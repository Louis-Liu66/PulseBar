import Foundation
import CoreLocation

private final class OfflineForecast: URLProtocol {
    static let lock = NSLock()
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; let n = Self.requests; Self.lock.unlock()
        let body: [String: Any] = ["timezone": "Australia/Sydney", "current": [
            "time": Date().timeIntervalSince1970, "temperature_2m": 20 + n % 3, "weather_code": 0, "is_day": 1]]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class FakeLocation: WeatherLocationDriver {
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var cachedLocation: CLLocation?
    var onAuthorizationChange: (() -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((Error) -> Void)?
    var requests = 0, authorizations = 0, stops = 0
    var onRequest: (() -> Void)?
    func requestAuthorization() { authorizations += 1 }
    func requestLocation() { requests += 1; onRequest?() }
    func stop() { stops += 1 }
    func cancelGeocoding() {}
    func placeName(for location: CLLocation) async throws -> WeatherPlaceName? {
        WeatherPlaceName(name: "测试地区", country: "Test", timezone: "Australia/Sydney")
    }
    func deliver(_ fix: CLLocation) { cachedLocation = fix; onLocations?([fix]) }
}

@main struct AutomaticWeatherTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), "FAIL: " + message); checks += 1
            print("PASS: " + message)
        }
        func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
            for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            preconditionFailure("asynchronous weather condition timed out")
        }
        let suite = "app.pulsebar.auto-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineForecast.self]; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var instant = Date()
        func fix(age: TimeInterval = 0) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: -33.864321, longitude: 151.214321),
                altitude: 0, horizontalAccuracy: 1000, verticalAccuracy: -1, timestamp: instant.addingTimeInterval(-age))
        }
        check(WeatherService.refreshInterval == 300, "production refresh schedule is five minutes")
        let driver = FakeLocation(); driver.cachedLocation = fix()
        let service = WeatherService(defaults: defaults, session: session, retryDelays: [0.08, 0.12],
            locationDriver: driver, now: { instant }, refreshInterval: 0.12, locationTimeout: 0.04)
        let before = OfflineForecast.count
        service.start()
        try await wait { service.snapshot != nil && !service.isLoading }
        check(driver.requests == 0, "fresh system cache avoids starting positioning")
        check(service.snapshot?.city.id == -1 && !service.isLocationStale, "fresh system location automatically fetches local weather")
        check(abs((service.selectedCity?.latitude ?? 0) + 33.86) < 0.00001, "system coordinates are rounded before weather and storage")
        check(service.snapshot?.city.name == "测试地区", "system region name is resolved automatically")
        service.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        check(OfflineForecast.count == before + 1, "activation does not duplicate fresh weather requests")
        try await wait { OfflineForecast.count >= before + 2 }
        check(true, "scheduled timer refreshes without user interaction")
        service.stop()
        let stoppedCount = OfflineForecast.count
        try await Task.sleep(nanoseconds: 180_000_000)
        check(OfflineForecast.count == stoppedCount, "stop cancels the automatic refresh timer")
        check(defaults.data(forKey: "PulseBar.weather.systemLocation.v1") != nil, "coarse system fix survives restart")

        instant = instant.addingTimeInterval(600)
        let noFix = FakeLocation()
        let restored = WeatherService(defaults: defaults, session: session, retryDelays: [0.10],
            locationDriver: noFix, now: { instant }, locationTimeout: 0.04)
        let restoredCount = OfflineForecast.count
        restored.start()
        try await wait { OfflineForecast.count > restoredCount && restored.snapshot?.fetchedAt == instant }
        check(restored.isLocationStale, "recent persisted system position is explicitly marked awaiting confirmation")
        try await wait { !restored.isLocating }
        check(!restored.isStale && !restored.isLoading, "stalled positioning does not block a weather refresh")
        try await wait { noFix.requests >= 2 }
        check(true, "positioning timeout automatically retries without clicks")
        noFix.deliver(fix())
        try await wait { !restored.isLocating && !restored.isLocationStale }
        check(restored.locationUpdatedAt == instant, "new system position automatically clears stale-location status")
        restored.stop()
        let stoppedRequests = noFix.requests
        try await Task.sleep(nanoseconds: 180_000_000)
        check(noFix.requests == stoppedRequests, "stop cancels positioning retries")

        instant = instant.addingTimeInterval(1900)
        let expiredDriver = FakeLocation()
        let expired = WeatherService(defaults: defaults, session: session, locationDriver: expiredDriver,
            now: { instant }, locationTimeout: 0.04)
        let expiredCount = OfflineForecast.count
        expired.start(); try await Task.sleep(nanoseconds: 70_000_000)
        check(OfflineForecast.count == expiredCount && expired.isStale, "expired coordinates never masquerade as current-location weather")
        expired.stop()
        defaults.removePersistentDomain(forName: suite)
        let manual = WeatherCity(id: 7, name: "Manual city", country: "", latitude: 10, longitude: 20, timezone: nil)
        defaults.set(try JSONEncoder().encode(manual), forKey: "PulseBar.weather.selectedCity.v1")
        defaults.set(false, forKey: "PulseBar.weather.followsLocation.v1")
        let permission = FakeLocation(); permission.authorizationStatus = .notDetermined
        let authorizing = WeatherService(defaults: defaults, session: session, locationDriver: permission,
            now: { instant }, locationTimeout: 0.04)
        let manualCount = OfflineForecast.count
        authorizing.start()
        check(authorizing.followsLocation && permission.authorizations == 1, "old manual preference migrates to automatic system authorization")
        check(OfflineForecast.count == manualCount, "manual city is never promoted to a system position")
        authorizing.start()
        check(permission.authorizations == 2, "foreground activation can recover an ignored background authorization request")
        permission.authorizationStatus = .authorizedAlways
        permission.onAuthorizationChange?()
        check(permission.requests == 1, "granting permission automatically starts positioning")
        permission.deliver(fix())
        try await wait { authorizing.snapshot != nil && !authorizing.isLoading }
        check(!authorizing.isStale, "granting location produces weather without manual refresh")
        authorizing.stop()
        defaults.removePersistentDomain(forName: suite)
        let staleDriver = FakeLocation()
        let staleFix = fix(age: 600)
        staleDriver.cachedLocation = staleFix
        staleDriver.onRequest = { [weak staleDriver] in staleDriver?.deliver(staleFix) }
        let backingOff = WeatherService(defaults: defaults, session: session, retryDelays: [0.08, 0.30],
            locationDriver: staleDriver, now: { instant }, locationTimeout: 0.04)
        backingOff.start()
        try await wait { staleDriver.requests == 2 }
        try await Task.sleep(nanoseconds: 130_000_000)
        check(staleDriver.requests == 2, "repeated stale fixes escalate retry backoff instead of restarting the first delay")
        staleDriver.cachedLocation = fix()
        backingOff.refresh()
        let requestsAfterFreshCache = staleDriver.requests
        try await Task.sleep(nanoseconds: 340_000_000)
        check(!backingOff.isLocationStale && staleDriver.requests == requestsAfterFreshCache,
              "fresh system cache cancels an already queued positioning retry")
        backingOff.stop()
        defaults.removePersistentDomain(forName: suite)
        let duplicateAuthorization = FakeLocation()
        let pendingLocation = WeatherService(defaults: defaults, session: session, retryDelays: [0.04],
            locationDriver: duplicateAuthorization, now: { instant }, locationTimeout: 0.04)
        pendingLocation.start()
        check(duplicateAuthorization.requests == 1 && pendingLocation.isLocating,
              "already authorized startup begins a bounded location request")
        duplicateAuthorization.onAuthorizationChange?()
        try await wait { duplicateAuthorization.requests >= 2 }
        check(true, "duplicate authorization callback preserves positioning timeout and automatic retry")
        pendingLocation.stop()
        print("\(checks) automatic-weather checks passed (all location/network data simulated offline).")
    }
}
