import Foundation

@main struct WeatherAdviceTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            checks += 1
        }
        let city = WeatherCity(id: 1, name: "测试地区", country: "Test", latitude: -33.86,
                               longitude: 151.21, timezone: "Australia/Sydney")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(temp: Double, apparent: Double? = nil, code: Int = 2,
                      rain: Double? = 10) -> WeatherSnapshot {
            WeatherSnapshot(city: city, temperatureCelsius: temp, apparentTemperatureCelsius: apparent,
                            humidity: 50, windKmh: nil, weatherCode: code, isDay: true,
                            fetchedAt: now, observationTime: "fixture", precipitationProbability: rain,
                            sunrise: nil, sunset: nil, weatherTimeZone: city.timezone)
        }

        let clothing = [(-5.0, "厚羽绒服"), (5, "厚外套"), (12, "保暖外套"), (20, "长袖上衣"),
                        (26, "轻薄单衣"), (31, "透气短袖"), (38, "轻薄衣物")]
        for (temperature, phrase) in clothing {
            check(WeatherAdvice.make(from: snapshot(temp: temperature)).clothing.contains(phrase),
                  "temperature band: \(phrase)")
        }
        let conditions = [(0, "天气晴朗"), (2, "局部多云"), (3, "阴天"), (45, "有雾"),
                          (61, "小雨"), (73, "中雪"), (82, "强阵雨"), (96, "雷暴伴冰雹")]
        for (code, phrase) in conditions {
            check(WeatherAdvice.make(from: snapshot(temp: 20, code: code)).condition == phrase,
                  "weather condition: \(phrase)")
        }
        let deterministic = snapshot(temp: 14, code: 63, rain: 85)
        check(WeatherAdvice.make(from: deterministic) == WeatherAdvice.make(from: deterministic),
              "same input produces identical advice")
        let missingAll = WeatherAdvice.make(from: nil)
        check(missingAll.condition == "天气待更新" && missingAll.clothing == "穿衣建议待更新",
              "missing snapshot has two explicit status lines")
        let onlyRequestedContent = WeatherAdvice.make(from: snapshot(temp: 31, code: 61, rain: 95)).text
        check(!onlyRequestedContent.contains("下一小时") && !onlyRequestedContent.contains("伞") &&
              !onlyRequestedContent.contains("日出") && !onlyRequestedContent.contains("日落"),
              "overview stays limited to current condition and clothing")
        check(WeatherAdvice.make(from: snapshot(temp: 20, apparent: 6)).clothing.contains("厚外套"),
              "apparent temperature drives clothing advice when available")
        print("\(checks) deterministic two-line weather-advice checks passed.")
    }
}
