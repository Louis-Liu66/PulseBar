import Foundation
import Combine
import CoreLocation
import Network

struct WeatherCity: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let country: String
    let latitude: Double
    let longitude: Double
    let timezone: String?

    var hasValidCoordinates: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    func isSameLocation(as other: WeatherCity) -> Bool {
        id == other.id && latitude == other.latitude && longitude == other.longitude
    }
}

extension WeatherCity {
    private enum CodingKeys: String, CodingKey {
        case id, name, country, latitude, longitude, timezone
        case countryCode = "country_code"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        country = try values.decodeIfPresent(String.self, forKey: .country)
            ?? values.decodeIfPresent(String.self, forKey: .countryCode) ?? ""
        latitude = try values.decode(Double.self, forKey: .latitude)
        longitude = try values.decode(Double.self, forKey: .longitude)
        timezone = try values.decodeIfPresent(String.self, forKey: .timezone)
        guard hasValidCoordinates, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid city coordinates or name"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(country, forKey: .country)
        try values.encode(latitude, forKey: .latitude)
        try values.encode(longitude, forKey: .longitude)
        try values.encodeIfPresent(timezone, forKey: .timezone)
    }
}

struct WeatherSnapshot: Codable {
    var city: WeatherCity
    let temperatureCelsius: Double
    let apparentTemperatureCelsius: Double?
    let humidity: Double?
    let windKmh: Double?
    let weatherCode: Int
    let isDay: Bool
    let fetchedAt: Date
    let observationTime: String?
    /// Probability for the upcoming hourly interval, not the daily maximum.
    let precipitationProbability: Double?
    let sunrise: Date?
    let sunset: Date?
    let weatherTimeZone: String?

    init(city: WeatherCity, temperatureCelsius: Double, apparentTemperatureCelsius: Double?,
         humidity: Double?, windKmh: Double?, weatherCode: Int, isDay: Bool,
         fetchedAt: Date, observationTime: String?, precipitationProbability: Double? = nil,
         sunrise: Date? = nil, sunset: Date? = nil, weatherTimeZone: String? = nil) {
        self.city = city
        self.temperatureCelsius = temperatureCelsius
        self.apparentTemperatureCelsius = apparentTemperatureCelsius
        self.humidity = humidity
        self.windKmh = windKmh
        self.weatherCode = weatherCode
        self.isDay = isDay
        self.fetchedAt = fetchedAt
        self.observationTime = observationTime
        self.precipitationProbability = precipitationProbability
        self.sunrise = sunrise
        self.sunset = sunset
        self.weatherTimeZone = weatherTimeZone
    }

    var symbol: String {
        switch weatherCode {
        case 0, 1: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.hail.fill"
        default: return "cloud.fill"
        }
    }

    var summary: String {
        switch weatherCode {
        case 0: return "晴"
        case 1: return "大部晴朗"
        case 2: return "局部多云"
        case 3: return "阴"
        case 45: return "雾"
        case 48: return "雾凇"
        case 51: return "轻微毛毛雨"
        case 53: return "毛毛雨"
        case 55: return "较强毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 66, 67: return "冻雨"
        case 71: return "小雪"
        case 73: return "中雪"
        case 75: return "大雪"
        case 77: return "米雪"
        case 80: return "小阵雨"
        case 81: return "阵雨"
        case 82: return "强阵雨"
        case 85: return "阵雪"
        case 86: return "强阵雪"
        case 95: return "雷雨"
        case 96, 99: return "雷雨伴冰雹"
        default: return "天气状况未知"
        }
    }
}

/// Pure decoders are shared by the network client and deterministic fixture tests.
enum WeatherDataDecoder {
    private struct GeocodingResponse: Decodable {
        let results: [WeatherCity]?
    }

    private struct APITime: Decodable {
        let seconds: Double?
        let text: String?
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            seconds = try? value.decode(Double.self)
            text = try? value.decode(String.self)
        }
        func date(in timeZone: TimeZone?) -> Date? {
            if let seconds, seconds.isFinite, (0...32_503_680_000).contains(seconds) {
                return Date(timeIntervalSince1970: seconds)
            }
            guard let text else { return nil }
            let iso = ISO8601DateFormatter()
            if let absolute = iso.date(from: text) { return absolute }
            guard let timeZone else { return nil } // Never interpret a remote city's time in the Mac's zone.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.isLenient = false
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
    }

