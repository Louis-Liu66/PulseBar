import Foundation
import Darwin

/// Decode only inert property-list values, never instantiate archived classes.
/// This optional macOS policy metadata is ignored unless it belongs to this boot.
enum ChargeLimitPolicyDecoder {
    static func decode(_ data: Data, bootSessionUUID: String) -> Double? {
        guard data.count <= 65_536, !bootSessionUUID.isEmpty,
              let outer = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let session = outer["bootSessionUUID"] as? String,
              session.caseInsensitiveCompare(bootSessionUUID) == .orderedSame,
              let policyData = outer["policies"] as? Data, policyData.count <= 32_768,
              let binary = try? PropertyListSerialization.propertyList(from: policyData, format: nil),
              // XML represents keyed-archive UID references as inert CF$UID maps.
              let xml = try? PropertyListSerialization.data(fromPropertyList: binary, format: .xml, options: 0),
              let xmlText = String(data: xml, encoding: .utf8),
              // Rename the key so Foundation does not turn it back into a private
              // UID object when reading the XML. No unarchiver is involved.
              let inertXML = xmlText.replacingOccurrences(of: "<key>CF$UID</key>",
                                                         with: "<key>PulseBarUID</key>").data(using: .utf8),
              let archive = (try? PropertyListSerialization.propertyList(from: inertXML, format: nil)) as? [String: Any],
              archive["$archiver"] as? String == "NSKeyedArchiver",
              let objects = archive["$objects"] as? [Any], objects.count <= 256,
              let top = archive["$top"] as? [String: Any] else { return nil }
        func object(_ reference: Any?) -> [String: Any]? {
            guard let map = reference as? [String: Any], let index = map["PulseBarUID"] as? Int,
                  objects.indices.contains(index) else { return nil }
            return objects[index] as? [String: Any]
        }
        guard let root = object(top["root"]),
              let rootClass = object(root["$class"])?["$classname"] as? String,
              ["NSArray", "NSMutableArray"].contains(rootClass),
              let references = root["NS.objects"] as? [Any] else { return nil }
        var limits: [Double] = []
        for reference in references {
            guard let policy = object(reference),
                  object(policy["$class"])?["$classname"] as? String == "ChargeCtrlPolicy",
                  let ended = policy["terminated"] as? NSNumber, CFGetTypeID(ended) == CFBooleanGetTypeID(), !ended.boolValue,
                  let held = policy["isEndOfCharge"] as? NSNumber, CFGetTypeID(held) == CFBooleanGetTypeID(), held.boolValue,
                  let number = policy["soclimit"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let limit = number.doubleValue
            if limit.isFinite && (1...100).contains(limit) && limit.rounded() == limit { limits.append(limit) }
        }
        return limits.min()
    }
}

private struct ChargeLimitPolicyReader {
    private var previousData: Data?
    private var previousLimit: Double?
    private let bootSessionUUID: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0, size <= 128 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }()
    mutating func read() -> Double? {
        guard let file = FileHandle(forReadingAtPath: "/Library/Preferences/com.apple.powerd.charging.plist") else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        if data == previousData { return previousLimit }
        previousData = data
        previousLimit = ChargeLimitPolicyDecoder.decode(data, bootSessionUUID: bootSessionUUID)
        return previousLimit
    }
}

/// Owned on the metrics serial queue. Cancellation and the AppModel generation
/// guard prevent a callback queued before sleep from publishing after resume.
final class BatterySamplingTimer {
    static let interval = BatteryHistory.samplingInterval
    private var timer: DispatchSourceTimer?
    func start(queue: DispatchQueue, interval: TimeInterval = BatterySamplingTimer.interval,
               handler: @escaping () -> Void) {
        guard timer == nil else { return }
        let next = DispatchSource.makeTimerSource(queue: queue)
        next.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(min(300, Int(interval * 100))))
        next.setEventHandler(handler: handler)
        timer = next
        next.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }
}

struct SystemSnapshot: Sendable {
    let sampledAt: Date
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64?
    let memoryTotalBytes: UInt64
    let batteryPercent: Double?
    let batteryCharging: Bool
    let onACPower: Bool
    let temperatureCelsius: Double?
    let temperatureSource: String
    let thermalState: String
    let sensorCount: Int
}

/// Own on one serial background queue; C IOKit and Mach calls never touch the UI.
final class SystemSampler {
    private let hardware = PBHardwareCreate()
    private var previousTicks: PBCPUTicks?
    private var previousTickTime: TimeInterval?
    private var chargeLimitPolicy = ChargeLimitPolicyReader()

    deinit { PBHardwareDestroy(hardware) }

    func sample(includeBattery: Bool = true) -> SystemSnapshot {
        let now = Date()
        let cpu = readCPU()
        let memory = PBReadMemory()
        let battery = includeBattery ? PBReadBattery() : PBBatteryReading()
        let temperature = PBReadTemperature(hardware)
        return SystemSnapshot(
            sampledAt: now,
            cpuPercent: cpu,
            memoryUsedBytes: memory.valid ? memory.usedBytes : nil,
            memoryTotalBytes: memory.totalBytes,
            batteryPercent: battery.valid ? battery.percent : nil,
            batteryCharging: battery.charging,
            onACPower: battery.onACPower,
            temperatureCelsius: temperature.valid ? temperature.celsius : nil,
            temperatureSource: temperature.valid ? "CPU 传感器最高值 · AppleSMC" : "CPU 温度传感器暂不可用",
            thermalState: thermalStateLabel,
            sensorCount: Int(temperature.sensorCount)
        )
    }

    func sampleBattery() -> BatterySnapshot {
        let reading = PBReadBatteryWithContext(hardware)
        let limit = reading.chargeLimited ? chargeLimitPolicy.read() : nil
        return BatterySnapshot(sampledAt: Date(), percent: reading.valid ? reading.percent : nil,
                               charging: reading.charging, onACPower: reading.onACPower,
                               fullyCharged: reading.fullyCharged, chargeLimitPercent: limit,
                               chargeLimitReached: reading.chargeLimited,
                               remainingEnergyWh: reading.energyValid ? reading.remainingEnergyWh : nil,
                               fullChargeEnergyWh: reading.energyValid ? reading.fullChargeEnergyWh : nil,
                               netPowerWatts: reading.powerValid ? reading.netPowerWatts : nil,
                               precisePercent: reading.energyValid ? reading.precisePercent : nil)
    }

    private func readCPU() -> Double? {
        var ticks = PBCPUTicks()
        guard PBReadCPUTicks(&ticks) else {
            previousTicks = nil
            previousTickTime = nil
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            previousTicks = ticks
            previousTickTime = now
        }
        // First sample and wake/resume establish a baseline rather than showing
        // a misleading average since boot or through an extended suspension.
        guard let before = previousTicks, let lastTime = previousTickTime,
              now > lastTime, now - lastTime < 60 else { return nil }
        let user = UInt64(ticks.user &- before.user)
        let system = UInt64(ticks.system &- before.system)
        let nice = UInt64(ticks.nice &- before.nice)
        let idle = UInt64(ticks.idle &- before.idle)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        // Aggregate busy ticks divided by all ticks normalizes all cores to 100%.
        return min(100, max(0, Double(busy) / Double(total) * 100))
    }

    private var thermalStateLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "略热"
        case .serious: return "高温"
        case .critical: return "很高"
        @unknown default: return "未知"
        }
    }
}
