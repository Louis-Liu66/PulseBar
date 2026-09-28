import AppKit
import SwiftUI
import ServiceManagement

enum MetricKind: String, CaseIterable, Identifiable {
    case codex, temperature, cpu, memory, weather, battery
    var id: String { rawValue }
    var hasDetail: Bool { self != .battery }
    var title: String {
        switch self {
        case .temperature: return "CPU 温度"
        case .cpu: return "CPU 占用"
        case .memory: return "内存占用"
        case .weather: return "天气"
        case .battery: return "电量"
        case .codex: return "Codex 用量"
        }
    }
    var symbol: String {
        switch self {
        case .temperature: return "thermometer.medium"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .weather: return "cloud.sun.fill"
        case .battery: return "battery.100percent"
        case .codex: return "chart.bar.fill"
        }
    }
    var color: Color {
        switch self {
        case .temperature: return Color(red: 1, green: 0.64, blue: 0.39)
        case .cpu: return Color(red: 0.49, green: 0.64, blue: 1)
        case .memory: return Color(red: 0.71, green: 0.56, blue: 1)
        case .weather: return Color(red: 0.43, green: 0.81, blue: 0.96)
        case .battery: return Color(red: 0.48, green: 0.88, blue: 0.67)
        case .codex: return Color(white: 0.86)
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var sample: SystemSnapshot?
    @Published var history: [MetricKind: [Double]] = [:]
    @Published var batterySample: BatterySnapshot?
    @Published var batteryHistory: [BatteryHistoryPoint] = []
    @Published var batteryEstimate = BatteryTimeEstimator().estimate
    @Published var touchBarVisible = false
    @Published var touchBarSupported = false
    @Published var touchBarMessage = "正在连接 Touch Bar"
    @Published var selectedMetric: MetricKind?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginMessage = ""
    @Published var isPaused = false
    let weather: WeatherService
    let codex: CodexUsageService
    var onSample: (() -> Void)?
    var showBar: (() -> Void)?
    var hideBar: (() -> Void)?
    var openWindow: (() -> Void)?
    var showTouchDetail: ((MetricKind) -> Void)?
    var returnToOverview: (() -> Void)?
    private let queue = DispatchQueue(label: "app.pulsebar.metrics", qos: .utility)
    private let sampler = SystemSampler()
    private var timer: DispatchSourceTimer?
    private let batteryTimer = BatterySamplingTimer()
    private var batteryHistoryStore = BatteryHistory()
    private var batteryEstimator = BatteryTimeEstimator()
    private var generation = 0

    init(weather: WeatherService? = nil, codex: CodexUsageService? = nil) {
        self.weather = weather ?? WeatherService()
        self.codex = codex ?? CodexUsageService()
    }

    func start() {
        guard timer == nil else { return }
        isPaused = false
        generation += 1
        let token = generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
        let sampler = self.sampler
        timer.setEventHandler { [weak self] in
            let snapshot = sampler.sample(includeBattery: false)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !self.isPaused else { return }
                self.sample = snapshot
                for kind in [MetricKind.temperature, .cpu, .memory] {
                    if let value = self.number(kind), value.isFinite {
                        var points = self.history[kind, default: []]
                        points.append(value)
                        if points.count > 90 { points.removeFirst(points.count - 90) }
                        self.history[kind] = points
                    } else {
                        self.history[kind] = []
                    }
                }
                self.onSample?()
            }
        }
        self.timer = timer
        timer.resume()
        batteryTimer.start(queue: queue) { [weak self] in
            let reading = sampler.sampleBattery()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !self.isPaused else { return }
                self.batterySample = reading
                self.batteryEstimate = self.batteryEstimator.append(reading)
                self.batteryHistoryStore.append(reading)
                self.batteryHistory = self.batteryHistoryStore.points
                self.onSample?()
            }
        }
    }

    func pause() {
        isPaused = true
        generation += 1
        timer?.cancel()
        timer = nil
        batteryTimer.stop()
        history.removeAll()
        batterySample = nil
        batteryEstimator.reset()
        batteryEstimate = batteryEstimator.estimate
        batteryHistoryStore.reset()
        batteryHistory.removeAll()
    }

