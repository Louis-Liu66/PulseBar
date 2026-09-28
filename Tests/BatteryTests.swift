import Foundation

@main struct BatteryTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    static func snapshot(_ percent: Double?, seconds: Double = 0, charging: Bool = false,
                         ac: Bool = true, full: Bool = false, limit: Double? = nil,
                         held: Bool = false) -> BatterySnapshot {
        BatterySnapshot(sampledAt: origin.addingTimeInterval(seconds), percent: percent,
                        charging: charging, onACPower: ac, fullyCharged: full,
                        chargeLimitPercent: limit, chargeLimitReached: held)
    }
    static func policyData(limit: Any = 80, terminated: Bool = false, held: Bool = true,
                           boot: String = "TEST-BOOT", policyClass: String = "ChargeCtrlPolicy",
                           inRoot: Bool = true) -> Data {
        let ref: (Int) -> [String: Int] = { ["CF$UID": $0] }
        let archive: [String: Any] = [
            "$archiver": "NSKeyedArchiver", "$version": 100000,
            "$top": ["root": ref(1)],
            "$objects": ["$null", ["$class": ref(3), "NS.objects": inRoot ? [ref(2)] : []],
                         ["$class": ref(4), "soclimit": limit, "terminated": terminated, "isEndOfCharge": held],
                         ["$classname": "NSMutableArray"], ["$classname": policyClass]]
        ]
        let inner = try! PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        return try! PropertyListSerialization.data(fromPropertyList: ["bootSessionUUID": boot, "policies": inner], format: .binary, options: 0)
    }
    static func main() {
        check(snapshot(80).displayState == .pluggedIn, "80% and not charging does not prove a charge limit")
        check(snapshot(80, limit: 80).displayState == .pluggedIn, "A configured limit alone does not prove a limit hold")
        check(snapshot(80, charging: true, limit: 80, held: true).displayState == .charging, "Charging overrides stale limit metadata")
        check(snapshot(79, ac: false, limit: 80, held: true).displayState == .discharging, "An unplugged battery is not held by charging limit")
        check(snapshot(80, limit: 80, held: true).displayState == .chargeLimited(80), "Confirmed charge limit")
        check(snapshot(80, held: true).displayState == .chargeLimited(nil), "Unknown configured threshold is not inferred from percent")
        check(snapshot(100, full: true).displayState == .fullyCharged, "System-reported full state")
        check(snapshot(100).displayState == .pluggedIn, "Percent alone is not a full-state flag")
        check(snapshot(80, charging: true, ac: false).displayState == .unknown, "Inconsistent source flags are unknown")
        check(snapshot(nil, charging: true).displayState == .unknown, "Unavailable capacity is unknown")
        check(snapshot(.nan).percent == nil && snapshot(.infinity).percent == nil, "Nonfinite capacity rejected")
        check(snapshot(-1).percent == nil && snapshot(101).percent == nil, "Out-of-range capacity rejected")
        check(snapshot(80, limit: .nan, held: true).displayState == .chargeLimited(nil), "Invalid threshold omitted")
        check(snapshot(80, limit: 80, held: true).displayState.description.contains("80%"), "Full description includes confirmed threshold")
        check(snapshot(80).displayState.description == "已接电源，电池未充电", "Detailed connected status")
        check(snapshot(80, ac: false).displayState.description == "未接电源，电池在放电", "Detailed unplugged status")
        check(snapshot(80, charging: true).displayState.description == "已接电源，电池在充电", "Detailed charging status")
        check(BatteryHistory.samplingInterval == 5 && BatterySamplingTimer.interval == 5, "Production sampling interval is five seconds")
        var history = BatteryHistory()
        for i in 0..<500 { history.append(snapshot(80, seconds: Double(i) * 5)) }
        check(history.points.count == 120, "History remains bounded to ten minutes")
        check(history.points.first?.sampledAt == origin.addingTimeInterval(1900), "Old points expire")
        check(history.points.allSatisfy { $0.percent == 80 }, "Constant battery is a true flat line")
        check(zip(history.points, history.points.dropFirst()).allSatisfy { $1.sampledAt.timeIntervalSince($0.sampledAt) == 5 }, "History retains timestamps at five-second intervals")
        history.append(snapshot(79, seconds: 2500))
        check(history.points.last?.percent == 79, "Falling battery retains actual reading")
        history.append(snapshot(nil, seconds: 2505))
        check(history.points.isEmpty, "Invalid sample clears the segment")
        history.append(snapshot(78, seconds: 2510))
        check(history.points.count == 1, "No line bridges an invalid reading")
        history.append(snapshot(77, seconds: 3000))
        check(history.points.count == 1, "No line bridges a sleep or acquisition gap")
        history.append(snapshot(76, seconds: 2000))
        check(history.points.count == 1 && history.points[0].percent == 76, "Clock rollback starts a new segment")
        history.reset()
        check(history.points.isEmpty, "Pause clears history")
        history.append(BatterySnapshot(sampledAt: origin, percent: 55, charging: false, onACPower: false,
                                       precisePercent: 52.12))
        history.append(BatterySnapshot(sampledAt: origin.addingTimeInterval(5), percent: 55,
                                       charging: false, onACPower: false, precisePercent: 52.10))
        check(history.points.map(\.percent) == [52.12, 52.10], "Fine capacity changes remain visible while displayed percentage is unchanged")
        history.append(snapshot(55, seconds: 10))
        check(history.points.count == 1 && history.points[0].percent == 55, "Precision-source changes never draw a false jump")
        check(ChargeLimitPolicyDecoder.decode(policyData(), bootSessionUUID: "TEST-BOOT") == 80, "Active current-boot policy decoded")
        check(ChargeLimitPolicyDecoder.decode(policyData(), bootSessionUUID: "OLD-BOOT") == nil, "Previous-boot policy ignored")
        check(ChargeLimitPolicyDecoder.decode(policyData(terminated: true), bootSessionUUID: "TEST-BOOT") == nil, "Terminated policy ignored")
        check(ChargeLimitPolicyDecoder.decode(policyData(held: false), bootSessionUUID: "TEST-BOOT") == nil, "Policy not at end of charge ignored")
        check(ChargeLimitPolicyDecoder.decode(policyData(policyClass: "OtherClass"), bootSessionUUID: "TEST-BOOT") == nil, "Unknown archive classes are ignored")
        check(ChargeLimitPolicyDecoder.decode(policyData(inRoot: false), bootSessionUUID: "TEST-BOOT") == nil, "Unreferenced archived policy is ignored")
        check(ChargeLimitPolicyDecoder.decode(policyData(limit: true), bootSessionUUID: "TEST-BOOT") == nil, "Boolean limit rejected")
        check(ChargeLimitPolicyDecoder.decode(policyData(limit: 800), bootSessionUUID: "TEST-BOOT") == nil, "Out-of-range policy limit rejected")
        check(ChargeLimitPolicyDecoder.decode(policyData(limit: 80.5), bootSessionUUID: "TEST-BOOT") == nil, "Fractional policy limit rejected")
        check(ChargeLimitPolicyDecoder.decode(Data(repeating: 0, count: 65_537), bootSessionUUID: "TEST-BOOT") == nil, "Oversized policy file rejected")
        check(ChargeLimitPolicyDecoder.decode(Data("broken".utf8), bootSessionUUID: "TEST-BOOT") == nil, "Malformed policy ignored")
        let queue = DispatchQueue(label: "app.pulsebar.battery-tests")
        let signal = DispatchSemaphore(value: 0)
        let timer = BatterySamplingTimer()
        var sampled: [TimeInterval] = []
        timer.start(queue: queue, interval: 0.04) { sampled.append(ProcessInfo.processInfo.systemUptime); signal.signal() }
        timer.start(queue: queue, interval: 0.001) { preconditionFailure("A second start must not install another timer") }
        for _ in 0..<4 { check(signal.wait(timeout: .now() + 2) == .success, "Timer samples automatically") }
        timer.stop()
        let stoppedCount = queue.sync { sampled.count }
        Thread.sleep(forTimeInterval: 0.10)
        check(queue.sync { sampled.count } == stoppedCount, "Stopping prevents further polling")
        check(queue.sync { zip(sampled, sampled.dropFirst()).allSatisfy { $1 - $0 >= 0.015 } }, "Timer uses requested cadence rather than a tight polling loop")
        print("\(checks) battery state, charge-policy, history and timer checks passed.")
    }
}
