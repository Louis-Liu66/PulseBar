import AppKit
import Combine

@MainActor final class TouchBarController: NSObject {
    let bar = NSTouchBar()
    private let model: AppModel
    private let contentItem = NSCustomTouchBarItem(identifier: .init("app.pulsebar.content.v2"))
    private var overview: TouchBarOverviewView!
    private var page: TouchBarPageView?
    private var currentDetail: MetricKind?
    private(set) var transitionHost: TouchBarTransitionView!
    private var tray: NSCustomTouchBarItem?
    private var visibilityObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var suspended = false
    private var resumeAfterSleep = false
    private var pageDiagnostics: [String: [String: Any]] = [:]

    init(model: AppModel) {
        self.model = model
        super.init()
        overview = TouchBarOverviewView(model: model) { [weak self] kind in self?.showDetail(kind) }
        transitionHost = TouchBarTransitionView(initialView: overview)
        contentItem.view = transitionHost
        contentItem.visibilityPriority = .high
        bar.templateItems = [contentItem]
        bar.defaultItemIdentifiers = [contentItem.identifier]
        model.touchBarSupported = PBTouchBarSupported()
        model.touchBarMessage = model.touchBarSupported ? "准备就绪 · 可显示到 Touch Bar" : "当前系统不支持常驻 Touch Bar，仍可使用面板"
        visibilityObservation = bar.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        }
        model.weather.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)
        model.codex.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)
        let item = NSCustomTouchBarItem(identifier: .init("app.pulsebar.controlstrip"))
        let button = NSButton(image: NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "显示 PulseBar")!, target: self, action: #selector(show))
        button.isBordered = false
        item.view = button
        if PBInstallControlStripItem(item) { tray = item }
    }
    func showDetail(_ kind: MetricKind) {
        guard kind.hasDetail else { return }
        if currentDetail == kind, page != nil { refresh(); show(); return }
        currentDetail = kind
        model.selectedMetric = kind
        let back: () -> Void = { [weak self] in self?.showOverview() }
        page = makeTouchBarPage(kind: kind, model: model, back: back)
        transitionHost.setContent(page!, direction: .forward, animated: bar.isVisible)
        refresh(); show()
    }
    func showOverview() {
        currentDetail = nil
        model.selectedMetric = nil
        transitionHost.setContent(overview, direction: .backward, animated: bar.isVisible)
        page = nil
        refresh(); show()
    }
    @objc func show() {
        suspended = false
        guard model.touchBarSupported else { return }
        if bar.isVisible { updateVisibility(); return }
        let accepted = PBPresentTouchBar(bar, true)
        model.touchBarMessage = accepted ? "正在显示 · 保留系统控制区" : "无法显示 Touch Bar，可从菜单栏重试"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.updateVisibility()
            if CommandLine.arguments.contains("--layout-diagnostics"), let self {
                var view: NSView? = self.contentItem.view
                while let current = view {
                    NSLog("PulseBar layout %@ frame %@ bounds %@", String(describing: type(of: current)), NSStringFromRect(current.frame), NSStringFromRect(current.bounds))
                    view = current.superview
                }
            }
        }
    }
    func hide() {
        resumeAfterSleep = false
        transitionHost.cancelTransition()
        PBDismissTouchBar(bar)
        model.touchBarVisible = false
        model.touchBarMessage = "已恢复系统触控栏 · 菜单栏可重新打开"
    }
    func refresh() {
        overview.refresh(); page?.refresh()
        if CommandLine.arguments.contains("--layout-diagnostics"), bar.isVisible {
            var view: NSView? = contentItem.view
            var frames: [[String: String]] = []
            while let current = view {
                frames.append(["type": String(describing: type(of: current)),
                               "frame": NSStringFromRect(current.frame),
                               "bounds": NSStringFromRect(current.bounds),
                               "visible": NSStringFromRect(current.visibleRect)])
                view = current.superview
            }
            let pageName = currentDetail?.rawValue ?? "overview"
            let content = transitionHost.currentContent
            let viewport = transitionHost.visibleRect
            let current: [String: Any] = [
                "views": frames,
                "contentType": String(describing: type(of: content)),
                "contentFrame": NSStringFromRect(content.frame),
                "contentVisible": NSStringFromRect(content.visibleRect),
                "expectedWidth": Double(TouchBarLayout.width),
                "transitioning": transitionHost.isTransitioning,
                "viewportFullyVisible": viewport.width >= TouchBarLayout.width - 0.5 && viewport.height >= 29.5]
            pageDiagnostics[pageName] = current
            var report = current
            report["page"] = pageName
            report["visitedPages"] = pageDiagnostics
            report["batterySampling"] = [
                "scheduledInterval": BatteryHistory.samplingInterval,
                "pointCount": model.batteryHistory.count,
                "recentIntervals": zip(model.batteryHistory, model.batteryHistory.dropFirst())
                    .map { $1.sampledAt.timeIntervalSince($0.sampledAt) }.suffix(5).map { $0 },
                "state": model.batteryDescription
            ] as [String: Any]
            if let battery = model.batterySample {
                report["batteryEstimate"] = [
                    "sampleTime": battery.sampledAt.timeIntervalSince1970,
                    "onACPower": battery.onACPower, "charging": battery.charging,
                    "percent": battery.percent as Any? ?? NSNull(),
                    "remainingWh": battery.remainingEnergyWh as Any? ?? NSNull(),
                    "fullWh": battery.fullChargeEnergyWh as Any? ?? NSNull(),
                    "netWatts": battery.netPowerWatts as Any? ?? NSNull(),
                    "text": model.batteryEstimate.text, "caption": model.batteryEstimate.caption
                ] as [String: Any]
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PulseBar-layout-\(ProcessInfo.processInfo.processIdentifier).json")
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    private func updateVisibility() {
        model.touchBarVisible = bar.isVisible
        if suspended { return }
        let detail = currentDetail.map { " · \($0.title)详情" } ?? ""
        model.touchBarMessage = bar.isVisible ? "已显示\(detail) · 保留系统控制区" : "已收起 · 菜单栏可重新显示"
    }
    func suspend() {
        resumeAfterSleep = bar.isVisible
        suspended = true
        transitionHost.cancelTransition()
        PBDismissTouchBar(bar)
    }
    func resume() {
        suspended = false
        if resumeAfterSleep { show() }
        resumeAfterSleep = false
    }
    func shutdown() {
        visibilityObservation = nil
        transitionHost.cancelTransition()
        PBDismissTouchBar(bar)
        if let tray { PBRemoveControlStripItem(tray) }
        tray = nil
    }
}
