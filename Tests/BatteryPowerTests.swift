import Foundation

@main struct BatteryPowerTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        func reading(_ energy: Double? = nil, full: Double? = nil, power: Double? = nil,
                     precise: Double? = nil) -> BatterySnapshot {
            BatterySnapshot(sampledAt: Date(), percent: 55, charging: false, onACPower: false,
                            remainingEnergyWh: energy, fullChargeEnergyWh: full,
                            netPowerWatts: power, precisePercent: precise)
        }
        let old = reading()
        check(old.remainingEnergyWh == nil && old.fullChargeEnergyWh == nil &&
              old.netPowerWatts == nil && old.precisePercent == nil, "Old initializer remains compatible")
        let valid = reading(24, full: 48, power: -12, precise: 50)
        check(valid.remainingEnergyWh == 24 && valid.fullChargeEnergyWh == 48, "Measured energy retained")
        check(valid.netPowerWatts == -12, "Discharging power retains negative sign")
        check(valid.precisePercent == 50 && valid.percent == 55, "Raw trend does not overwrite macOS percent")
        check(reading(0, full: 48, power: 0, precise: 0).remainingEnergyWh == 0, "Zero remaining charge is valid")
        check(reading(power: 0).netPowerWatts == 0, "Zero current is not missing current")
        check(reading(power: 12).netPowerWatts == 12, "Charging power retains positive sign")
        check(reading(.nan, full: .infinity, power: -.infinity, precise: .nan).remainingEnergyWh == nil,
              "Nonfinite energy rejected")
        check(reading(full: .infinity).fullChargeEnergyWh == nil, "Nonfinite full energy rejected")
        check(reading(power: .nan).netPowerWatts == nil, "Nonfinite power rejected")
        check(reading(precise: .infinity).precisePercent == nil, "Nonfinite trend rejected")
        check(reading(-1, full: -1).remainingEnergyWh == nil && reading(full: 0).fullChargeEnergyWh == nil,
              "Negative energy and empty full capacity rejected")
        check(reading(1000, full: 1000, power: 1000, precise: 101).remainingEnergyWh == nil &&
              reading(full: 1000).fullChargeEnergyWh == nil && reading(power: -1000).netPowerWatts == nil &&
              reading(precise: 101).precisePercent == nil, "Implausible values rejected")
        if CommandLine.arguments.contains("--live") {
            // Selected values only; never registry identifiers or adapter details.
            let sampler = SystemSampler()
            var estimator = BatteryTimeEstimator()
            let count = CommandLine.arguments.contains("--watch") ? 24 : 1
            for index in 0..<count {
                let live = sampler.sampleBattery()
                let estimate = estimator.append(live)
                let registry = PBReadBattery()
                print("Live battery: macOS=\(live.percent.map { String(format: "%.1f%%", $0) } ?? "unavailable"), " +
                      "raw=\(live.precisePercent.map { String(format: "%.3f%%", $0) } ?? "unavailable"), " +
                      "energy=\(live.remainingEnergyWh.map { String(format: "%.3f Wh", $0) } ?? "unavailable"), " +
                      "full=\(live.fullChargeEnergyWh.map { String(format: "%.3f Wh", $0) } ?? "unavailable"), " +
                      "net=\(live.netPowerWatts.map { String(format: "%.3f W", $0) } ?? "unavailable"), " +
                      "AC=\(live.onACPower), charging=\(live.charging), ETA=\(estimate.text), " +
                      "registry=\(registry.powerValid ? String(format: "%.3f W", registry.netPowerWatts) : "unavailable")")
                fflush(stdout)
                if index + 1 < count { Thread.sleep(forTimeInterval: 5) }
            }
        }
        print("\(checks) battery snapshot power validation checks passed.")
    }
}
