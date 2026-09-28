import Foundation

final class MockWeatherProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests = 0
    static var shouldFail = false
    static var failuresRemaining = 0
    static var lastURL: URL?
    private var cancelled = false
    static func count() -> Int { lock.withLock { requests } }
    static func failNextRequests() { lock.withLock { shouldFail = true } }
    static func reset(failures: Int = 0) {
        lock.withLock { requests = 0; shouldFail = false; failuresRemaining = failures; lastURL = nil }
    }
    static func query(_ name: String) -> String? {
        lock.withLock {
            lastURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first(where: { $0.name == name })?.value
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lastURL = request.url
        let fails = Self.shouldFail || Self.failuresRemaining > 0
        Self.failuresRemaining = max(0, Self.failuresRemaining - 1)
        Self.lock.unlock()
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let lat = parts.queryItems?.first(where: { $0.name == "latitude" })?.value ?? "0"
        let slow = lat == "10.0"
        DispatchQueue.global().asyncAfter(deadline: .now() + (slow ? 0.15 : 0.02)) { [weak self] in
            guard let self, !Self.lock.withLock({ self.cancelled }) else { return }
            if fails {
                self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let body = #"{"current":{"time":"2026-09-14T12:00","temperature_2m":21.5,"apparent_temperature":20,"relative_humidity_2m":60,"wind_speed_10m":8,"weather_code":2,"is_day":1}}"#
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.lock.withLock { cancelled = true } }
}

@main struct WeatherTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL: \(message)") }
            checks += 1
            print("PASS: \(message)")
        }
        let city = WeatherCity(id: 1, name: "Test A", country: "", latitude: 10, longitude: 20, timezone: nil)
        let valid = Data(#"{"current":{"temperature_2m":21.5,"relative_humidity_2m":135,"weather_code":0,"is_day":0}}"#.utf8)
        let decoded = try WeatherDataDecoder.snapshot(from: valid, city: city)
        check(decoded.temperatureCelsius == 21.5, "decode temperature")
        check(decoded.symbol == "moon.stars.fill", "night weather icon")
        check(decoded.humidity == nil, "invalid humidity stays missing")
        check(decoded.apparentTemperatureCelsius == nil, "missing optional values stay missing")
        let invalid = Data(#"{"current":{"weather_code":0,"is_day":1}}"#.utf8)
        check((try? WeatherDataDecoder.snapshot(from: invalid, city: city)) == nil, "missing temperature is rejected")
        let invalidDay = Data(#"{"current":{"temperature_2m":20,"weather_code":0,"is_day":9}}"#.utf8)
        check((try? WeatherDataDecoder.snapshot(from: invalidDay, city: city)) == nil, "invalid day is rejected")
        let emptyResults = try WeatherDataDecoder.cities(from: Data(#"{"results":[]}"#.utf8))
        check(emptyResults.isEmpty, "empty city search")
        let cities = Data(#"{"results":[{"id":1,"name":"A","latitude":10,"longitude":20},{"id":1,"name":"A","latitude":10,"longitude":20}]}"#.utf8)
        let uniqueResults = try WeatherDataDecoder.cities(from: cities)
        check(uniqueResults.count == 1, "duplicate cities removed")
        let malformed = Data(#"{"results":[{"id":1,"name":"A","latitude":100,"longitude":20}]}"#.utf8)
        check((try? WeatherDataDecoder.cities(from: malformed)) == nil, "invalid coordinates rejected")

        let iso = ISO8601DateFormatter()
        func date(_ text: String) -> Date { iso.date(from: text)! }
        func epoch(_ text: String) -> Double { date(text).timeIntervalSince1970 }
        let currentTime = epoch("2026-09-15T06:45:00Z") // September 14, 23:45 in Los Angeles.
        var forecast: [String: Any] = [
            "timezone": "America/Los_Angeles", "utc_offset_seconds": -25_200,
            "current": ["time": currentTime, "temperature_2m": 21.5, "weather_code": 2, "is_day": 0],
            "hourly": ["time": [epoch("2026-09-15T06:00:00Z"), epoch("2026-09-15T07:00:00Z"), epoch("2026-09-15T08:00:00Z")],
                       "precipitation_probability": [5, 70, 95]],
            "daily": ["time": [epoch("2026-09-14T07:00:00Z"), epoch("2026-09-15T07:00:00Z")],
                      "sunrise": [epoch("2026-09-14T13:35:00Z"), epoch("2026-09-15T13:36:00Z")],
                      "sunset": [epoch("2026-09-15T02:05:00Z"), epoch("2026-09-16T02:03:00Z")]]
        ]
        func decode(_ object: [String: Any]) throws -> WeatherSnapshot {
            try WeatherDataDecoder.snapshot(from: JSONSerialization.data(withJSONObject: object), city: city,
                                            fetchedAt: date("2026-09-15T06:47:00Z"))
        }
        let complete = try decode(forecast)
        check(complete.precipitationProbability == 70, "next-hour probability crosses local midnight and is not daily max")
        check(complete.sunrise == date("2026-09-14T13:35:00Z"), "sunrise selects weather city's day, not Mac's day")
        check(complete.sunset == date("2026-09-15T02:05:00Z"), "sunset keeps the correct absolute instant")
        check(complete.weatherTimeZone == "America/Los_Angeles", "weather time-zone identifier is retained")
        check(complete.observationTime.flatMap(iso.date(from:)) == date("2026-09-15T06:45:00Z"), "Unix current time preserves observationTime string contract")
        let roundTrip = try JSONDecoder().decode(WeatherSnapshot.self, from: JSONEncoder().encode(complete))
        check(roundTrip.precipitationProbability == 70 && roundTrip.sunrise == complete.sunrise,
              "new weather fields survive cache round trip")
        var legacyCache = try JSONSerialization.jsonObject(with: JSONEncoder().encode(complete)) as! [String: Any]
        for key in ["precipitationProbability", "sunrise", "sunset", "weatherTimeZone"] { legacyCache.removeValue(forKey: key) }
        let restoredLegacy = try JSONDecoder().decode(WeatherSnapshot.self, from: JSONSerialization.data(withJSONObject: legacyCache))
        check(restoredLegacy.temperatureCelsius == complete.temperatureCelsius && restoredLegacy.precipitationProbability == nil
              && restoredLegacy.sunrise == nil && restoredLegacy.sunset == nil && restoredLegacy.weatherTimeZone == nil,
              "older cache without new optional keys remains readable")
        let oldInitializer = WeatherSnapshot(city: city, temperatureCelsius: 10, apparentTemperatureCelsius: nil,
                                             humidity: nil, windKmh: nil, weatherCode: 0, isDay: true,
                                             fetchedAt: Date(), observationTime: nil)
        check(oldInitializer.sunrise == nil && oldInitializer.precipitationProbability == nil, "old initializer labels remain source compatible")

        forecast["hourly"] = ["time": [currentTime - 900, currentTime + 900], "precipitation_probability": [95, NSNull()]]
        forecast["daily"] = ["time": [epoch("2026-09-14T07:00:00Z")], "sunrise": [NSNull()], "sunset": ["malformed"]]
        let nullValues = try decode(forecast)
        check(nullValues.precipitationProbability == nil && nullValues.sunrise == nil && nullValues.sunset == nil,
              "null and malformed optional weather values remain absent")
        forecast["hourly"] = ["time": [currentTime + 900], "precipitation_probability": [150]]
        check(try decode(forecast).precipitationProbability == nil, "probability outside zero to one hundred is rejected")
        forecast["hourly"] = ["time": [currentTime + 900], "precipitation_probability": [0]]
        check(try decode(forecast).precipitationProbability == 0, "zero probability is real data rather than missing")
        forecast["hourly"] = ["time": [currentTime - 900], "precipitation_probability": [99]]
        check(try decode(forecast).precipitationProbability == nil, "past-only probability cannot masquerade as next hour")
        forecast["hourly"] = ["time": [currentTime + 7_200], "precipitation_probability": [99]]
        check(try decode(forecast).precipitationProbability == nil, "far-future probability cannot masquerade as next hour")
        forecast["hourly"] = "malformed"
        forecast["daily"] = NSNull()
        let malformedOptional = try decode(forecast)
        check(malformedOptional.temperatureCelsius == 21.5 && malformedOptional.precipitationProbability == nil,
              "malformed optional forecast sections do not discard valid current weather")

        let dst = try decode([
            "timezone": "America/New_York", "current": ["time": epoch("2026-11-01T05:30:00Z"), "temperature_2m": 10, "weather_code": 3, "is_day": 0],
            "hourly": ["time": [epoch("2026-11-01T05:00:00Z"), epoch("2026-11-01T06:00:00Z"), epoch("2026-11-01T07:00:00Z")],
                       "precipitation_probability": [1, 82, 2]]])
        check(dst.precipitationProbability == 82, "repeated DST hour is selected by absolute timestamp")
        let legacyTime = try decode([
            "timezone": "Asia/Tokyo", "current": ["time": "2026-09-15T00:15", "temperature_2m": 20, "weather_code": 0, "is_day": 0],
            "hourly": ["time": ["2026-09-15T00:00", "2026-09-15T01:00"], "precipitation_probability": [4, 42]],
            "daily": ["time": ["2026-09-15"], "sunrise": ["2026-09-15T05:25"], "sunset": ["2026-09-15T17:50"]]])
        check(legacyTime.precipitationProbability == 42 && legacyTime.observationTime == "2026-09-15T00:15",
              "legacy ISO local timestamps use supplied weather timezone")
        check(legacyTime.sunrise == date("2026-09-14T20:25:00Z"), "legacy sunrise is converted using weather timezone")
        let missingZone = try decode([
            "timezone": "invalid/zone", "current": ["time": "2026-09-15T00:15", "temperature_2m": 20, "weather_code": 0, "is_day": 0],
            "hourly": ["time": ["2026-09-15T01:00"], "precipitation_probability": [80]],
            "daily": ["time": ["2026-09-15"], "sunrise": ["2026-09-15T05:25"], "sunset": ["2026-09-15T17:50"]]])
        check(missingZone.weatherTimeZone == nil && missingZone.sunrise == nil && missingZone.precipitationProbability == nil,
              "missing timezone never silently falls back to device timezone")

        let suite = "app.pulsebar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockWeatherProtocol.self]
        let session = URLSession(configuration: config)
        let service = WeatherService(defaults: defaults, session: session)
        check(service.followsLocation, "new install defaults to automatic current-location weather")
        service.select(city)
        try await Task.sleep(nanoseconds: 20_000_000) // First city's request is already in flight.
        let cityB = WeatherCity(id: 2, name: "Test B", country: "", latitude: 30, longitude: 40, timezone: nil)
        service.select(cityB)
        try await Task.sleep(nanoseconds: 400_000_000)
        check(service.snapshot?.city.id == 2, "rapid city switch cannot overwrite latest city")
        check(!service.isLoading && !service.isStale, "successful request clears loading and stale state")
        check(MockWeatherProtocol.query("timeformat") == "unixtime" && MockWeatherProtocol.query("daily") == "sunrise,sunset"
              && MockWeatherProtocol.query("hourly") == "precipitation_probability" && MockWeatherProtocol.query("forecast_days") == "2",
              "request includes Unix times and enough forecast data for midnight rollover")
        let previous = service.snapshot!.fetchedAt
        let count = MockWeatherProtocol.count()
        service.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        check(MockWeatherProtocol.count() == count, "fresh cache suppresses scheduled network request")
        MockWeatherProtocol.failNextRequests()
        service.refresh(force: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        check(service.isStale && !service.isLoading, "offline failure is marked stale without stuck loading")
        check(service.snapshot?.fetchedAt == previous && service.snapshot?.city.id == 2, "offline request preserves last known data and city")
        service.stop()
        check(!service.isLoading, "stop cancels pending work")
        let restored = WeatherService(defaults: defaults, session: session)
        check(restored.snapshot?.city.id == 2 && restored.isStale, "disk cache restores with explicit stale status")
        check(restored.followsLocation, "automatic location replaces a saved manual-city preference on restart")
        restored.stop()

        MockWeatherProtocol.reset(failures: 2)
        let retrying = WeatherService(defaults: defaults, session: session, retryDelays: [0.05, 0.10, 0.15])
        retrying.select(cityB)
        try await Task.sleep(nanoseconds: 500_000_000)
        check(MockWeatherProtocol.count() == 3, "offline failures automatically retry then stop retrying after success")
        check(!retrying.isStale && !retrying.isLoading, "successful automatic retry restores fresh state")
        retrying.stop()

        MockWeatherProtocol.reset(failures: 10)
        let stopped = WeatherService(defaults: defaults, session: session, retryDelays: [0.12])
        stopped.select(cityB)
        try await Task.sleep(nanoseconds: 60_000_000)
        check(MockWeatherProtocol.count() == 1 && stopped.isStale, "failure schedules a delayed retry without spinning")
        stopped.stop()
        try await Task.sleep(nanoseconds: 220_000_000)
        check(MockWeatherProtocol.count() == 1 && !stopped.isLoading, "stop cancels pending retry and prevents new requests")

        MockWeatherProtocol.reset(failures: 1)
        let switched = WeatherService(defaults: defaults, session: session, retryDelays: [0.12])
        switched.select(cityB)
        try await Task.sleep(nanoseconds: 60_000_000)
        switched.select(city)
        try await Task.sleep(nanoseconds: 350_000_000)
        check(MockWeatherProtocol.count() == 2 && switched.snapshot?.city.id == 1,
              "city switch cancels old city's scheduled retry")
        switched.stop()

        MockWeatherProtocol.reset()
        let nonoverlapping = WeatherService(defaults: defaults, session: session, retryDelays: [0.05])
        nonoverlapping.select(city)
        for _ in 0..<10 { nonoverlapping.refresh(force: true) }
        try await Task.sleep(nanoseconds: 250_000_000)
        check(MockWeatherProtocol.count() == 1, "repeated refreshes cannot start parallel weather requests")
        nonoverlapping.stop()
        session.invalidateAndCancel()
        print("\(checks) checks passed.")
    }
}