    private struct APINumber: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Double.self) }
    }

    private struct ForecastResponse: Decodable {
        let current: Current?
        let timezone: String?
        let utc_offset_seconds: Int?
        let hourly: Hourly?
        let daily: Daily?
        private enum CodingKeys: String, CodingKey { case current, timezone, utc_offset_seconds, hourly, daily }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            current = try values.decodeIfPresent(Current.self, forKey: .current)
            timezone = try? values.decode(String.self, forKey: .timezone)
            utc_offset_seconds = try? values.decode(Int.self, forKey: .utc_offset_seconds)
            hourly = try? values.decode(Hourly.self, forKey: .hourly)
            daily = try? values.decode(Daily.self, forKey: .daily)
        }
        struct Current: Decodable {
            let time: APITime?
            let temperature_2m: Double?
            let apparent_temperature: Double?
            let relative_humidity_2m: Double?
            let wind_speed_10m: Double?
            let weather_code: Int?
            let is_day: Int?
        }
        struct Hourly: Decodable {
            let time: [APITime]?
            let precipitation_probability: [APINumber]?
        }
        struct Daily: Decodable {
            let time: [APITime]?
            let sunrise: [APITime]?
            let sunset: [APITime]?
        }
    }

    static func cities(from data: Data, limit: Int = 8) throws -> [WeatherCity] {
        let response = try JSONDecoder().decode(GeocodingResponse.self, from: data)
        var seen = Set<Int>()
        return Array((response.results ?? []).filter { seen.insert($0.id).inserted }.prefix(max(0, min(limit, 8))))
    }

    static func snapshot(from data: Data, city: WeatherCity, fetchedAt: Date = Date()) throws -> WeatherSnapshot {
        let response = try JSONDecoder().decode(ForecastResponse.self, from: data)
        guard city.hasValidCoordinates, let current = response.current,
              let temperature = current.temperature_2m, temperature.isFinite,
              let code = current.weather_code, let day = current.is_day, day == 0 || day == 1 else {
            throw WeatherServiceError.invalidData
        }
        let humidity = current.relative_humidity_2m.flatMap { (0...100).contains($0) ? $0 : nil }
        let wind = current.wind_speed_10m.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let apparent = current.apparent_temperature.flatMap { $0.isFinite ? $0 : nil }
        let timeZone = response.timezone.flatMap(TimeZone.init(identifier:))
            ?? city.timezone.flatMap(TimeZone.init(identifier:))
            ?? response.utc_offset_seconds.flatMap(TimeZone.init(secondsFromGMT:))
        let currentDate = current.time?.date(in: timeZone) ?? fetchedAt
        let observationTime: String?
        if let original = current.time?.text {
            observationTime = original
        } else if current.time?.date(in: timeZone) != nil {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = timeZone ?? TimeZone(secondsFromGMT: 0)!
            observationTime = formatter.string(from: currentDate)
        } else { observationTime = nil }

        // Open-Meteo's hourly probability applies to the hour ending at its timestamp.
        // Select the first future endpoint within one hour, including across local midnight/DST.
        let nextHour = response.hourly?.time?.enumerated().compactMap { index, value -> (Int, Date)? in
            guard let date = value.date(in: timeZone), date > currentDate,
                  date.timeIntervalSince(currentDate) <= 3_600 else { return nil }
            return (index, date)
        }.min(by: { $0.1 < $1.1 })?.0
        var probability: Double?
        if let nextHour, let values = response.hourly?.precipitation_probability,
           values.indices.contains(nextHour), let value = values[nextHour].value,
           value.isFinite, (0...100).contains(value) { probability = value }

        var sunrise: Date?
        var sunset: Date?
        if let timeZone, let daily = response.daily, let times = daily.time {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            if let index = times.firstIndex(where: { value in
                value.date(in: timeZone).map { calendar.isDate($0, inSameDayAs: currentDate) } ?? false
            }) {
                if let values = daily.sunrise, values.indices.contains(index) {
                    sunrise = values[index].date(in: timeZone)
                }
                if let values = daily.sunset, values.indices.contains(index) {
                    sunset = values[index].date(in: timeZone)
                }
                if let value = sunrise, !calendar.isDate(value, inSameDayAs: currentDate) { sunrise = nil }
                if let value = sunset, !calendar.isDate(value, inSameDayAs: currentDate) { sunset = nil }
            }
        }
        return WeatherSnapshot(city: city, temperatureCelsius: temperature,
                               apparentTemperatureCelsius: apparent, humidity: humidity,
                               windKmh: wind, weatherCode: code, isDay: day == 1,
                               fetchedAt: fetchedAt, observationTime: observationTime,
                               precipitationProbability: probability, sunrise: sunrise, sunset: sunset,
                               weatherTimeZone: timeZone?.identifier)
    }
}

private enum WeatherServiceError: LocalizedError {
    case invalidData
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidData: return "天气服务返回的数据不完整"
        case .http(let code): return "天气服务暂不可用（\(code)）"
        }
    }
}

