import AppKit
import Foundation

/// An unexpected weather request fails locally instead of reaching the network.
private final class LayoutNoNetworkProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requestCount = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return requestCount }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requestCount += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private struct LayoutFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private final class LayoutChecks {
    private(set) var count = 0
    private(set) var frames: [[String: Any]] = []

    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LayoutFailure(description: message) }
        count += 1
    }

    func geometry(of view: NSView, page: String) throws {
        try require(abs(view.bounds.width - TouchBarLayout.width) < 0.1,
                    "\(page): root width must match TouchBarLayout.width")
        try require(abs(view.bounds.height - 30) < 0.1, "\(page): root height must be 30pt")
        try require(!view.hasAmbiguousLayout, "\(page): ambiguous root layout")
        try inspect(view, root: view, path: page)
    }

    private func inspect(_ view: NSView, root: NSView, path: String) throws {
        let rect = root.convert(view.bounds, from: view)
        try require([rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                    "\(path): non-finite frame")
        try require(rect.minX >= -0.1 && rect.maxX <= root.bounds.width + 0.1,
                    "\(path): horizontal overflow \(rect)")
        try require(rect.minY >= -0.1 && rect.maxY <= root.bounds.height + 0.1,
                    "\(path): vertical overflow \(rect)")
        if view is NSControl {
            try require(rect.width > 0 && rect.height > 0, "\(path): collapsed control")
        }
        if let stack = view as? NSStackView {
            let arranged = stack.arrangedSubviews.filter { !$0.isHidden }
            for pair in zip(arranged, arranged.dropFirst()) {
                let a = root.convert(pair.0.bounds, from: pair.0)
                let b = root.convert(pair.1.bounds, from: pair.1)
                try require(a.maxX <= b.minX + 0.1, "\(path): overlapping arranged controls")
            }
        }
        frames.append(["path": path, "type": String(describing: type(of: view)),
                       "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height])
        for (index, child) in view.subviews.enumerated() where !child.isHidden {
            try inspect(child, root: root, path: "\(path)/\(index)")
        }
    }
}

/// Wrap actual product views with an explicit fixture label. No pixels are read
/// from a display or the physical Touch Bar; AppKit draws these offscreen views.
@MainActor private final class FixtureCanvas: NSView {
    let product: NSView
    init(product: NSView, name: String) {
        self.product = product
        super.init(frame: NSRect(x: 0, y: 0, width: TouchBarLayout.width, height: 54))
        let label = NSTextField(labelWithString: "FIXTURE · \(name) · simulated metrics · offscreen NSView render")
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = NSColor(white: 0.78, alpha: 1)
        label.frame = NSRect(x: 5, y: 35, width: TouchBarLayout.width - 10, height: 13)
        addSubview(label)
        addSubview(product)
        NSLayoutConstraint.activate([
            product.leadingAnchor.constraint(equalTo: leadingAnchor),
            product.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill() }
}

@main struct TouchBarLayoutTests {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                         ?? "work/pulsebar-v2/previews", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures = output.deletingLastPathComponent().appendingPathComponent("layout-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let checks = LayoutChecks()
        let now = Date()
        try checks.require(TouchBarLayout.width == 620, "weather absorbs the removed memory slot without changing total width")
        let ordinaryWidths = [MetricKind.temperature, .cpu, .memory].map { TouchBarLayout.width(for: $0) }
        try checks.require(Set(ordinaryWidths).count == 1, "temperature, CPU and retained detail metrics keep regular widths")
        try checks.require(TouchBarLayout.width(for: .weather) == TouchBarLayout.regularWidth * 2 + TouchBarLayout.spacing,
                           "weather occupies the removed memory module and its former spacing")
        try checks.require(TouchBarLayout.width(for: .battery) > ordinaryWidths[0] &&
                           TouchBarLayout.width(for: .battery) < TouchBarLayout.width(for: .codex),
                           "battery expands while remaining shorter than Codex")
        try writeCodexFixture(to: fixtures, now: now)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LayoutNoNetworkProtocol.self]
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        // A unique, empty suite is read only. No UserDefaults values are saved.
        let defaults = UserDefaults(suiteName: "app.pulsebar.layout-tests.\(UUID().uuidString)")!
        let weather = WeatherService(defaults: defaults, session: session)
        let codex = CodexUsageService(sessionsDirectory: fixtures)
        // One read of our generated fixture directory; never start any service.
        codex.refresh(force: true)
        for _ in 0..<100 where codex.isRefreshing {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try checks.require(codex.snapshot?.windows.count == 2, "fixture Codex windows were loaded")
        try checks.require(codex.snapshot?.windows.first?.usedPercent == 100, "fixture includes 100% quota")
        let model = AppModel(weather: weather, codex: codex)
        model.sample = SystemSnapshot(sampledAt: now, cpuPercent: 100,
            memoryUsedBytes: 8_589_934_592, memoryTotalBytes: 8_589_934_592,
            batteryPercent: 100, batteryCharging: true, onACPower: true,
            temperatureCelsius: 98, temperatureSource: "TEST FIXTURE", thermalState: "测试数据", sensorCount: 4)
        let indices = (0..<90).map(Double.init)
        model.history[.temperature] = indices.map { index in
            let wave = sin(index / 6.0) * 12.0
            return 62.0 + wave + index * 0.2
        }
        model.history[.cpu] = indices.map { 45.0 + sin($0 / 4.0) * 35.0 }
        model.history[.memory] = indices.map { 65.0 + $0 / 3.0 }
        model.batteryHistory = (0..<120).map { index in
            BatteryHistoryPoint(sampledAt: now.addingTimeInterval(Double(index - 119) * 5),
                                percent: 94 + Double(index) / 119 * 6)
        }
        let city = WeatherCity(id: 999, name: "Fixture Sydney", country: "Test",
                               latitude: -33.86, longitude: 151.21, timezone: "Australia/Sydney")
        weather.selectedCity = city
        weather.snapshot = WeatherSnapshot(city: city, temperatureCelsius: 21,
            apparentTemperatureCelsius: 20, humidity: 55, windKmh: 14, weatherCode: 2,
            isDay: true, fetchedAt: now.addingTimeInterval(-3600), observationTime: "fixture",
            precipitationProbability: 100, sunrise: now.addingTimeInterval(-6 * 3600),
            sunset: now.addingTimeInterval(6 * 3600), weatherTimeZone: "Australia/Sydney")
        weather.status = "测试缓存，非实时天气"

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: TouchBarLayout.width, height: 54),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        // Do not order the window on screen or present a system Touch Bar.
        var paths: [URL] = []
        var selected: [MetricKind] = []
        var overview: TouchBarOverviewView? = TouchBarOverviewView(model: model) { selected.append($0) }
        overview!.refresh()
        paths.append(try render(overview!, name: "00-overview", window: window, output: output, checks: checks))
        let metricButtons = descendants(of: overview!).compactMap { $0 as? MetricTouchButton }
        try checks.require(metricButtons.count == 4, "overview has temperature, CPU, weather and battery buttons")
        try checks.require(!metricButtons.contains(where: { $0.kind == .memory }),
                           "memory module is absent from the Touch Bar overview")
        guard let batteryButton = metricButtons.first(where: { $0.kind == .battery }) else {
            throw LayoutFailure(description: "overview is missing the battery module")
        }
        guard let weatherButton = metricButtons.first(where: { $0.kind == .weather }) else {
            throw LayoutFailure(description: "overview is missing the expanded weather module")
        }
        let initialAnimationPhase = batteryButton.batteryAnimationPhaseForTests
        let initialWeatherPhase = weatherButton.weatherAnimationPhaseForTests
        try await Task.sleep(nanoseconds: 350_000_000)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try checks.require(!batteryButton.batteryAnimationIsRunning &&
                               batteryButton.batteryAnimationPhaseForTests == 0,
                               "battery animation respects Reduce Motion")
            try checks.require(!weatherButton.weatherAnimationIsRunning &&
                               weatherButton.weatherAnimationPhaseForTests == 0,
                               "weather scene respects Reduce Motion")
        } else {
            try checks.require(batteryButton.batteryAnimationIsRunning &&
                               batteryButton.batteryAnimationPhaseForTests != initialAnimationPhase,
                               "charging animation advances while the Touch Bar module is attached")
            try checks.require(weatherButton.weatherAnimationIsRunning &&
                               weatherButton.weatherAnimationPhaseForTests != initialWeatherPhase,
                               "weather scene animates while the expanded module is attached")
        }
        for button in metricButtons {
            let expected = TouchBarLayout.width(for: button.kind)
            try checks.require(abs(button.bounds.width - expected) < 0.1, "\(button.kind): requested pill width is preserved")
            button.performClick(nil) // Battery has no action; other metrics invoke test callbacks.
            if [.cpu, .battery].contains(button.kind) {
                let value = model.value(button.kind, compact: true)
                let measured = (value as NSString).size(withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: button.kind == .battery ? MetricTouchButton.batteryPercentageFontSize : MetricTouchButton.regularValueFontSize,
                                                         weight: button.kind == .battery ? .bold : .semibold)]).width
                try checks.require(value == "100%", "\(button.kind): full percentage fixture")
                try checks.require(measured <= MetricTouchButton.valueRect(for: button.kind, width: button.bounds.width).width,
                                   "\(button.kind): 100% must fit the rendered text area (\(measured)pt)")
            }
        }
        try checks.require(Set(selected) == Set([MetricKind.temperature, .cpu, .weather]),
                           "all visible detail callbacks work, while memory is absent and battery has no action")
        let advice = WeatherAdvice.make(from: weather.snapshot)
        let adviceLines = [advice.condition, advice.clothing]
        try checks.require(adviceLines.count == 2, "weather advice is exactly two lines")
        let adviceFont = NSFont.systemFont(ofSize: MetricTouchButton.weatherAdviceFontSize, weight: .bold)
        for line in adviceLines {
            try checks.require((line as NSString).size(withAttributes: [.font: adviceFont]).width <= 78,
                               "weather advice line fits the expanded module")
            try checks.require(!line.contains("…"), "weather advice is fully visible without truncation")
        }
        try checks.require(MetricTouchButton.weatherAdviceFontSize >= 10,
                           "two-line weather advice uses a larger bold font")
        try checks.require(MetricTouchButton.weatherConditionRect().minX == 43 &&
                           MetricTouchButton.weatherClothingRect().minX == 43,
                           "both weather text lines keep extra separation from the left cluster")
        try checks.require(MetricTouchButton.weatherRegionRect().minX == 5,
                           "location name is inset from the module edge")
        try checks.require(MetricTouchButton.weatherAdviceUsesDarkText(code: 0, isDay: true) &&
                           !MetricTouchButton.weatherAdviceUsesDarkText(code: 0, isDay: false),
                           "clear weather switches between dark daytime and light nighttime text")
        try checks.require(MetricTouchButton.weatherAdviceUsesDarkText(code: 73, isDay: false) &&
                           !MetricTouchButton.weatherAdviceUsesDarkText(code: 63, isDay: true) &&
                           !MetricTouchButton.weatherAdviceUsesDarkText(code: 95, isDay: false),
                           "snow uses dark text while rain and thunder use light text")
        try checks.require(MetricTouchButton.weatherAnimationFrameInterval >= 0.12 &&
                           MetricTouchButton.weatherAnimationFrameInterval <= 0.2,
                           "weather scene uses a bounded low-rate refresh cadence")
        let weatherScenes: [(String, Int, Bool, Double, Double?)] = [
            ("17-weather-clear", 0, true, 31, 5),
            ("18-weather-cloudy", 3, true, 20, 10),
            ("19-weather-fog", 45, true, 12, 15),
            ("20-weather-rain", 63, true, 14, 65),
            ("21-weather-snow", 73, true, -2, 30),
            ("22-weather-thunder", 95, false, 19, 90)
        ]
        let originalWeather = weather.snapshot
        for (name, code, isDay, temperature, rain) in weatherScenes {
            weather.snapshot = WeatherSnapshot(city: city, temperatureCelsius: temperature,
                apparentTemperatureCelsius: temperature, humidity: 70, windKmh: 18,
                weatherCode: code, isDay: isDay, fetchedAt: now, observationTime: "fixture",
                precipitationProbability: rain, sunrise: now.addingTimeInterval(-6 * 3600),
                sunset: now.addingTimeInterval(6 * 3600), weatherTimeZone: city.timezone)
            let sceneAdvice = WeatherAdvice.make(from: weather.snapshot)
            let sceneLines = [sceneAdvice.condition, sceneAdvice.clothing]
            try checks.require(sceneLines.count == 2, "\(name): advice has exactly two lines")
            for line in sceneLines {
                try checks.require((line as NSString).size(withAttributes: [.font: adviceFont]).width <= 78,
                                   "\(name): bold advice line fits without truncation")
            }
            overview!.refresh()
            paths.append(try render(overview!, name: name, window: window, output: output, checks: checks))
        }
        weather.snapshot = originalWeather
        overview!.refresh()
        let batteryWidth = TouchBarLayout.width(for: .battery)
        let statusRect = MetricTouchButton.batteryStatusRect()
        let number = MetricTouchButton.valueRect(for: .battery, width: batteryWidth)
        let timeRect = MetricTouchButton.batteryTimeRect(width: batteryWidth)
        try checks.require(statusRect.maxX < number.minX && number.maxX < timeRect.minX && timeRect.maxX <= batteryWidth - 4,
                           "two-line status, centered percentage and time occupy separate non-overlapping columns")
        try checks.require(abs(number.midX - batteryWidth / 2) < 0.1 && batteryWidth == 176,
                           "enlarged battery percentage is centered without resizing the module")
        let percentageDrawingRect = MetricTouchButton.batteryPercentageDrawingRect(text: "80%", width: batteryWidth)
        try checks.require(abs(percentageDrawingRect.midX - batteryWidth / 2) < 0.01 &&
                           abs(percentageDrawingRect.midY - TouchBarLayout.height / 2) < 0.01,
                           "battery percentage glyph bounds are centered horizontally and vertically")
        let restoredIconRect = MetricTouchButton.batteryRestoredIconRect(width: batteryWidth)
        try checks.require(timeRect.contains(restoredIconRect) && restoredIconRect.width == 14,
                           "custom vector lightning mark fits the estimate column")
        try checks.require(MetricTouchButton.batteryAnimationFrameInterval >= 0.1 &&
                           MetricTouchButton.batteryAnimationFrameInterval <= 0.2,
                           "battery animation uses a bounded low-rate refresh cadence")
        let displayStates: [BatteryDisplayState] = [.pluggedIn, .charging, .discharging,
                                                     .chargeLimited(80), .fullyCharged, .unknown]
        for state in displayStates {
            let lines = MetricTouchButton.batteryStatusLines(for: state)
            for line in [lines.0, lines.1] {
                let size = (line as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(
                    ofSize: MetricTouchButton.batteryStatusFontSize, weight: .semibold)])
                try checks.require(size.width <= statusRect.width, "two-line battery state fits without truncation: \(line)")
            }
        }
        for value in ["99H59m", "0H1m", "99H+", "功率不足", "计算中", "未充电"] {
            let measured = (value as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(
                ofSize: MetricTouchButton.batteryTimeFontSize, weight: .semibold)])
            try checks.require(measured.width <= timeRect.width, "time and missing-data labels fit: \(value)")
        }
        var backCount = 0
        for (index, kind) in MetricKind.allCases.filter(\.hasDetail).enumerated() {
            let page = makeTouchBarPage(kind: kind, model: model) { backCount += 1 }
            page.refresh()
            paths.append(try render(page, name: String(format: "%02d-", index + 1) + kind.rawValue,
                                    window: window, output: output, checks: checks))
            guard let back = descendants(of: page).compactMap({ $0 as? TouchActionButton })
                .first(where: { $0.label.isEmpty }) else {
                throw LayoutFailure(description: "\(kind): missing back control")
            }
            back.performClick(nil) // Never click power or Settings controls.
        }
        try checks.require(backCount == 5, "every detail page has a working back callback")

        let batteryCases: [(String, BatterySnapshot, Double)] = [
            ("09-battery-limit", BatterySnapshot(sampledAt: now, percent: 80, charging: false,
                onACPower: true, chargeLimitPercent: 80, chargeLimitReached: true), 80),
            ("10-battery-discharging", BatterySnapshot(sampledAt: now, percent: 67, charging: false,
                onACPower: false, remainingEnergyWh: 33.5, fullChargeEnergyWh: 50, netPowerWatts: -10), 67.3),
            ("11-battery-not-charging", BatterySnapshot(sampledAt: now, percent: 60, charging: false,
                onACPower: true), 60),
            ("12-battery-full", BatterySnapshot(sampledAt: now, percent: 100, charging: false,
                onACPower: true, fullyCharged: true), 99.8),
            ("13-battery-charging-time", BatterySnapshot(sampledAt: now, percent: 55, charging: true,
                onACPower: true, remainingEnergyWh: 26, fullChargeEnergyWh: 50, netPowerWatts: 10), 54.8),
            ("14-battery-unplugged-above-80", BatterySnapshot(sampledAt: now, percent: 90, charging: false,
                onACPower: false, remainingEnergyWh: 45, fullChargeEnergyWh: 50, netPowerWatts: -10), 90.3),
            ("15-battery-missing-power", BatterySnapshot(sampledAt: now, percent: 55, charging: false,
                onACPower: false), 55),
            ("16-battery-near-zero-power", BatterySnapshot(sampledAt: now, percent: 55, charging: false,
                onACPower: false, remainingEnergyWh: 25, fullChargeEnergyWh: 50, netPowerWatts: 0.01), 55)
        ]
        for (name, reading, initialPercent) in batteryCases {
            model.batterySample = reading
            var estimator = BatteryTimeEstimator()
            model.batteryEstimate = estimator.append(reading)
            model.batteryHistory = (0..<120).map { index in
                BatteryHistoryPoint(sampledAt: now.addingTimeInterval(Double(index - 119) * 5),
                    percent: initialPercent + (reading.percent! - initialPercent) * Double(index) / 119)
            }
            let statusLines = MetricTouchButton.batteryStatusLines(for: model.batteryState)
            for line in [statusLines.0, statusLines.1] {
                let measured = (line as NSString).size(withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: MetricTouchButton.batteryStatusFontSize, weight: .semibold)])
                try checks.require(measured.width <= MetricTouchButton.batteryStatusRect().width,
                                   "\(name): two-line state text is fully visible")
            }
            let captionWidth = (model.batteryEstimate.caption as NSString).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.2, weight: .medium)]).width
            try checks.require(captionWidth <= MetricTouchButton.batteryCaptionRect(width: batteryWidth).width,
                               "\(name): time/recovery caption fits without truncation")
            overview!.refresh()
            paths.append(try render(overview!, name: name, window: window, output: output, checks: checks))
            let shouldAnimate = reading.displayState == .charging || reading.displayState == .discharging
            try checks.require(batteryButton.batteryAnimationIsRunning ==
                               (shouldAnimate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
                               "\(name): animation runs only while charging or discharging")
        }

        // Also render missing-data paths without reading real logs or sensors.
        model.sample = nil
        model.batterySample = nil
        model.batteryEstimate = BatteryTimeEstimator().estimate
        model.batteryHistory = []
        weather.snapshot = nil
        model.history = [:]
        overview!.refresh()
        try checks.require(!weatherButton.weatherAnimationIsRunning && weatherButton.weatherAnimationPhaseForTests == 0,
                           "missing weather stops the scene timer and clears its phase")
        paths.append(try render(overview!, name: "07-overview-missing-data", window: window, output: output, checks: checks))
        let emptyChart = makeTouchBarPage(kind: .cpu, model: model, back: {})
        emptyChart.refresh()
        paths.append(try render(emptyChart, name: "08-chart-missing-data", window: window, output: output, checks: checks))
        window.contentView = nil
        overview = nil

        for pass in 0..<30 {
            for kind in MetricKind.allCases where kind.hasDetail {
                weak var weakPage: TouchBarPageView?
                weak var weakContent: NSView?
                autoreleasepool {
                    let page = makeTouchBarPage(kind: kind, model: model, back: {})
                    weakPage = page; weakContent = page.content
                    page.refresh()
                }
                try checks.require(weakPage == nil && weakContent == nil,
                                   "\(kind): page and content released after cycle \(pass)")
            }
        }
        try checks.require(LayoutNoNetworkProtocol.requests == 0, "no network requests were attempted")
        window.close()
        try contactSheet(paths, to: output.appendingPathComponent("fixture-contact-sheet.png"))
        let report: [String: Any] = [
            "fixture_only": true, "physical_touch_bar_capture": false,
            "assertions_passed": checks.count, "rendered_pages": paths.map(\.lastPathComponent),
            "page_release_cycles": 150, "network_requests": LayoutNoNetworkProtocol.requests,
            "power_mutations": 0, "frames": checks.frames]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("fixture-layout-report.json"))
        try """
        These are offscreen renders of the actual PulseBar NSView implementations.
        All metric, weather and Codex quota values are generated TEST FIXTURES.
        Battery is a read-only overview item; no power changes are made.
        No real Touch Bar or desktop pixels are captured. No service is started,
        no network request is made, and no login registration is attempted.
        Images are rendered at 2x scale: the product view is exactly \(Int(TouchBarLayout.width)) x 30pt,
        with a separate 24pt fixture label above it. Review the contact sheet for
        text/icon legibility in addition to the automated geometry assertions.
        """.write(to: output.appendingPathComponent("FIXTURES-README.txt"), atomically: true, encoding: .utf8)
        print("PASS: \(checks.count) layout assertions; overview + 5 details + 6 weather scenes + 8 battery states + 2 missing-data renders; 150 release cycles.")
        print("FIXTURE previews: \(output.path)")
    }

    private static func writeCodexFixture(to directory: URL, now: Date) throws {
        let iso = ISO8601DateFormatter()
        let event: [String: Any] = ["timestamp": iso.string(from: now), "type": "event_msg",
            "payload": ["type": "token_count", "rate_limits": ["limit_id": "codex", "plan_type": "FIXTURE",
                "primary": ["window_minutes": 300, "used_percent": 100,
                            "resets_at": now.addingTimeInterval(3 * 3600).timeIntervalSince1970],
                "secondary": ["window_minutes": 10080, "used_percent": 63,
                              "resets_at": now.addingTimeInterval(3 * 86400 + 4 * 3600).timeIntervalSince1970]]]]
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(10)
        try data.write(to: directory.appendingPathComponent("rollout-layout-fixture.jsonl"))
    }

    @MainActor private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor private static func render(_ product: NSView, name: String, window: NSWindow,
                                          output: URL, checks: LayoutChecks) throws -> URL {
        let canvas = FixtureCanvas(product: product, name: name)
        window.contentView = canvas
        window.setContentSize(canvas.frame.size)
        canvas.layoutSubtreeIfNeeded()
        product.layoutSubtreeIfNeeded()
        try checks.geometry(of: product, page: name)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(TouchBarLayout.width * 2), pixelsHigh: 108,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw LayoutFailure(description: "failed to allocate fixture bitmap")
        }
        rep.size = canvas.bounds.size
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw LayoutFailure(description: "failed to encode fixture bitmap")
        }
        let destination = output.appendingPathComponent("fixture-\(name).png")
        try png.write(to: destination)
        return destination
    }

    @MainActor private static func contactSheet(_ pages: [URL], to destination: URL) throws {
        let height = pages.count * 60
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(TouchBarLayout.width * 2), pixelsHigh: height * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw LayoutFailure(description: "failed to allocate contact sheet")
        }
        rep.size = NSSize(width: TouchBarLayout.width, height: CGFloat(height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: TouchBarLayout.width, height: CGFloat(height)).fill()
        for (index, url) in pages.enumerated() {
            NSImage(contentsOf: url)?.draw(in: NSRect(x: 0, y: CGFloat(height - (index + 1) * 60 + 3),
                                                     width: TouchBarLayout.width, height: 54))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw LayoutFailure(description: "failed to encode contact sheet")
        }
        try data.write(to: destination)
    }
}
