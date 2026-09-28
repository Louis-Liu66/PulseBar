import Foundation

/// Two deterministic, local-only lines derived from the current weather payload.
/// The overview stays limited to current conditions and clothing.
struct WeatherAdvice: Equatable, Sendable {
    let condition: String
    let clothing: String

    var text: String { condition + "。" + clothing + "。" }

    static func make(from snapshot: WeatherSnapshot?) -> WeatherAdvice {
        guard let snapshot else {
            return WeatherAdvice(condition: "天气待更新", clothing: "穿衣建议待更新")
        }

        let feltTemperature = snapshot.apparentTemperatureCelsius ?? snapshot.temperatureCelsius
        return WeatherAdvice(
            condition: conditionLine(for: snapshot.weatherCode),
            clothing: clothingLine(for: feltTemperature)
        )
    }

    private static func conditionLine(for code: Int) -> String {
        switch code {
        case 0: return "天气晴朗"
        case 1: return "大致晴朗"
        case 2: return "局部多云"
        case 3: return "阴天"
        case 45, 48: return "有雾"
        case 51, 53, 55: return "毛毛雨"
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
        case 85: return "小阵雪"
        case 86: return "强阵雪"
        case 95: return "雷雨"
        case 96, 99: return "雷暴伴冰雹"
        default: return "天气待更新"
        }
    }

    private static func clothingLine(for temperature: Double) -> String {
        switch temperature {
        case ...0: return "穿厚羽绒服"
        case ...8: return "穿厚外套"
        case ...15: return "穿保暖外套"
        case ...23: return "穿长袖上衣"
        case ...28: return "穿轻薄单衣"
        case ...34: return "穿透气短袖"
        default: return "穿轻薄衣物"
        }
    }
}