struct WeatherPlaceName {
    let name: String
    let country: String
    let timezone: String?
}

@MainActor protocol WeatherLocationDriver: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var cachedLocation: CLLocation? { get }
    var onAuthorizationChange: (() -> Void)? { get set }
    var onLocations: (([CLLocation]) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func requestAuthorization()
    func requestLocation()
    func stop()
    func placeName(for location: CLLocation) async throws -> WeatherPlaceName?
    func cancelGeocoding()
}

@MainActor final class SystemWeatherLocationDriver: NSObject, WeatherLocationDriver, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    var onAuthorizationChange: (() -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((Error) -> Void)?
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var cachedLocation: CLLocation? { manager.location }
    override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = self
    }
    func requestAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestLocation() { manager.requestLocation() }
    func stop() { manager.stopUpdatingLocation() }
    func cancelGeocoding() { geocoder.cancelGeocode() }
    func placeName(for location: CLLocation) async throws -> WeatherPlaceName? {
        guard let place = try await geocoder.reverseGeocodeLocation(location).first,
              let name = [place.locality, place.subAdministrativeArea, place.administrativeArea]
                .compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        return WeatherPlaceName(name: name, country: place.country ?? "", timezone: place.timeZone?.identifier)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { onAuthorizationChange?() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { onLocations?(locations) }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { onFailure?(error) }
    deinit { manager.stopUpdatingLocation(); geocoder.cancelGeocode() }
}

/// Weather: https://open-meteo.com/ (CC BY 4.0); city search: GeoNames.
/// The current endpoint returns model-derived conditions, not station observations.
@MainActor
final class WeatherService: NSObject, ObservableObject {
    @Published var snapshot: WeatherSnapshot?
    @Published var status = "请选择城市或使用当前位置"
    @Published var cities: [WeatherCity] = []
    @Published var isLoading = false
    @Published var selectedCity: WeatherCity?
    @Published private(set) var isStale = true
    @Published private(set) var searchStatus = ""
    @Published private(set) var isSearching = false
    @Published private(set) var followsLocation = false
    @Published private(set) var locationStatus = ""
    @Published private(set) var isLocating = false
    @Published private(set) var isLocationStale = true
    @Published private(set) var locationUpdatedAt: Date?

    var hasConfiguredWeather: Bool { selectedCity != nil || followsLocation }

    static let attribution = "天气数据：Open-Meteo · 城市搜索：GeoNames"
    nonisolated static let refreshInterval: TimeInterval = 300
    private static let locationFreshAge: TimeInterval = 300
    private static let locationMaxAge: TimeInterval = 30 * 60
    private static let cityKey = "PulseBar.weather.selectedCity.v1"
    private static let cacheKey = "PulseBar.weather.snapshot.v1"
    private static let followKey = "PulseBar.weather.followsLocation.v1"
    private static let systemFixKey = "PulseBar.weather.systemLocation.v1"
    private struct SystemFix: Codable {
        var city: WeatherCity
        let timestamp: Date
        let accuracy: Double
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let ownsSession: Bool
    private let retryDelays: [TimeInterval]
    private let locationDriver: WeatherLocationDriver
    private let now: () -> Date
    private let pollingInterval: TimeInterval
    private let locationTimeoutInterval: TimeInterval
    private let monitorsNetwork: Bool
    private var networkMonitor: NWPathMonitor?
    private var networkGeneration = UUID()
    private var networkWasUnavailable = false
    private var systemFix: SystemFix?
    private var timer: Timer?
    private var weatherTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var locationTimeout: Task<Void, Never>?
    private var geocodeTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var geocodeRetryTask: Task<Void, Never>?
    private var geocodeTimeout: Task<Void, Never>?
    private var locationRetryTask: Task<Void, Never>?
    private var locationRetryAttempt = 0
    private var retryAttempt = 0
    private var geocodeRetryAttempt = 0
    private var automaticRetriesEnabled = false
    private var weatherGeneration = UUID()
    private var searchGeneration = UUID()
    private var locationGeneration = UUID()
    private var geocodeGeneration = UUID()
    private var lastGeocodedLocation: CLLocation?
    private var lastGeocodedAt: Date?
    private var locationRequestsEnabled = false
    private var awaitingAuthorization = false
    private var confirmedLocationThisRun = false

    init(defaults: UserDefaults = .standard, session: URLSession? = nil,
         retryDelays: [TimeInterval] = [60, 180, 300],
         locationDriver: WeatherLocationDriver? = nil,
         now: @escaping () -> Date = Date.init,
         refreshInterval: TimeInterval = WeatherService.refreshInterval,
         locationTimeout: TimeInterval = 15) {
        self.defaults = defaults
        self.locationDriver = locationDriver ?? SystemWeatherLocationDriver()
        self.now = now
        pollingInterval = refreshInterval.isFinite && refreshInterval > 0 ? refreshInterval : Self.refreshInterval
        locationTimeoutInterval = locationTimeout.isFinite && locationTimeout > 0 ? locationTimeout : 15
        monitorsNetwork = locationDriver == nil
        let delays = retryDelays.filter { $0.isFinite && $0 > 0 }.map { min($0, 900) }
        self.retryDelays = delays.isEmpty ? [60, 180, 300] : delays
        ownsSession = session == nil
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 12
            config.waitsForConnectivity = false
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        super.init()
        if let data = defaults.data(forKey: Self.cityKey),
           let city = try? JSONDecoder().decode(WeatherCity.self, from: data) {
            selectedCity = city
        }
        followsLocation = true
        if let data = defaults.data(forKey: Self.systemFixKey),
           let fix = try? JSONDecoder().decode(SystemFix.self, from: data),
           fix.city.id == -1, fix.city.hasValidCoordinates, fix.accuracy >= 0, fix.accuracy <= 50_000,
           now().timeIntervalSince(fix.timestamp) >= -60,
           now().timeIntervalSince(fix.timestamp) <= Self.locationMaxAge {
            systemFix = fix
            locationUpdatedAt = fix.timestamp
        }
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(WeatherSnapshot.self, from: data),
           cached.city.hasValidCoordinates, cached.temperatureCelsius.isFinite,
           cached.fetchedAt.timeIntervalSince(now()) <= 300,
           followsLocation || selectedCity.map({ cached.city.isSameLocation(as: $0) }) == true {
            snapshot = cached
            status = cachedStatus("显示上次缓存")
        }
        self.locationDriver.onAuthorizationChange = { [weak self] in self?.authorizationChanged() }
        self.locationDriver.onLocations = { [weak self] locations in self?.receivedLocations(locations) }
        self.locationDriver.onFailure = { [weak self] error in self?.locationRequestFailed(error) }
    }

    deinit {
        timer?.invalidate()
        weatherTask?.cancel()
        searchTask?.cancel()
        locationTimeout?.cancel()
        geocodeTask?.cancel()
        retryTask?.cancel()
        geocodeRetryTask?.cancel()
        geocodeTimeout?.cancel()
        locationRetryTask?.cancel()
        networkMonitor?.cancel()
        if ownsSession { session.invalidateAndCancel() }
    }

    func start() {
        if timer != nil {
            awaitingAuthorization = false
            refresh()
            return
        }
        followsLocation = true
        defaults.set(true, forKey: Self.followKey)
        locationRequestsEnabled = true
        automaticRetriesEnabled = true
        timer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh(force: true) }
        }
        timer?.tolerance = min(30, pollingInterval * 0.1)
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        startNetworkMonitor()
        refresh(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        networkGeneration = UUID()
        locationRequestsEnabled = false
        automaticRetriesEnabled = false
        cancelRetry(resetAttempts: true)
        cancelLocation()
        cancelWeather()
        cancelSearch()
        isLoading = false
        isStale = true
        isLocationStale = true
        status = cachedStatus("天气更新已暂停")
    }

    func search(_ query: String) {
        cancelSearch()
        cities = []
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard term.count >= 2 else {
            searchStatus = term.isEmpty ? "" : "请输入至少两个字符"
            return
        }
        let generation = searchGeneration
        isSearching = true
        searchStatus = "正在搜索城市…"
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard let self, !Task.isCancelled else { return }
                var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                url.queryItems = [URLQueryItem(name: "name", value: term),
                                  URLQueryItem(name: "count", value: "8"),
                                  URLQueryItem(name: "language", value: "zh"),
                                  URLQueryItem(name: "format", value: "json")]
                let data = try await self.requestData(url.url!)
                let found = try WeatherDataDecoder.cities(from: data)
                guard !Task.isCancelled, self.searchGeneration == generation else { return }
                self.cities = found
                self.searchStatus = found.isEmpty ? "未找到城市，试试英文名或加上国家名称" : "请选择城市"
                self.isSearching = false
                self.searchTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
                self.searchStatus = "城市搜索暂不可用，请检查网络后重试"
                self.isSearching = false
                self.searchTask = nil
            }
        }
    }

    func select(_ city: WeatherCity) {
        guard city.hasValidCoordinates else { return }
        cancelRetry(resetAttempts: true)
        cancelLocation()
        cancelWeather()
        cancelSearch()
        followsLocation = false
        automaticRetriesEnabled = true
        defaults.set(false, forKey: Self.followKey)
        locationStatus = "已使用手选城市"
        selectedCity = city
        persistCity()
        cities = []
        searchStatus = ""
        isStale = true
        fetchWeather(for: city, force: true)
    }

    func useCurrentLocation() {
        cancelRetry(resetAttempts: true)
        cancelLocation()
        cancelWeather()
        cancelSearch()
        followsLocation = true
        defaults.set(true, forKey: Self.followKey)
        locationRequestsEnabled = true
        automaticRetriesEnabled = true
        isStale = true
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        if force { cancelRetry(resetAttempts: false) }
        if followsLocation {
            guard locationRequestsEnabled else { return }
            guard locationDriver.authorizationStatus == .authorizedAlways else {
                requestCoarseLocation(allowPrompt: true)
                return
            }
            // This is a read of Core Location's own cache, not a new sensor request.
            if let cached = locationDriver.cachedLocation, validSystemLocation(cached),
               systemFix == nil || cached.timestamp >= systemFix!.timestamp {
                acceptSystemLocation(cached, finishRequest: false)
            }
            refreshWeatherFromSystemFix(force: force)
            if !confirmedLocationThisRun || systemFix.map({ now().timeIntervalSince($0.timestamp) >= Self.locationFreshAge }) != false {
                if locationRetryTask == nil { requestCoarseLocation(allowPrompt: true) }
            }
            return
        }
        guard let city = selectedCity else {
            status = "请选择城市或使用当前位置"
            return
        }
        fetchWeather(for: city, force: force)
    }

    private func validSystemLocation(_ fix: CLLocation) -> Bool {
        CLLocationCoordinate2DIsValid(fix.coordinate) && fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 50_000
            && now().timeIntervalSince(fix.timestamp) >= -60 && now().timeIntervalSince(fix.timestamp) <= Self.locationMaxAge
    }

    private var usableSystemFix: SystemFix? {
        guard let fix = systemFix, now().timeIntervalSince(fix.timestamp) >= -60,
              now().timeIntervalSince(fix.timestamp) <= Self.locationMaxAge else { return nil }
        return fix
    }

    private func refreshWeatherFromSystemFix(force: Bool) {
        guard followsLocation, locationDriver.authorizationStatus == .authorizedAlways,
              let fix = usableSystemFix else {
            isLocationStale = true
            isStale = true
            status = cachedStatus("等待系统提供有效位置")
            return
        }
        isLocationStale = !confirmedLocationThisRun || now().timeIntervalSince(fix.timestamp) >= Self.locationFreshAge
        locationUpdatedAt = fix.timestamp
        if selectedCity?.isSameLocation(as: fix.city) != true {
            cancelWeather()
            cancelRetry(resetAttempts: true)
        }
        selectedCity = fix.city
        persistCity()
        fetchWeather(for: fix.city, force: force)
    }

    private var locationSuffix: String {
        guard followsLocation, isLocationStale else { return "" }
        if let time = locationUpdatedAt { return " · 位置待确认（上次定位 \(Self.dateLabel(time))）" }
        return " · 等待系统定位"
    }

    private func fetchWeather(for city: WeatherCity, force: Bool) {
        guard weatherTask == nil else { return }
        if !force, !isStale, let snapshot, snapshot.city.isSameLocation(as: city),
           now().timeIntervalSince(snapshot.fetchedAt) < pollingInterval { return }
        let generation = weatherGeneration
        isLoading = true
        isStale = true
        status = cachedStatus("正在更新\(city.name)天气…") + locationSuffix
        weatherTask = Task { [weak self] in
            guard let self else { return }
            do {
                var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                url.queryItems = [URLQueryItem(name: "latitude", value: String(city.latitude)),
                                  URLQueryItem(name: "longitude", value: String(city.longitude)),
                                  URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"),
                                  URLQueryItem(name: "hourly", value: "precipitation_probability"),
                                  URLQueryItem(name: "daily", value: "sunrise,sunset"),
                                  URLQueryItem(name: "timeformat", value: "unixtime"),
                                  URLQueryItem(name: "temperature_unit", value: "celsius"),
                                  URLQueryItem(name: "wind_speed_unit", value: "kmh"),
                                  URLQueryItem(name: "timezone", value: "auto"),
                                  URLQueryItem(name: "forecast_days", value: "2")]
                let data = try await self.requestData(url.url!)
                var result = try WeatherDataDecoder.snapshot(from: data, city: city, fetchedAt: self.now())
                guard !Task.isCancelled, generation == self.weatherGeneration,
                      let selected = self.selectedCity, selected.isSameLocation(as: city) else { return }
                result.city = selected // A reverse-geocode result may have supplied the name meanwhile.
                self.snapshot = result
                self.isStale = false
                self.cancelRetry(resetAttempts: true)
                self.status = "已更新 · \(Self.dateLabel(result.fetchedAt))" + self.locationSuffix
                self.persistSnapshot()
            } catch {
                guard !Task.isCancelled, generation == self.weatherGeneration else { return }
                self.isStale = true
                let note = (error as? WeatherServiceError)?.localizedDescription ?? "天气更新失败，请检查网络"
                self.status = self.cachedStatus(note)
                self.scheduleRetry()
            }
            guard generation == self.weatherGeneration else { return }
            self.weatherTask = nil
            self.isLoading = self.isLocating
        }
    }

    private func requestData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WeatherServiceError.invalidData }
        guard (200...299).contains(http.statusCode) else { throw WeatherServiceError.http(http.statusCode) }
        guard data.count <= 2_000_000 else { throw WeatherServiceError.invalidData }
        return data
    }

    private func requestCoarseLocation(allowPrompt: Bool) {
        guard followsLocation, locationRequestsEnabled, !isLocating else { return }
        switch locationDriver.authorizationStatus {
        case .notDetermined:
            if allowPrompt && !awaitingAuthorization {
                awaitingAuthorization = true
                locationStatus = "等待 macOS 定位授权"
                status = cachedStatus(locationStatus)
                locationDriver.requestAuthorization()
                // An inactive menu-bar app's request can be ignored by macOS.
                // Never latch authorization waiting forever; activation/start can retry too.
                locationTimeout?.cancel()
                locationTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    self.awaitingAuthorization = false
                    self.locationTimeout = nil
                }
            }
            return
        case .denied, .restricted:
            locationFailed("macOS 未允许定位；在系统设置允许后将自动恢复", retryable: false)
            return
        case .authorizedAlways: break
        @unknown default:
            locationFailed("系统定位暂不可用", retryable: false)
            return
        }
        awaitingAuthorization = false
        isLocating = true
        isLoading = true
        locationStatus = "正在获取系统大致位置…"
        if snapshot == nil { status = locationStatus }
        let token = locationGeneration
        let timeout = locationTimeoutInterval
        locationTimeout?.cancel()
        locationTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled, self.locationGeneration == token, self.isLocating else { return }
            self.locationFailed("系统定位暂未返回，将自动重试")
        }
        // One system request, at kilometre accuracy, with a bounded deadline. No continuous GPS.
        locationDriver.requestLocation()
    }

    private func authorizationChanged() {
        guard followsLocation, locationRequestsEnabled else { return }
        awaitingAuthorization = false
        switch locationDriver.authorizationStatus {
        case .authorizedAlways:
            // Core Location can report its existing authorization after start()
            // has already begun positioning. Preserve that request's deadline.
            if !isLocating {
                locationTimeout?.cancel()
                locationTimeout = nil
            }
            refresh(force: true)
        case .denied, .restricted:
            cancelLocation()
            cancelWeather()
            cancelRetry(resetAttempts: true)
            locationFailed("macOS 未允许定位；在系统设置允许后将自动恢复", retryable: false)
        default: break
        }
    }

    private func receivedLocations(_ locations: [CLLocation]) {
        guard followsLocation, locationRequestsEnabled, isLocating else { return }
        guard let fix = locations.filter({ validSystemLocation($0) }).max(by: { $0.timestamp < $1.timestamp }) else {
            return // Keep the bounded deadline when the first cached value is unusable.
        }
        acceptSystemLocation(fix, finishRequest: true)
        refreshWeatherFromSystemFix(force: false)
    }

    private func acceptSystemLocation(_ fix: CLLocation, finishRequest: Bool) {
        guard validSystemLocation(fix) else { return }
        if finishRequest {
            locationDriver.stop()
            locationTimeout?.cancel()
            locationTimeout = nil
            isLocating = false
            locationRetryTask?.cancel()
            locationRetryTask = nil
            isLoading = weatherTask != nil
        }
        if let old = systemFix, old.timestamp > fix.timestamp { return }
        let lat = (fix.coordinate.latitude * 100).rounded() / 100
        let lon = (fix.coordinate.longitude * 100).rounded() / 100
        let previous = systemFix.flatMap { old -> WeatherCity? in
            let point = CLLocation(latitude: old.city.latitude, longitude: old.city.longitude)
            return point.distance(from: fix) < 5_000 ? old.city : nil
        }
        let city = WeatherCity(id: -1, name: previous?.name ?? "当前位置", country: previous?.country ?? "",
                               latitude: lat, longitude: lon, timezone: previous?.timezone)
        if systemFix?.city.isSameLocation(as: city) != true {
            cancelWeather()
            cancelRetry(resetAttempts: true)
            cancelGeocoding()
        }
        systemFix = SystemFix(city: city, timestamp: fix.timestamp, accuracy: fix.horizontalAccuracy)
        confirmedLocationThisRun = true
        isLocationStale = now().timeIntervalSince(fix.timestamp) >= Self.locationFreshAge
        if !isLocationStale {
            locationRetryTask?.cancel()
            locationRetryTask = nil
            locationRetryAttempt = 0
            if isLocating {
                locationDriver.stop()
                locationTimeout?.cancel()
                locationTimeout = nil
                isLocating = false
                isLoading = weatherTask != nil
            }
        }
        locationUpdatedAt = fix.timestamp
        locationStatus = isLocationStale ? "使用上次系统位置，位置待更新" : "已取得系统大致位置"
        selectedCity = city
        persistCity()
        persistSystemFix()
        reverseGeocode(CLLocation(latitude: lat, longitude: lon), city: city)
        if finishRequest && isLocationStale { scheduleLocationRetry() }
    }

    private func locationRequestFailed(_ error: Error) {
        guard followsLocation, locationRequestsEnabled, isLocating else { return }
        let failure = error as NSError
        let denied = failure.domain == kCLErrorDomain && failure.code == CLError.denied.rawValue
        // requestLocation ends on locationUnknown; retry after backoff rather than leaving it stuck.
        locationFailed(denied ? "macOS 未允许定位；允许后将自动恢复" : "系统定位暂不可用，将自动重试", retryable: !denied)
    }

    private func reverseGeocode(_ fix: CLLocation, city: WeatherCity) {
        guard followsLocation, geocodeTask == nil else { return }
        if city.name != "当前位置", let previous = lastGeocodedLocation, let time = lastGeocodedAt,
           previous.distance(from: fix) < 5_000, now().timeIntervalSince(time) < 6 * 60 * 60 { return }
        geocodeRetryTask?.cancel()
        geocodeRetryTask = nil
        geocodeGeneration = UUID()
        let generation = geocodeGeneration
        // City naming is optional and never delays or prevents the weather fetch.
        let coarseFix = CLLocation(latitude: city.latitude, longitude: city.longitude)
        geocodeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.geocodeGeneration {
                    self.geocodeTask = nil
                    self.geocodeTimeout?.cancel()
                    self.geocodeTimeout = nil
                }
            }
            do {
                let place = try await self.locationDriver.placeName(for: coarseFix)
                guard !Task.isCancelled, self.followsLocation, generation == self.geocodeGeneration,
                      self.selectedCity?.isSameLocation(as: city) == true else { return }
                guard let place, !place.name.isEmpty else {
                    self.scheduleGeocodeRetry(for: city)
                    return
                }
                let namedCity = WeatherCity(id: -1, name: place.name,
                                           country: place.country, latitude: city.latitude, longitude: city.longitude,
                                           timezone: place.timezone)
                self.lastGeocodedAt = self.now() // Cache successes only; failures retry with bounded backoff.
                self.lastGeocodedLocation = coarseFix
                self.geocodeRetryAttempt = 0
                self.selectedCity = namedCity
                if self.systemFix?.city.isSameLocation(as: city) == true {
                    self.systemFix?.city = namedCity
                    self.persistSystemFix()
                }
                self.persistCity()
                if self.snapshot?.city.isSameLocation(as: city) == true {
                    self.snapshot?.city = namedCity
                    self.persistSnapshot()
                }
            } catch {
                guard !Task.isCancelled, generation == self.geocodeGeneration else { return }
                self.scheduleGeocodeRetry(for: city)
            }
        }
        geocodeTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, generation == self.geocodeGeneration,
                  self.geocodeTask != nil else { return }
            self.geocodeGeneration = UUID()
            self.geocodeTask?.cancel()
            self.geocodeTask = nil
            self.locationDriver.cancelGeocoding()
            self.geocodeTimeout = nil
            self.scheduleGeocodeRetry(for: city)
        }
    }

    private func locationFailed(_ message: String, retryable: Bool = true) {
        locationDriver.stop()
        locationTimeout?.cancel()
        locationTimeout = nil
        awaitingAuthorization = false
        isLocating = false
        isLoading = weatherTask != nil
        isLocationStale = true
        locationStatus = message
        if usableSystemFix != nil && locationDriver.authorizationStatus == .authorizedAlways {
            // Failure to acquire a newer fix must not starve weather at a recent system fix.
            refreshWeatherFromSystemFix(force: false)
            isLocationStale = true
            if let snapshot, !isStale { status = "已更新 · \(Self.dateLabel(snapshot.fetchedAt))" + locationSuffix }
        } else {
            isStale = true
            status = cachedStatus(message)
        }
        if retryable { scheduleLocationRetry() }
        else { locationRetryTask?.cancel(); locationRetryTask = nil }
    }

    private func scheduleLocationRetry() {
        guard automaticRetriesEnabled, locationRequestsEnabled, followsLocation, locationRetryTask == nil else { return }
        let delay = retryDelays[min(locationRetryAttempt, retryDelays.count - 1)]
        locationRetryAttempt = min(locationRetryAttempt + 1, retryDelays.count - 1)
        let token = locationGeneration
        locationRetryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled, self.automaticRetriesEnabled, self.locationGeneration == token else { return }
            self.locationRetryTask = nil
            self.requestCoarseLocation(allowPrompt: true)
        }
    }

    private func scheduleRetry() {
        guard automaticRetriesEnabled, retryTask == nil else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt = min(retryAttempt + 1, retryDelays.count - 1)
        let weatherToken = weatherGeneration
        status += " · 将自动重试"
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.automaticRetriesEnabled,
                  self.weatherGeneration == weatherToken else { return }
            self.retryTask = nil
            if self.followsLocation { self.refreshWeatherFromSystemFix(force: true) }
            else if let city = self.selectedCity { self.fetchWeather(for: city, force: true) }
        }
    }

    private func cancelRetry(resetAttempts: Bool) {
        retryTask?.cancel()
        retryTask = nil
        if resetAttempts { retryAttempt = 0 }
    }

    private func scheduleGeocodeRetry(for city: WeatherCity) {
        guard automaticRetriesEnabled, followsLocation, geocodeRetryTask == nil,
              selectedCity?.isSameLocation(as: city) == true else { return }
        let delay = retryDelays[min(geocodeRetryAttempt, retryDelays.count - 1)]
        geocodeRetryAttempt = min(geocodeRetryAttempt + 1, retryDelays.count - 1)
        let token = locationGeneration
        geocodeRetryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.automaticRetriesEnabled, self.followsLocation,
                  self.locationGeneration == token,
                  let selected = self.selectedCity, selected.isSameLocation(as: city) else { return }
            self.geocodeRetryTask = nil
            self.reverseGeocode(CLLocation(latitude: city.latitude, longitude: city.longitude), city: selected)
        }
    }

    private func cancelWeather() {
        weatherGeneration = UUID()
        weatherTask?.cancel()
        weatherTask = nil
        isLoading = isLocating
    }

    private func cancelSearch() {
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func cancelLocation() {
        locationGeneration = UUID()
        locationDriver.stop()
        locationTimeout?.cancel()
        locationTimeout = nil
        locationRetryTask?.cancel()
        locationRetryTask = nil
        locationRetryAttempt = 0
        cancelGeocoding()
        awaitingAuthorization = false
        isLocating = false
    }

    private func cancelGeocoding() {
        geocodeGeneration = UUID()
        geocodeTask?.cancel()
        geocodeTask = nil
        geocodeRetryTask?.cancel()
        geocodeRetryTask = nil
        geocodeTimeout?.cancel()
        geocodeTimeout = nil
        geocodeRetryAttempt = 0
        locationDriver.cancelGeocoding()
    }

    private func persistSystemFix() {
        if let fix = systemFix, let data = try? JSONEncoder().encode(fix) { defaults.set(data, forKey: Self.systemFixKey) }
    }

    private func startNetworkMonitor() {
        guard monitorsNetwork, networkMonitor == nil else { return }
        networkGeneration = UUID()
        let token = networkGeneration
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.automaticRetriesEnabled, self.networkGeneration == token else { return }
                if !satisfied { self.networkWasUnavailable = true }
                else if self.networkWasUnavailable {
                    self.networkWasUnavailable = false
                    self.locationRetryTask?.cancel()
                    self.locationRetryTask = nil
                    self.cancelRetry(resetAttempts: true)
                    self.refresh(force: true)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "PulseBar.weather.network", qos: .utility))
    }

    private func persistCity() {
        if let city = selectedCity, let data = try? JSONEncoder().encode(city) {
            defaults.set(data, forKey: Self.cityKey)
        }
    }

    private func persistSnapshot() {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    private func cachedStatus(_ message: String) -> String {
        guard let snapshot else { return message }
        return "\(message) · 显示\(snapshot.city.name)缓存（\(Self.dateLabel(snapshot.fetchedAt))）"
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