    func number(_ kind: MetricKind) -> Double? {
        switch kind {
        case .temperature: return sample?.temperatureCelsius
        case .cpu: return sample?.cpuPercent
        case .memory:
            guard let s = sample, let used = s.memoryUsedBytes, s.memoryTotalBytes > 0 else { return nil }
            return Double(used) / Double(s.memoryTotalBytes) * 100
        case .weather: return weather.snapshot?.temperatureCelsius
        case .battery:
            if let batterySample { return batterySample.percent }
            return sample?.batteryPercent
        case .codex: return codex.snapshot?.windows.first?.usedPercent
        }
    }

    func value(_ kind: MetricKind, compact: Bool = false) -> String {
        guard let value = number(kind), value.isFinite else { return "—" }
        switch kind {
        case .temperature, .weather: return String(format: compact ? "%.0f°" : "%.0f", value)
        default: return String(format: compact ? "%.0f%%" : "%.0f", value)
        }
    }

    func detail(_ kind: MetricKind) -> String {
        if kind == .codex {
            return "只读本机 Codex 额度记录，不联网、不读取账号凭据。立即刷新会重新读取本地日志；本地日志未更新时无法得到新的服务器额度。\n\(codex.status)"
        }
        guard let s = sample else { return "正在读取实时数据…" }
        switch kind {
        case .temperature:
            if s.temperatureCelsius == nil { return "当前系统未提供可读取的温度传感器。" }
            return "显示 \(s.sensorCount) 个有效 CPU 传感器中的最高温度。它反映芯片内部温度，不是外壳温度。\n系统热状态：\(s.thermalState)。"
        case .cpu: return "全机 CPU 的平均占用率，按所有核心归一化到 0–100%。每 2 秒采样，曲线保留最近 3 分钟。"
        case .memory:
            return "物理内存使用估计：活跃、非活跃、推测、不可换出及压缩内存，扣除可回收文件缓存与可清除页。与活动监视器可能因采样时刻和统计口径略有差异。\n\(memoryDescription)"
        case .weather: return "系统自动定位，每 5 分钟更新天气。天气服务：Open-Meteo；地区名称由 Apple 提供。网络不可用时保留上次数据并标记状态。"
        case .battery: return "电量来自 macOS 电源信息。\n\(batteryDescription)"
        case .codex: return codex.status
        }
    }

    var memoryDescription: String {
        guard let s = sample, let used = s.memoryUsedBytes, s.memoryTotalBytes > 0 else { return "等待内存数据" }
        return String(format: "%.1f / %.0f GB 已使用", Double(used) / 1_073_741_824, Double(s.memoryTotalBytes) / 1_073_741_824)
    }

    var batteryState: BatteryDisplayState {
        if let batterySample { return batterySample.displayState }
        guard let s = sample, s.batteryPercent != nil else { return .unknown }
        return BatteryDisplayState(charging: s.batteryCharging, onACPower: s.onACPower)
    }

    func trend(_ kind: MetricKind) -> MetricTrend {
        MetricTrend(values: history[kind, default: []])
    }

    var batteryDescription: String {
        batteryState.description
    }

    var batteryStatusText: String { batteryState.label }
    var batteryCompactStatusText: String {
        if case .chargeLimited(let limit) = batteryState {
            return "已接电源 · 已限充" + (limit.map { String(format: "%.0f%%", $0) } ?? "")
        }
        return batteryStatusText
    }

    func selectMetric(_ kind: MetricKind) {
        guard kind.hasDetail else { return }
        if let showTouchDetail { showTouchDetail(kind) }
        else { selectedMetric = kind }
    }

    var weatherRegion: String {
        weather.snapshot?.city.name ?? weather.selectedCity?.name ?? "定位中"
    }

    func configureLoginOnLaunch() {
        let defaults = UserDefaults.standard
        let key = "PulseBar.launchAtLogin.desired.v2"
        if defaults.object(forKey: key) == nil { defaults.set(true, forKey: key) }
        guard defaults.bool(forKey: key) else { return }
        if SMAppService.mainApp.status == .enabled {
            launchAtLogin = true
        } else if SMAppService.mainApp.status == .requiresApproval {
            loginMessage = "请在系统设置 → 通用 → 登录项中允许 PulseBar。"
        } else {
            setLogin(true)
        }
    }

    func setLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "PulseBar.launchAtLogin.desired.v2")
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "请在系统设置 → 通用 → 登录项中允许 PulseBar。" : ""
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginMessage = "未能更改登录设置。请先将应用移至「应用程序」，再重试。"
        }
    }
}
