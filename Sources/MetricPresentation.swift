import Foundation

/// Trend compares the two most recent consecutive valid samples. A gap or an
/// unchanged value never becomes a made-up direction.
enum MetricTrend: Equatable {
    case rising, falling, steady, unknown
    init(values: [Double]) {
        guard values.count >= 2 else { self = .unknown; return }
        let recent = values.suffix(2)
        guard let previous = recent.first, let latest = recent.last,
              previous.isFinite, latest.isFinite else { self = .unknown; return }
        self = latest > previous ? .rising : (latest < previous ? .falling : .steady)
    }
    var label: String {
        switch self {
        case .rising: return "上升"
        case .falling: return "下降"
        case .steady: return "持平"
        case .unknown: return "等待采样"
        }
    }
}

struct BatterySnapshot: Sendable {
    let sampledAt: Date
    let percent: Double?
    let charging: Bool
    let onACPower: Bool
    let fullyCharged: Bool
    let chargeLimitPercent: Double?
    let chargeLimitReached: Bool
    let remainingEnergyWh: Double?
    let fullChargeEnergyWh: Double?
    let netPowerWatts: Double?
    let precisePercent: Double?

    init(sampledAt: Date, percent: Double?, charging: Bool, onACPower: Bool,
         fullyCharged: Bool = false, chargeLimitPercent: Double? = nil,
         chargeLimitReached: Bool = false, remainingEnergyWh: Double? = nil,
         fullChargeEnergyWh: Double? = nil, netPowerWatts: Double? = nil,
         precisePercent: Double? = nil) {
        self.sampledAt = sampledAt
        self.percent = percent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        self.charging = charging
        self.onACPower = onACPower
        self.fullyCharged = fullyCharged
        self.chargeLimitPercent = chargeLimitPercent.flatMap {
            $0.isFinite && (1...100).contains($0) ? $0 : nil
        }
        self.chargeLimitReached = chargeLimitReached && onACPower && !charging
        self.remainingEnergyWh = remainingEnergyWh.flatMap {
            $0.isFinite && (0...750).contains($0) ? $0 : nil
        }
        self.fullChargeEnergyWh = fullChargeEnergyWh.flatMap {
            $0.isFinite && $0 > 0 && $0 <= 750 ? $0 : nil
        }
        self.netPowerWatts = netPowerWatts.flatMap {
            $0.isFinite && abs($0) <= 750 ? $0 : nil
        }
        self.precisePercent = precisePercent.flatMap {
            $0.isFinite && (0...100).contains($0) ? $0 : nil
        }
    }
    var displayState: BatteryDisplayState {
        guard percent != nil else { return .unknown }
        return BatteryDisplayState(charging: charging, onACPower: onACPower,
                                   fullyCharged: fullyCharged, chargeLimitReached: chargeLimitReached,
                                   chargeLimitPercent: chargeLimitPercent)
    }
}

struct BatteryHistoryPoint: Equatable, Sendable {
    let sampledAt: Date
    let percent: Double
}

/// A missing reading or a gap starts a new segment, rather than drawing a line
/// across sleep, missing hardware data, or a backwards system-clock adjustment.
struct BatteryHistory {
    static let samplingInterval: TimeInterval = 5
    static let duration: TimeInterval = 10 * 60
    static let maximumPoints = 120
    private(set) var points: [BatteryHistoryPoint] = []
    private var usesPreciseCapacity: Bool?

    mutating func append(_ reading: BatterySnapshot) {
        guard reading.percent != nil, let percent = reading.precisePercent ?? reading.percent,
              reading.sampledAt.timeIntervalSince1970.isFinite else { reset(); return }
        let precise = reading.precisePercent != nil
        // Never join differently calibrated percentages into a fictional jump.
        if let previous = usesPreciseCapacity, previous != precise { points.removeAll() }
        usesPreciseCapacity = precise
        if let last = points.last {
            let elapsed = reading.sampledAt.timeIntervalSince(last.sampledAt)
            if elapsed <= 0 || elapsed > Self.samplingInterval * 3 { points.removeAll() }
        }
        let oldest = reading.sampledAt.addingTimeInterval(-Self.duration)
        points.removeAll { $0.sampledAt < oldest }
        points.append(BatteryHistoryPoint(sampledAt: reading.sampledAt, percent: percent))
        if points.count > Self.maximumPoints { points.removeFirst(points.count - Self.maximumPoints) }
    }
    mutating func reset() { points.removeAll(); usesPreciseCapacity = nil }
}

enum BatteryDisplayState: Equatable {
    case charging, pluggedIn, discharging, fullyCharged, chargeLimited(Double?), unknown
    init(charging: Bool, onACPower: Bool, fullyCharged: Bool = false,
         chargeLimitReached: Bool = false, chargeLimitPercent: Double? = nil) {
        if !onACPower { self = charging ? .unknown : .discharging }
        else if charging { self = .charging }
        else if chargeLimitReached {
            self = .chargeLimited(chargeLimitPercent.flatMap {
                $0.isFinite && (1...100).contains($0) ? $0 : nil
            })
        }
        else { self = fullyCharged ? .fullyCharged : .pluggedIn }
    }
    var label: String {
        switch self {
        case .charging: return "已接电源，电池在充电"
        case .pluggedIn: return "已接电源，电池未充电"
        case .discharging: return "未接电源，电池在放电"
        case .fullyCharged: return "已接电源，电池已充满"
        case .chargeLimited(let limit):
            return "已接电源 · 已达充电上限" + limit.map { String(format: " %.0f%%", $0) }.orEmpty
        case .unknown: return "读取电量"
        }
    }
    var description: String {
        switch self {
        case .chargeLimited(let limit):
            return "已接电源，已达到充电上限" + limit.map { String(format: " %.0f%%", $0) }.orEmpty + "，电池未充电"
        case .unknown: return "等待电源数据"
        default: return label
        }
    }
    var symbol: String {
        self == .charging ? "battery.100percent.bolt" : "battery.100percent"
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
