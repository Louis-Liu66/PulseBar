import Foundation

@main struct BatteryEstimateTests {
    static var checks = 0
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }
    static func reading(seconds: Double = 0, percent: Double? = 60, precise: Double? = nil,
                        remaining: Double? = 30, full: Double? = 50, power: Double? = -10,
                        ac: Bool = false, charging: Bool = false) -> BatterySnapshot {
        BatterySnapshot(sampledAt: origin.addingTimeInterval(seconds), percent: percent,
                        charging: charging, onACPower: ac, remainingEnergyWh: remaining,
                        fullChargeEnergyWh: full, netPowerWatts: power, precisePercent: precise)
    }
    static func main() {
        var estimator = BatteryTimeEstimator()
        check(estimator.estimate == .unavailable(.readingUnavailable), "Initial display has no invented duration")
        check(estimator.append(reading()) == .discharging(minutes: 180), "30 Wh divided by 10 W gives three hours")
        check(estimator.estimate.text == "3H0m", "Duration uses requested H/m format")
        check(estimator.estimate.caption == "预计可用", "Unplugged duration is remaining use")
        check(estimator.append(reading(seconds: 5, percent: 60, power: 20, ac: true, charging: true)) == .charging(minutes: 30), "Charging uses net battery power and energy needed to reach 80%, without previous discharge average")
        check(estimator.estimate.caption == "预计充至80%", "Charging target is visible")
        check(estimator.append(reading(seconds: 10, percent: 85, remaining: 42.5, power: -5)) == .discharging(minutes: 510), "Unplugging above 80% shows available use rather than infinity")
        check(estimator.append(reading(seconds: 15, percent: 80, remaining: nil, full: nil, power: nil, ac: true)) == .restored, "At 80% and connected, no unavailable power field prevents recovery state")
        check(estimator.estimate.text == "已恢复" && estimator.estimate.caption == "电量已经恢复", "Recovered state exposes semantic fallback while UI draws the vector mark")
        check(estimator.append(reading(seconds: 20, percent: 90, power: 20, ac: true, charging: true)) == .restored, "Connected above 80% is recovered even if still charging")
        check(estimator.append(reading(seconds: 25, percent: 80, precise: 77, remaining: 38.5, power: 10, ac: true, charging: true)) == .restored, "Recovery follows the visible system percentage rather than a differently calibrated raw ratio")
        check(estimator.append(reading(seconds: 30, percent: 79, precise: 80, remaining: 40, power: 0, ac: true)) == .unavailable(.notCharging), "Raw 80% must not signal recovery while the system-visible charge is below target")
        check(estimator.append(reading(seconds: 35, percent: 79, remaining: 39.5, power: 0, ac: true)) == .unavailable(.notCharging), "Connected below target but not charging has no charge ETA")
        check(estimator.estimate.text == "未充电", "Not-charging state is explicit")
        check(estimator.append(reading(seconds: 40, power: 0)) == .unavailable(.insufficientPower), "Zero current power never divides by zero or reuses the old estimate")
        check(estimator.append(reading(seconds: 45, power: -0.1)) == .unavailable(.insufficientPower), "Near-zero battery current does not produce an implausible precise duration")
        check(estimator.append(reading(seconds: 50, power: 5)) == .unavailable(.insufficientPower), "Wrong-direction unplugged power invalidates stale discharge data")
        check(estimator.append(reading(seconds: 55, power: -5, ac: true, charging: true)) == .unavailable(.insufficientPower), "Connected battery that is net discharging has no invented charge time")
        check(estimator.append(reading(seconds: 60, power: -5)) == .discharging(minutes: 360), "Valid data after a bad direction starts a fresh estimate")

        estimator.reset()
        _ = estimator.append(reading(power: -10))
        let smoothed = estimator.append(reading(seconds: 5, power: -20))
        let expected = Int(ceil(30 / (10 + (1 - exp(-5.0 / 30)) * 10) * 60))
        check(smoothed == .discharging(minutes: expected), "EMA weight follows actual elapsed seconds")
        check(expected > 90 && expected < 180, "A brief load jump is smoothed without freezing the estimate")
        check(estimator.append(reading(seconds: 26, power: -5)) == .discharging(minutes: 360), "Sample gap over 20 seconds discards prior load")
        check(estimator.append(reading(seconds: 26, power: -10)) == .discharging(minutes: 180), "Duplicate timestamps do not mix stale power")
        check(estimator.append(reading(seconds: 25, power: -20)) == .discharging(minutes: 90), "Clock rollback starts a fresh window")
        estimator.reset()
        check(estimator.estimate == .unavailable(.readingUnavailable), "Sleep or stop reset removes the display estimate")
        check(estimator.append(reading(seconds: 30, power: -2)) == .discharging(minutes: 900), "Explicit reset discards previous power")

        for bad in [reading(seconds: 35, remaining: nil),
                    reading(seconds: 35, power: nil), reading(seconds: 35, remaining: .nan),
                    reading(seconds: 35, remaining: -1), reading(seconds: 35, remaining: 60),
                    reading(seconds: 35, power: .nan), reading(seconds: 35, power: .infinity),
                    reading(seconds: 35, power: -501), reading(seconds: 35, percent: nil),
                    reading(seconds: 35, charging: true)] {
            check(estimator.append(bad) == .unavailable(.readingUnavailable), "Invalid or contradictory live data removes stale ETA")
        }
        check(estimator.append(reading(seconds: 40, power: -15)) == .discharging(minutes: 120), "Invalid samples erase the old power average")
        check(estimator.append(reading(seconds: 65, percent: 0, remaining: 0, power: -10)) == .discharging(minutes: 0), "A genuinely depleted battery can show zero")
        check(estimator.estimate.text == "0H0m", "Zero duration still uses the specified format")
        check(estimator.append(reading(seconds: 90, percent: 0.01, remaining: 0.005, power: -10)) == .discharging(minutes: 1), "A positive subminute duration rounds upward")
        check(estimator.append(reading(seconds: 120, remaining: 100, full: 100, power: -0.25)) == .discharging(minutes: 6_000), "Unusually long duration is safely bounded")
        check(estimator.estimate.text == "99H+", "Large values do not overflow the narrow layout")
        check(BatteryTimeEstimate.discharging(minutes: 5_999).text == "99H59m", "Maximum exact display fits the duration format")
        check(BatteryTimeEstimate.discharging(minutes: Int.max).text == "99H+", "Formatting handles even maximal integer duration")
        check(BatteryTimeEstimate.discharging(minutes: -10).text == "0H0m", "Defensive formatting never displays a negative duration")
        check(BatteryTimeEstimate.charging(minutes: 145).accessibilityDescription.contains("2小时25分钟"), "VoiceOver describes units and approximate charge duration")
        check(estimator.append(reading(seconds: 150, percent: 55, precise: 52, remaining: 26, full: 50, power: 10, ac: true, charging: true)) == .charging(minutes: 75), "Charging target uses the calibrated visible percentage deficit even when raw capacity ratio is 52%")
        check(estimator.append(reading(seconds: 175, percent: 79, precise: 80, remaining: 40, full: 50, power: 10, ac: true, charging: true)) == .charging(minutes: 3), "Raw capacity above a target does not manufacture zero while the system-visible percentage is below target")
        check(estimator.append(reading(seconds: .infinity)) == .unavailable(.readingUnavailable), "Invalid sample dates cannot update the average")
        estimator.reset()
        check(estimator.append(reading(full: nil)) == .discharging(minutes: 180), "Discharge estimate only requires remaining energy and measured power")
        check(estimator.append(reading(seconds: 5, power: 0)) == .discharging(minutes: 180), "One zero-current dropout retains recent measured discharge power")
        check(estimator.append(reading(seconds: 10, remaining: 29, power: nil)) == .discharging(minutes: 174), "Missing power uses current energy with the same recent average")
        check(estimator.append(reading(seconds: 15, power: 0)) == .discharging(minutes: 180), "Grace lasts no more than fifteen seconds from a valid reading")
        check(estimator.append(reading(seconds: 20, power: 0)) == .unavailable(.insufficientPower), "Repeated missing samples cannot extend grace indefinitely")
        check(estimator.estimate.text == "采样中", "No power reading is described as sampling instead of a battery failure")
        check(estimator.append(reading(seconds: 25, power: -20)) == .discharging(minutes: 90), "Expired average is reseeded by fresh power")
        check(estimator.append(reading(seconds: 30, power: 20)) == .unavailable(.insufficientPower), "Opposite-direction power immediately invalidates retained discharge data")
        _ = estimator.append(reading(seconds: 35))
        check(estimator.append(reading(seconds: 40, power: 0.1)) == .unavailable(.insufficientPower), "Even small opposite-direction power must not retain the old average")
        estimator.reset()
        _ = estimator.append(reading())
        check(estimator.append(reading(seconds: 5, power: 0, ac: true, charging: true)) == .unavailable(.insufficientPower), "No discharge average carries into charging")
        _ = estimator.append(reading(seconds: 10, power: 10, ac: true, charging: true))
        check(estimator.append(reading(seconds: 15, power: 0)) == .unavailable(.insufficientPower), "No charge average carries into discharge")
        _ = estimator.append(reading(seconds: 20, percent: 80, power: 0, ac: true))
        check(estimator.append(reading(seconds: 25, percent: 80, power: 0)) == .unavailable(.insufficientPower), "Unplug never retains the recovered infinity state")
        check(estimator.append(reading(seconds: 30, percent: 80, remaining: 38.843, full: 47.764, power: -11.459)) == .discharging(minutes: 204), "Direct signed SMC power gives an ETA while old registry current is still zero")
        estimator.reset()
        check(estimator.append(reading(remaining: 50.01)) == .discharging(minutes: 300), "Mild raw-capacity recalibration is capped at full instead of hiding ETA")
        estimator.reset()
        _ = estimator.append(reading())
        check(estimator.append(reading(seconds: 60, power: nil)) == .unavailable(.readingUnavailable), "Long sleep gap cannot reuse old power")
        _ = estimator.append(reading(seconds: 65))
        check(estimator.append(reading(seconds: 64, power: 0)) == .unavailable(.insufficientPower), "Clock rollback cannot reuse a future estimate")
        estimator.reset()
        check(estimator.append(reading(full: nil, power: 10, ac: true, charging: true)) == .unavailable(.readingUnavailable), "Charging still requires full energy to calculate the target")
        _ = estimator.append(reading(seconds: 5, percent: 60, power: 10, ac: true, charging: true))
        check(estimator.append(reading(seconds: 10, percent: 70, power: nil, ac: true, charging: true)) == .charging(minutes: 30), "Charging grace recalculates from the current charge deficit")
        print("\(checks) battery energy, power smoothing, charging target and duration checks passed.")
    }
}
