import Foundation

enum BatteryEstimateUnavailableReason: Equatable, Sendable {
    case readingUnavailable, notCharging, insufficientPower
}

/// An estimate from battery energy and net battery power, never from adapter
/// wattage or macOS's previously cached time-to-empty/time-to-full fields.
enum BatteryTimeEstimate: Equatable, Sendable {
    case discharging(minutes: Int)
    case charging(minutes: Int)
    case restored
    case unavailable(BatteryEstimateUnavailableReason)

    var text: String {
        switch self {
        case .discharging(let minutes), .charging(let minutes):
            guard minutes < 6_000 else { return "99H+" }
            let value = max(0, minutes)
            return "\(value / 60)H\(value % 60)m"
        // The UI draws its own vector recovery mark; this semantic fallback is
        // retained for diagnostics and non-visual consumers only.
        case .restored: return "已恢复"
        case .unavailable(.readingUnavailable): return "计算中"
        case .unavailable(.notCharging): return "未充电"
        case .unavailable(.insufficientPower): return "采样中"
        }
    }

    var caption: String {
        switch self {
        case .discharging: return "预计可用"
        case .charging: return "预计充至80%"
        case .restored: return "电量已经恢复"
        case .unavailable(.readingUnavailable): return "等待有效采样"
        case .unavailable(.notCharging): return "等待开始充电"
        case .unavailable(.insufficientPower): return "等待功率更新"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .discharging(let minutes): return "按近期放电功率预计可用约" + Self.spokenDuration(minutes)
        case .charging(let minutes): return "按近期净充电功率预计充至百分之八十约需" + Self.spokenDuration(minutes)
        case .restored: return "已接电源，电量已达到百分之八十，电量已经恢复"
        case .unavailable: return caption + "，" + text
        }
    }

    private static func spokenDuration(_ minutes: Int) -> String {
        guard minutes < 6_000 else { return "超过九十九小时" }
        let value = max(0, minutes)
        return "\(value / 60)小时\(value % 60)分钟"
    }
}

/// Constant-memory, time-weighted smoothing: a five-second sample weighs about
/// 15% with the default 30-second time constant. Gaps, source transitions and
/// invalid current measurements expire old power within a short grace period.
/// An opposite power direction or source change discards it immediately. No timer lives
/// here; the existing five-second hardware sampler drives the estimator.
struct BatteryTimeEstimator {
    static let powerTimeConstant: TimeInterval = 30
    static let maximumSampleGap: TimeInterval = 20
    static let minimumUsablePowerWatts = 0.25
    static let powerGracePeriod: TimeInterval = 15
    private(set) var estimate: BatteryTimeEstimate = .unavailable(.readingUnavailable)
    private var smoothedPowerWatts: Double?
    private var lastSampleDate: Date?
    private var wasOnACPower: Bool?

    @discardableResult
    mutating func append(_ reading: BatterySnapshot) -> BatteryTimeEstimate {
        guard reading.sampledAt.timeIntervalSince1970.isFinite,
              let percent = reading.percent,
              percent.isFinite, (0...100).contains(percent) else {
            return invalidate(.readingUnavailable)
        }

        // This is a user-selected 80% recovery target, not an assertion that
        // macOS has enabled a hardware charging limit or stopped charging.
        if reading.onACPower && percent >= 80 {
            reset()
            estimate = .restored
            return estimate
        }
        if reading.onACPower && !reading.charging { return invalidate(.notCharging) }
        if !reading.onACPower && reading.charging { return invalidate(.readingUnavailable) }

        let energyWh: Double
        if reading.onACPower {
            guard let fullWh = reading.fullChargeEnergyWh, fullWh > 0 else {
                return invalidate(.readingUnavailable)
            }
            energyWh = fullWh * ((80 - percent) / 100)
        } else {
            guard let remainingWh = reading.remainingEnergyWh, remainingWh >= 0 else {
                return invalidate(.readingUnavailable)
            }
            // A usable remaining-energy reading does not depend on a separate
            // full-capacity field. Mild gauge recalibration is capped at full.
            if let fullWh = reading.fullChargeEnergyWh {
                guard remainingWh <= fullWh * 1.1 else { return invalidate(.readingUnavailable) }
                energyWh = min(remainingWh, fullWh)
            } else {
                energyWh = remainingWh
            }
        }
        guard energyWh.isFinite, energyWh >= 0 else { return invalidate(.readingUnavailable) }

        let elapsed = lastSampleDate.map { reading.sampledAt.timeIntervalSince($0) }
        let signedPower = reading.netPowerWatts
        let currentPower = signedPower.map { reading.onACPower ? $0 : -$0 }
        if let currentPower, currentPower < 0 { return invalidate(.insufficientPower) }
        // A missed/zero measurement can retain the last measured same-mode
        // average for at most 15 seconds. This never extends its timestamp,
        // survives sleep, crosses plug/unplug, or conceals opposite power flow.
        if currentPower == nil || abs(currentPower!) < Self.minimumUsablePowerWatts {
            if wasOnACPower == reading.onACPower, let elapsed,
               elapsed > 0, elapsed <= Self.powerGracePeriod, let watts = smoothedPowerWatts {
                return updateEstimate(energyWh: energyWh, watts: watts, onACPower: reading.onACPower)
            }
            return invalidate(currentPower == nil ? .readingUnavailable : .insufficientPower)
        }
        guard let currentPower, currentPower.isFinite, abs(currentPower) <= 500 else {
            return invalidate(.readingUnavailable)
        }
        guard currentPower >= Self.minimumUsablePowerWatts else { return invalidate(.insufficientPower) }

        // Apple calibrates the displayed percent separately from raw mAh/FCC.
        // Use the visible percentage deficit for this user's visible 80% target,
        // mapped linearly onto current full energy. The raw ratio is only for
        // the fine-grained trend. Charge taper changes later power samples;
        // this is a continuously updated approximation, not a promised finish.
        if wasOnACPower != reading.onACPower || elapsed == nil ||
            elapsed! <= 0 || elapsed! > Self.maximumSampleGap {
            smoothedPowerWatts = currentPower
        } else if let previousPower = smoothedPowerWatts, let elapsed {
            let weight = 1 - exp(-elapsed / Self.powerTimeConstant)
            smoothedPowerWatts = previousPower + weight * (currentPower - previousPower)
        } else {
            smoothedPowerWatts = currentPower
        }
        lastSampleDate = reading.sampledAt
        wasOnACPower = reading.onACPower

        guard let watts = smoothedPowerWatts else { return invalidate(.readingUnavailable) }
        return updateEstimate(energyWh: energyWh, watts: watts, onACPower: reading.onACPower)
    }

    private mutating func updateEstimate(energyWh: Double, watts: Double,
                                        onACPower: Bool) -> BatteryTimeEstimate {
        let totalMinutes = energyWh / watts * 60
        guard totalMinutes.isFinite, totalMinutes >= 0 else {
            return invalidate(.readingUnavailable)
        }
        // Round upward so a partially remaining minute is not shown as empty.
        // Saturate safely before integer conversion, with an explicit 99H+ UI.
        let minutes = Int(min(6_000, ceil(totalMinutes)))
        estimate = onACPower ? .charging(minutes: minutes) : .discharging(minutes: minutes)
        return estimate
    }

    mutating func reset() {
        estimate = .unavailable(.readingUnavailable)
        smoothedPowerWatts = nil
        lastSampleDate = nil
        wasOnACPower = nil
    }

    private mutating func invalidate(_ reason: BatteryEstimateUnavailableReason) -> BatteryTimeEstimate {
        reset()
        estimate = .unavailable(reason)
        return estimate
    }
}
