import Foundation
@main struct MetricPresentationTests {
    static func main() {
        let cases: [([Double], MetricTrend)] = [([], .unknown), ([30], .unknown),
            ([30, 31], .rising), ([30, 29], .falling), ([30, 30], .steady),
            ([90, 10, 11], .rising), ([1, 90, 89], .falling),
            ([1, .nan], .unknown), ([.infinity, 30], .unknown)]
        for (values, expected) in cases { precondition(MetricTrend(values: values) == expected) }
        precondition(BatteryDisplayState(charging: true, onACPower: true) == .charging)
        precondition(BatteryDisplayState(charging: false, onACPower: true) == .pluggedIn)
        precondition(BatteryDisplayState(charging: false, onACPower: false) == .discharging)
        print("12 trend and battery state checks passed.")
    }
}
