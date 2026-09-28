import AppKit
import SwiftUI

enum TouchBarLayout {
    static let height: CGFloat = 30
    static let spacing: CGFloat = 4
    static let regularWidth: CGFloat = 60
    static let overviewKinds: [MetricKind] = [.codex, .temperature, .cpu, .weather, .battery]
    static func width(for kind: MetricKind) -> CGFloat {
        switch kind {
        case .temperature, .cpu, .memory: return regularWidth
        case .weather: return regularWidth * 2 + spacing
        case .battery: return 176
        case .codex: return 184
        }
    }
    static let width = overviewKinds.reduce(CGFloat(0)) { $0 + width(for: $1) }
        + spacing * CGFloat(overviewKinds.count - 1)
    static let detailWidth = width - 40
}

private func fixedSize(_ view: NSView, width: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width),
                                 view.heightAnchor.constraint(equalToConstant: 30)])
}
private func placeStack(_ children: [NSView], in parent: NSView, spacing: CGFloat) {
    let stack = NSStackView(views: children)
    stack.orientation = .horizontal; stack.alignment = .centerY
    stack.distribution = .fill; stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        stack.topAnchor.constraint(equalTo: parent.topAnchor),
        stack.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
}
func touchText(_ text: String, rect: NSRect, size: CGFloat, color: NSColor = .white,
               weight: NSFont.Weight = .medium, align: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = align
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph]
    (text as NSString).draw(in: rect, withAttributes: attributes)
}
private func touchBackground(_ rect: NSRect, color: NSColor, pressed: Bool = false) {
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0.5), xRadius: 7, yRadius: 7)
    NSColor(white: 0.09, alpha: 1).setFill(); path.fill()
    color.withAlphaComponent(pressed ? 0.44 : 0.29).setFill(); path.fill()
}
private func touchIcon(_ name: String, rect: NSRect, color: NSColor) {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)?
        .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

private enum TouchWeatherScene {
    case clear, partlyCloudy, cloudy, fog, rain, snow, thunder, unknown

    init(code: Int?) {
        guard let code else { self = .unknown; return }
        switch code {
        case 0, 1: self = .clear
        case 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51...67, 80...82: self = .rain
        case 71...77, 85, 86: self = .snow
        case 95...99: self = .thunder
        default: self = .unknown
        }
    }
}

@MainActor final class MetricTouchButton: NSButton {
    override var isFlipped: Bool { false }
    let kind: MetricKind
    private weak var model: AppModel?
    private let onTap: () -> Void
    private var batteryAnimationTimer: Timer?
    private var batteryAnimationPhase: CGFloat = 0
    private var weatherAnimationTimer: Timer?
    private var weatherAnimationPhase: CGFloat = 0
    static let regularValueFontSize: CGFloat = 12
    static let batteryStatusFontSize: CGFloat = 8.4
    static let batteryPercentageFontSize: CGFloat = 18
    static let batteryTimeFontSize: CGFloat = 12
    static let batteryAnimationFrameInterval: TimeInterval = 0.10
    static let weatherAdviceFontSize: CGFloat = 10
    static let weatherAnimationFrameInterval: TimeInterval = 0.14
    var batteryAnimationIsRunning: Bool { batteryAnimationTimer != nil }
    var batteryAnimationPhaseForTests: CGFloat { batteryAnimationPhase }
    var weatherAnimationIsRunning: Bool { weatherAnimationTimer != nil }
    var weatherAnimationPhaseForTests: CGFloat { weatherAnimationPhase }
    static func batteryStatusRect() -> NSRect { NSRect(x: 8, y: 3, width: 50, height: 24) }
    static func batteryTimeRect(width: CGFloat) -> NSRect { NSRect(x: 119, y: 0, width: width - 123, height: 19) }
    static func batteryCaptionRect(width: CGFloat) -> NSRect { NSRect(x: 116, y: 18, width: width - 120, height: 10) }
    static func batteryRestoredIconRect(width: CGFloat) -> NSRect {
        let column = batteryTimeRect(width: width)
        return NSRect(x: column.midX - 7, y: 2, width: 14, height: 15)
    }
    static func valueRect(for kind: MetricKind, width: CGFloat) -> NSRect {
        NSRect(x: kind == .battery ? 60 : 21, y: 0,
               width: kind == .battery ? 56 : width - 24, height: kind == .battery ? 30 : 19)
    }
    static func weatherRegionRect() -> NSRect { NSRect(x: 5, y: 20, width: 32, height: 9) }
    static func weatherConditionRect() -> NSRect { NSRect(x: 43, y: 15.2, width: 78, height: 13) }
    static func weatherClothingRect() -> NSRect { NSRect(x: 43, y: 2.2, width: 78, height: 13) }
    static func weatherAdviceUsesDarkText(code: Int?, isDay: Bool) -> Bool {
        guard let code else { return false }
        switch code {
        case 0...2: return isDay
        case 3, 45, 48, 71...77, 85, 86: return true
        default: return false
        }
    }
    static func batteryPercentageDrawingRect(text: String, width: CGFloat) -> NSRect {
        let column = valueRect(for: .battery, width: width)
        let font = NSFont.monospacedDigitSystemFont(ofSize: batteryPercentageFontSize, weight: .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSRect(x: column.midX - size.width / 2, y: TouchBarLayout.height / 2 - size.height / 2,
                      width: size.width, height: size.height)
    }
    static func batteryStatusLines(for state: BatteryDisplayState) -> (String, String) {
        switch state {
        case .charging: return ("已接电源", "电池在充电")
        case .pluggedIn: return ("已接电源", "电池未充电")
        case .discharging: return ("未接电源", "电池在放电")
        case .fullyCharged: return ("已接电源", "电池已充满")
        case .chargeLimited(let limit):
            return ("已接电源", "已限充" + (limit.map { String(format: "%.0f%%", $0) } ?? ""))
        case .unknown: return ("正在读取", "电池状态")
        }
    }
    init(kind: MetricKind, model: AppModel, onTap: @escaping () -> Void) {
        self.kind = kind; self.model = model; self.onTap = onTap
        super.init(frame: NSRect(x: 0, y: 0, width: TouchBarLayout.width(for: kind), height: 30))
        isBordered = false; title = ""; target = self; action = #selector(pressed)
        setButtonType(.momentaryChange)
        fixedSize(self, width: TouchBarLayout.width(for: kind))
        setAccessibilityLabel(kind.title)
        if !kind.hasDetail {
            setAccessibilityRole(.staticText)
            focusRingType = .none
            action = nil; target = nil
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        batteryAnimationTimer?.invalidate()
        weatherAnimationTimer?.invalidate()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBatteryAnimation()
        updateWeatherAnimation()
    }
    @objc private func pressed() { if kind.hasDetail { onTap() } }
    func refresh() {
        setAccessibilityLabel(kind == .weather ? model?.weatherRegion : (kind == .battery ? model?.batteryDescription : kind.title))
        setAccessibilityValue(model?.value(kind, compact: true) ?? "暂无数据")
        if kind == .weather {
            let advice = WeatherAdvice.make(from: model?.weather.snapshot).text
            setAccessibilityValue((model?.value(.weather, compact: true) ?? "—") + "，" + advice)
            toolTip = advice + "\n" + (model?.weather.status ?? "等待天气更新")
            updateWeatherAnimation()
        }
        if kind == .battery {
            let estimate = model?.batteryEstimate.accessibilityDescription ?? "等待采样"
            setAccessibilityValue((model?.value(.battery, compact: true) ?? "—") + "，" + estimate)
            toolTip = (model?.batteryDescription ?? "读取电量") + "\n" + estimate +
                "\n根据电池容量与近期实际充放电功率估算，随使用负载变化。\n绿色液面表示真实电量；充电向右流动，离电向左退潮。"
            updateBatteryAnimation()
        }
        needsDisplay = true
    }

    private var batteryStateIsAnimated: Bool {
        guard kind == .battery, let model else { return false }
        switch model.batteryState {
        case .charging, .discharging: return true
        default: return false
        }
    }

    private func updateBatteryAnimation() {
        let shouldRun = window != nil && batteryStateIsAnimated &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldRun else {
            batteryAnimationTimer?.invalidate()
            batteryAnimationTimer = nil
            batteryAnimationPhase = 0
            return
        }
        guard batteryAnimationTimer == nil else { return }
        let timer = Timer(timeInterval: Self.batteryAnimationFrameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window != nil, self.batteryStateIsAnimated else {
                    self?.updateBatteryAnimation()
                    return
                }
                self.batteryAnimationPhase = (self.batteryAnimationPhase + 0.018)
                    .truncatingRemainder(dividingBy: 1)
                self.needsDisplay = true
            }
        }
        timer.tolerance = 0.035
        RunLoop.main.add(timer, forMode: .common)
        batteryAnimationTimer = timer
    }

    private func updateWeatherAnimation() {
        let shouldRun = kind == .weather && window != nil && model?.weather.snapshot != nil &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldRun else {
            weatherAnimationTimer?.invalidate()
            weatherAnimationTimer = nil
            weatherAnimationPhase = 0
            return
        }
        guard weatherAnimationTimer == nil else { return }
        let timer = Timer(timeInterval: Self.weatherAnimationFrameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.kind == .weather, self.window != nil,
                      self.model?.weather.snapshot != nil else {
                    self?.updateWeatherAnimation()
                    return
                }
                self.weatherAnimationPhase = (self.weatherAnimationPhase + 0.025)
                    .truncatingRemainder(dividingBy: 1)
                self.needsDisplay = true
            }
        }
        timer.tolerance = 0.045
        RunLoop.main.add(timer, forMode: .common)
        weatherAnimationTimer = timer
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let accent = NSColor(kind.color)
        if kind == .battery {
            drawBatteryBackground(model, accent: accent)
            drawBattery(model, accent: accent)
            return
        }
        if kind == .weather {
            drawWeatherBackground(model.weather.snapshot)
            drawWeather(model, accent: accent)
            return
        }
        touchBackground(bounds, color: accent, pressed: kind.hasDetail && isHighlighted)
        touchIcon(kind.symbol, rect: NSRect(x: 4, y: 7, width: 14, height: 16), color: accent)
        touchText(kind.title, rect: NSRect(x: 21, y: 18, width: bounds.width - 24, height: 10),
                  size: 7.2, color: .white.withAlphaComponent(0.72))
        touchText(model.value(kind, compact: true), rect: Self.valueRect(for: kind, width: bounds.width),
                  size: Self.regularValueFontSize, weight: .semibold)
    }

    private func drawWeather(_ model: AppModel, accent: NSColor) {
        let snapshot = model.weather.snapshot
        touchText(model.weatherRegion, rect: Self.weatherRegionRect(),
                  size: 6.5, color: .white.withAlphaComponent(0.78), weight: .semibold)
        touchIcon(snapshot?.symbol ?? kind.symbol, rect: NSRect(x: 3, y: 3, width: 14, height: 15), color: accent)
        touchText(model.value(.weather, compact: true), rect: NSRect(x: 17, y: 1, width: 22, height: 18),
                  size: 11.5, color: .white, weight: .semibold, align: .center)

        let advice = WeatherAdvice.make(from: snapshot)
        let darkText = Self.weatherAdviceUsesDarkText(code: snapshot?.weatherCode,
                                                      isDay: snapshot?.isDay ?? true)
        let adviceColor = darkText
            ? NSColor(calibratedRed: 0.025, green: 0.09, blue: 0.15, alpha: 0.96)
            : NSColor.white.withAlphaComponent(0.98)
        touchText(advice.condition, rect: Self.weatherConditionRect(), size: Self.weatherAdviceFontSize,
                  color: adviceColor, weight: .bold)
        touchText(advice.clothing, rect: Self.weatherClothingRect(), size: Self.weatherAdviceFontSize,
                  color: adviceColor, weight: .bold)
        if snapshot != nil, model.weather.isStale || model.weather.isLocationStale {
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: 35, y: 1, width: 3, height: 3)).fill()
        }
    }

    private func drawWeatherBackground(_ snapshot: WeatherSnapshot?) {
        NSGraphicsContext.saveGraphicsState()
        let shellRect = bounds.insetBy(dx: 0, dy: 0.5)
        let shell = NSBezierPath(roundedRect: shellRect, xRadius: 7, yRadius: 7)
        shell.addClip()
        let scene = TouchWeatherScene(code: snapshot?.weatherCode)
        let isDay = snapshot?.isDay ?? true
        let colors: [NSColor]
        switch scene {
        case .clear:
            colors = isDay ? [NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.76, alpha: 1),
                              NSColor(calibratedRed: 0.18, green: 0.71, blue: 0.94, alpha: 1)] :
                             [NSColor(calibratedRed: 0.01, green: 0.03, blue: 0.14, alpha: 1),
                              NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.42, alpha: 1)]
        case .partlyCloudy:
            colors = isDay ? [NSColor(calibratedRed: 0.08, green: 0.37, blue: 0.64, alpha: 1),
                              NSColor(calibratedRed: 0.34, green: 0.66, blue: 0.82, alpha: 1)] :
                             [NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.20, alpha: 1),
                              NSColor(calibratedRed: 0.16, green: 0.27, blue: 0.43, alpha: 1)]
        case .cloudy:
            colors = [NSColor(calibratedRed: 0.17, green: 0.23, blue: 0.29, alpha: 1),
                      NSColor(calibratedRed: 0.39, green: 0.48, blue: 0.54, alpha: 1)]
        case .fog:
            colors = [NSColor(calibratedRed: 0.21, green: 0.30, blue: 0.34, alpha: 1),
                      NSColor(calibratedRed: 0.54, green: 0.63, blue: 0.65, alpha: 1)]
        case .rain:
            colors = [NSColor(calibratedRed: 0.02, green: 0.11, blue: 0.24, alpha: 1),
                      NSColor(calibratedRed: 0.08, green: 0.36, blue: 0.54, alpha: 1)]
        case .snow:
            colors = [NSColor(calibratedRed: 0.22, green: 0.39, blue: 0.54, alpha: 1),
                      NSColor(calibratedRed: 0.62, green: 0.79, blue: 0.86, alpha: 1)]
        case .thunder:
            colors = [NSColor(calibratedRed: 0.03, green: 0.02, blue: 0.13, alpha: 1),
                      NSColor(calibratedRed: 0.24, green: 0.16, blue: 0.40, alpha: 1)]
        case .unknown:
            colors = [NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.31, alpha: 1),
                      NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.56, alpha: 1)]
        }
        NSGradient(colors: colors)?.draw(in: shell, angle: 0)

        let angle = weatherAnimationPhase * 2 * .pi
        let drift = CGFloat(sin(Double(angle))) * 7.5
        let pulse = CGFloat((sin(Double(angle)) + 1) / 2)
        switch scene {
        case .clear:
            if isDay { drawWeatherSun(center: NSPoint(x: 106, y: 21), radius: 10, pulse: pulse, angle: angle) }
            else {
                drawWeatherStars(pulse: pulse)
                drawWeatherMoon(center: NSPoint(x: 106, y: 20), radius: 8.5)
            }
        case .partlyCloudy:
            if isDay { drawWeatherSun(center: NSPoint(x: 105, y: 22), radius: 9, pulse: pulse, angle: angle) }
            else {
                drawWeatherStars(pulse: pulse)
                drawWeatherMoon(center: NSPoint(x: 106, y: 21), radius: 7.5)
            }
            drawWeatherCloud(center: NSPoint(x: 78 + drift, y: 14), scale: 1.35, alpha: 0.45)
            drawWeatherCloud(center: NSPoint(x: 113 - drift * 0.45, y: 8), scale: 1.0, alpha: 0.32)
        case .cloudy:
            drawWeatherCloud(center: NSPoint(x: 37 + drift, y: 20), scale: 1.5, alpha: 0.40)
            drawWeatherCloud(center: NSPoint(x: 86 - drift * 0.75, y: 10), scale: 1.8, alpha: 0.54)
            drawWeatherCloud(center: NSPoint(x: 119 + drift * 0.5, y: 23), scale: 1.15, alpha: 0.36)
        case .fog:
            for index in 0..<5 {
                let y = CGFloat(3 + index * 6)
                let offset = drift * (index.isMultiple(of: 2) ? 1 : -1)
                NSColor.white.withAlphaComponent(0.22 + CGFloat(index) * 0.025).setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: -8 + offset, y: y))
                line.curve(to: NSPoint(x: bounds.maxX + 8 + offset, y: y + 0.8),
                           controlPoint1: NSPoint(x: 35 + offset, y: y + 2),
                           controlPoint2: NSPoint(x: 84 + offset, y: y - 2))
                line.lineWidth = 2.8; line.lineCapStyle = .round; line.stroke()
            }
        case .rain, .thunder:
            drawWeatherCloud(center: NSPoint(x: 61 + drift * 0.55, y: 22), scale: 1.9, alpha: 0.50)
            drawWeatherCloud(center: NSPoint(x: 110 - drift * 0.45, y: 20), scale: 1.45, alpha: 0.39)
            let fall = weatherAnimationPhase * 30
            for index in 0..<12 {
                let x = CGFloat(6 + index * 11) + drift * 0.28
                let y = CGFloat((index * 7) % 19) + fall
                NSColor(calibratedRed: 0.56, green: 0.88, blue: 1, alpha: 0.62).setStroke()
                let drop = NSBezierPath()
                drop.move(to: NSPoint(x: x, y: y.truncatingRemainder(dividingBy: 24) - 1))
                drop.line(to: NSPoint(x: x - 3.0, y: y.truncatingRemainder(dividingBy: 24) - 8))
                drop.lineWidth = 1.25; drop.lineCapStyle = .round; drop.stroke()
            }
            if scene == .thunder {
                let flash = min(0.92, 0.28 + max(0, pulse - 0.55) * 1.5)
                NSColor.systemYellow.withAlphaComponent(flash).setFill()
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: 102, y: 20)); bolt.line(to: NSPoint(x: 96, y: 11))
                bolt.line(to: NSPoint(x: 101, y: 11)); bolt.line(to: NSPoint(x: 96, y: 3))
                bolt.line(to: NSPoint(x: 108, y: 14)); bolt.line(to: NSPoint(x: 102, y: 14)); bolt.close()
                bolt.fill()
            }
        case .snow:
            drawWeatherCloud(center: NSPoint(x: 67 + drift * 0.5, y: 22), scale: 1.85, alpha: 0.44)
            for index in 0..<14 {
                let x = CGFloat(3 + index * 10) + drift * 0.4
                let y = (CGFloat((index * 7) % 24) - weatherAnimationPhase * 25)
                    .truncatingRemainder(dividingBy: 25) + 2
                NSColor.white.withAlphaComponent(0.72).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2.0, height: 2.0)).fill()
            }
        case .unknown:
            drawWeatherCloud(center: NSPoint(x: 92 + drift, y: 16), scale: 1.5, alpha: 0.32)
        }
        NSColor.black.withAlphaComponent(0.04).setFill(); shell.fill()
        let border = colors[0].blended(withFraction: 0.34, of: .black) ?? colors[0]
        border.withAlphaComponent(0.92).setStroke(); shell.lineWidth = 0.8; shell.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawWeatherSun(center: NSPoint, radius: CGFloat, pulse: CGFloat, angle: CGFloat) {
        NSColor.systemYellow.withAlphaComponent(0.17 + pulse * 0.10).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius - 4, y: center.y - radius - 4,
                                    width: (radius + 4) * 2, height: (radius + 4) * 2)).fill()
        NSColor.systemYellow.withAlphaComponent(0.42 + pulse * 0.14).setStroke()
        for ray in 0..<8 {
            let direction = angle * 0.18 + CGFloat(ray) * .pi / 4
            let inner = radius + 1.5
            let outer = radius + 4.5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: center.x + cos(direction) * inner,
                                  y: center.y + sin(direction) * inner))
            path.line(to: NSPoint(x: center.x + cos(direction) * outer,
                                  y: center.y + sin(direction) * outer))
            path.lineWidth = 1.2; path.lineCapStyle = .round; path.stroke()
        }
        NSColor(calibratedRed: 1, green: 0.78, blue: 0.15, alpha: 0.62).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }

    private func drawWeatherMoon(center: NSPoint, radius: CGFloat) {
        NSColor(calibratedRed: 0.82, green: 0.91, blue: 1, alpha: 0.58).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
        NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.29, alpha: 0.90).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius * 0.15, y: center.y - radius * 0.55,
                                    width: radius * 1.4, height: radius * 1.4)).fill()
    }

    private func drawWeatherStars(pulse: CGFloat) {
        let stars: [(CGFloat, CGFloat, CGFloat)] = [(49, 23, 1.7), (68, 10, 1.3), (87, 25, 1.4), (118, 7, 1.2)]
        for (index, star) in stars.enumerated() {
            let twinkle = index.isMultiple(of: 2) ? pulse : 1 - pulse
            NSColor.white.withAlphaComponent(0.38 + twinkle * 0.42).setFill()
            NSBezierPath(ovalIn: NSRect(x: star.0, y: star.1, width: star.2, height: star.2)).fill()
        }
    }

    private func drawWeatherCloud(center: NSPoint, scale: CGFloat, alpha: CGFloat) {
        NSColor(calibratedRed: 0.67, green: 0.77, blue: 0.84, alpha: alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 18 * scale, y: center.y - 4 * scale,
                                    width: 36 * scale, height: 9 * scale)).fill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 12 * scale, y: center.y - 1 * scale,
                                    width: 14 * scale, height: 11 * scale)).fill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2 * scale, y: center.y - 2 * scale,
                                    width: 15 * scale, height: 13 * scale)).fill()
    }

    private func drawBattery(_ model: AppModel, accent: NSColor) {
        let status = Self.batteryStatusLines(for: model.batteryState)
        let statusRect = Self.batteryStatusRect()
        touchText(status.0, rect: NSRect(x: statusRect.minX, y: 15, width: statusRect.width, height: 12),
                  size: Self.batteryStatusFontSize, color: .white.withAlphaComponent(0.9), weight: .semibold)
        touchText(status.1, rect: NSRect(x: statusRect.minX, y: 3, width: statusRect.width, height: 12),
                  size: Self.batteryStatusFontSize, color: .white.withAlphaComponent(0.9), weight: .semibold)
        let percentage = model.value(.battery, compact: true)
        let percentageRect = Self.batteryPercentageDrawingRect(text: percentage, width: bounds.width)
        (percentage as NSString).draw(at: percentageRect.origin, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Self.batteryPercentageFontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ])
        touchText(model.batteryEstimate.caption, rect: Self.batteryCaptionRect(width: bounds.width),
                  size: 7.2, color: .white.withAlphaComponent(0.82), align: .right)
        if case .restored = model.batteryEstimate {
            drawRestoredBolt(rect: Self.batteryRestoredIconRect(width: bounds.width))
        } else {
            touchText(model.batteryEstimate.text, rect: Self.batteryTimeRect(width: bounds.width),
                      size: Self.batteryTimeFontSize, color: .white, weight: .semibold, align: .right)
        }
    }

    private func drawRestoredBolt(rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + rect.width * 0.58, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.43))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.43))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.29, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.82, y: rect.minY + rect.height * 0.58))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.55, y: rect.minY + rect.height * 0.58))
        path.close()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 2.5; path.lineJoinStyle = .round; path.stroke()
        NSColor.white.withAlphaComponent(0.95).setFill(); path.fill()
    }

    private func drawBatteryBackground(_ model: AppModel, accent: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let shellRect = bounds.insetBy(dx: 0, dy: 0.5)
        let shell = NSBezierPath(roundedRect: shellRect, xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: 0.27, alpha: 1).setFill(); shell.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke(); shell.lineWidth = 0.65; shell.stroke()

        guard let percent = model.number(.battery), percent.isFinite else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let level = min(1, max(0, CGFloat(percent / 100)))
        guard level > 0 else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        let animated: Bool, charging: Bool
        switch model.batteryState {
        case .charging: animated = true; charging = true
        case .discharging: animated = true; charging = false
        default: animated = false; charging = false
        }

        shell.addClip()
        let motionEnabled = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let direction: CGFloat = charging ? 1 : -1
        let wavePhase = motionEnabled ? batteryAnimationPhase * 2 * .pi * direction : 0
        let nominalEdge = shellRect.minX + shellRect.width * level
        let liquid = NSBezierPath()
        liquid.move(to: NSPoint(x: shellRect.minX, y: shellRect.minY))
        liquid.line(to: NSPoint(x: nominalEdge, y: shellRect.minY))
        let steps = 12
        for step in 0...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let y = shellRect.minY + shellRect.height * fraction
            let edgeWave = motionEnabled && level < 0.995
                ? CGFloat(sin(Double(fraction * 3 * .pi + wavePhase))) * 1.5 : 0
            liquid.line(to: NSPoint(x: min(shellRect.maxX, max(shellRect.minX, nominalEdge + edgeWave)), y: y))
        }
        liquid.line(to: NSPoint(x: shellRect.minX, y: shellRect.maxY))
        liquid.close()
        let darkGreen = accent.blended(withFraction: 0.28, of: .black) ?? accent
        NSGradient(colors: [darkGreen.withAlphaComponent(0.76), accent.withAlphaComponent(0.72)])?
            .draw(in: liquid, angle: 0)

        guard motionEnabled else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        liquid.addClip()

        // A broad highlight and several curved ribbons travel with the power
        // direction. Their long cycle reads as a slow river or receding tide.
        let travel = charging ? batteryAnimationPhase : 1 - batteryAnimationPhase
        let bandCenter = shellRect.minX - 24 + (shellRect.width + 48) * travel
        let bandRect = NSRect(x: bandCenter - 24, y: shellRect.minY,
                              width: 48, height: shellRect.height)
        NSGradient(colors: [.clear, NSColor.white.withAlphaComponent(0.16), .clear])?
            .draw(in: bandRect, angle: 0)

        for index in 0..<5 {
            let raw = (batteryAnimationPhase + CGFloat(index) / 5)
                .truncatingRemainder(dividingBy: 1)
            let stream = charging ? raw : 1 - raw
            let centerX = shellRect.minX - 18 + (shellRect.width + 36) * stream
            let centerY = shellRect.minY + 5 + CGFloat(index % 3) * 7
            let ribbon = NSBezierPath()
            ribbon.move(to: NSPoint(x: centerX - 15, y: centerY - direction * 1.2))
            ribbon.curve(to: NSPoint(x: centerX + 15, y: centerY + direction * 1.2),
                         controlPoint1: NSPoint(x: centerX - 5, y: centerY + direction * 2.2),
                         controlPoint2: NSPoint(x: centerX + 5, y: centerY - direction * 2.2))
            NSColor.white.withAlphaComponent(charging ? 0.14 : 0.10).setStroke()
            ribbon.lineWidth = charging ? 1.05 : 0.8
            ribbon.lineCapStyle = .round; ribbon.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor final class TouchBarOverviewView: NSView {
    private var metrics: [MetricTouchButton] = []
    private let quota: CodexQuotaView
    init(model: AppModel, onSelect: @escaping (MetricKind) -> Void) {
        quota = CodexQuotaView(service: model.codex, width: TouchBarLayout.width(for: .codex)) { onSelect(.codex) }
        super.init(frame: NSRect(x: 0, y: 0, width: TouchBarLayout.width, height: 30))
        fixedSize(self, width: TouchBarLayout.width)
        for kind in TouchBarLayout.overviewKinds where kind != .codex {
            metrics.append(MetricTouchButton(kind: kind, model: model) { onSelect(kind) })
        }
        placeStack([quota] + metrics.map { $0 as NSView }, in: self, spacing: TouchBarLayout.spacing)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() { metrics.forEach { $0.refresh() }; quota.refresh() }
}

@MainActor final class TouchActionButton: NSButton {
    override var isFlipped: Bool { false }
    var label: String; var subtitle: String
    let symbol: String; let accent: NSColor
    private let onTap: () -> Void
    init(label: String, subtitle: String = "", symbol: String, width: CGFloat,
         color: NSColor, onTap: @escaping () -> Void) {
        self.label = label; self.subtitle = subtitle; self.symbol = symbol
        accent = color; self.onTap = onTap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        title = ""; isBordered = false; target = self; action = #selector(pressed)
        setButtonType(.momentaryChange); fixedSize(self, width: width); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { if isEnabled { onTap() } }
    override func draw(_ dirtyRect: NSRect) {
        touchBackground(bounds, color: accent, pressed: isHighlighted)
        let iconRect = label.isEmpty ? NSRect(x: (bounds.width - 13) / 2, y: 8, width: 13, height: 14) :
            NSRect(x: 8, y: 8, width: 14, height: 14)
        touchIcon(symbol, rect: iconRect, color: accent)
        if !label.isEmpty {
            touchText(label, rect: NSRect(x: 28, y: subtitle.isEmpty ? 7 : 13, width: bounds.width - 32, height: 16),
                      size: subtitle.isEmpty ? 11 : 10, color: isEnabled ? .white : .lightGray)
            if !subtitle.isEmpty {
                touchText(subtitle, rect: NSRect(x: 28, y: 1, width: bounds.width - 32, height: 12),
                          size: 7.5, color: .white.withAlphaComponent(0.6))
            }
        }
    }
}

@MainActor final class TouchBarPageView: NSView {
    let content: NSView
    private let updater: () -> Void
    init(content: NSView, update: @escaping () -> Void, back: @escaping () -> Void) {
        self.content = content; updater = update
        super.init(frame: NSRect(x: 0, y: 0, width: TouchBarLayout.width, height: 30))
        fixedSize(self, width: TouchBarLayout.width)
        let button = TouchActionButton(label: "", symbol: "chevron.left", width: 32, color: .lightGray, onTap: back)
        button.setAccessibilityLabel("返回监控总览")
        placeStack([button, content], in: self, spacing: 8)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() { updater() }
}

@MainActor final class MetricChartTouchView: NSView {
    let kind: MetricKind
    private weak var model: AppModel?
    init(kind: MetricKind, model: AppModel) {
        self.kind = kind; self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: TouchBarLayout.detailWidth, height: 30))
        fixedSize(self, width: TouchBarLayout.detailWidth)
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        setAccessibilityLabel("\(kind.title)历史曲线，当前 \(model?.value(kind, compact: true) ?? "—")，\(model?.trend(kind).label ?? "等待采样")，采样时间三分钟")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let accent = NSColor(kind.color)
        touchBackground(bounds, color: accent)
        let values = model.history[kind, default: []].filter(\.isFinite)
        touchIcon(kind.symbol, rect: NSRect(x: 7, y: 7, width: 17, height: 17), color: accent)
        touchText(kind.title, rect: NSRect(x: 31, y: 18, width: 68, height: 10), size: 8, color: .white.withAlphaComponent(0.75))
        touchText(model.value(kind, compact: true), rect: NSRect(x: 31, y: 0, width: 68, height: 19), size: 15, weight: .semibold)
        let graph = NSRect(x: 107, y: 3, width: bounds.width - 180, height: 23)
        drawTrend(model.trend(kind))
        touchText("采样时间三分钟", rect: NSRect(x: bounds.width - 72, y: 2, width: 65, height: 12), size: 8,
                  color: .white.withAlphaComponent(0.65), align: .right)
        guard values.count > 1 else {
            touchText("正在积累曲线…", rect: NSRect(x: graph.minX + 10, y: 8, width: graph.width, height: 15), size: 10, color: .lightGray)
            return
        }
        let minimum = values.min()!, maximum = values.max()!
        let lower = kind == .temperature ? max(0, minimum - 3) : 0
        let upper = kind == .temperature ? max(lower + 10, maximum + 3) : 100
        let points = values.enumerated().map { index, value in
            NSPoint(x: graph.minX + graph.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: graph.minY + graph.height * CGFloat(min(1, max(0, (value - lower) / (upper - lower)))))
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: graph).addClip()
        let path = NSBezierPath(); path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: graph.maxX, y: graph.minY))
        fill.line(to: NSPoint(x: graph.minX, y: graph.minY)); fill.close()
        accent.withAlphaComponent(0.17).setFill(); fill.fill()
        accent.setStroke(); path.lineWidth = 1.6; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawTrend(_ trend: MetricTrend) {
        let centerX = bounds.width - 37
        switch trend {
        case .rising, .falling:
            let path = NSBezierPath()
            if trend == .rising {
                path.move(to: NSPoint(x: centerX, y: 27))
                path.line(to: NSPoint(x: centerX - 5, y: 18))
                path.line(to: NSPoint(x: centerX + 5, y: 18))
            } else {
                path.move(to: NSPoint(x: centerX, y: 17))
                path.line(to: NSPoint(x: centerX - 5, y: 26))
                path.line(to: NSPoint(x: centerX + 5, y: 26))
            }
            path.close()
            (trend == .rising ? NSColor.systemRed : NSColor.systemGreen).setFill()
            path.fill()
        case .steady, .unknown:
            touchText("—", rect: NSRect(x: centerX - 8, y: 15, width: 16, height: 15), size: 11,
                      color: .lightGray, align: .center)
        }
    }
}

@MainActor final class WeatherTouchDetailView: NSView {
    private weak var model: AppModel?
    init(model: AppModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: TouchBarLayout.detailWidth, height: 30))
        fixedSize(self, width: TouchBarLayout.detailWidth)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let accent = NSColor(MetricKind.weather.color)
        touchBackground(bounds, color: accent)
        let w = model.weather.snapshot
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = w?.weatherTimeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        fmt.dateFormat = "HH:mm"
        let rain = w?.precipitationProbability.map { String(format: "%.0f%%", $0) } ?? "—"
        let sunrise = w?.sunrise.map(fmt.string(from:)) ?? "—"
        let sunset = w?.sunset.map(fmt.string(from:)) ?? "—"
        let cached = model.weather.isStale && w != nil
        let placeLabel = model.weatherRegion + (cached ? " · 缓存" : (model.weather.isLocationStale ? " · 上次位置" : ""))
        let labels = [placeLabel, cached ? "降雨 · 缓存" : "下一小时降雨", cached ? "日出 · 缓存" : "日出", cached ? "日落 · 缓存" : "日落"]
        let values = [model.value(.weather, compact: true), rain, sunrise, sunset]
        let icons = [w?.symbol ?? "cloud.sun.fill", "cloud.rain", "sunrise.fill", "sunset.fill"]
        let column = bounds.width / 4
        for index in 0..<4 {
            let x = CGFloat(index) * column
            if index > 0 {
                NSColor.white.withAlphaComponent(0.1).setFill()
                NSRect(x: x, y: 7, width: 0.5, height: 16).fill()
            }
            touchIcon(icons[index], rect: NSRect(x: x + 10, y: 7, width: 19, height: 17), color: accent)
            touchText(labels[index], rect: NSRect(x: x + 36, y: 18, width: column - 42, height: 10), size: 8,
                      color: .white.withAlphaComponent(0.7))
            touchText(values[index], rect: NSRect(x: x + 36, y: 0, width: column - 42, height: 19), size: 15, weight: .semibold)
        }
        setAccessibilityLabel(zip(labels, values).map { "\($0): \($1)" }.joined(separator: "，") + (model.weather.isStale ? "，缓存数据" : ""))
    }
}

@MainActor final class TouchInfoView: NSView {
    var lines: () -> [String]; var accent: NSColor
    init(width: CGFloat, color: NSColor, lines: @escaping () -> [String]) {
        self.lines = lines; accent = color
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        fixedSize(self, width: width); setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let content = lines()
        touchBackground(bounds, color: accent)
        for (i, line) in content.prefix(2).enumerated() {
            touchText(line, rect: NSRect(x: 8, y: i == 0 ? 15 : 1, width: bounds.width - 16, height: 14),
                      size: i == 0 ? 9 : 8, color: i == 0 ? .white : .white.withAlphaComponent(0.65))
        }
        setAccessibilityLabel(content.joined(separator: "，"))
    }
}

@MainActor final class CodexTouchDetailView: NSView {
    private let quota: CodexQuotaView, refreshButton: TouchActionButton, info: TouchInfoView
    private weak var service: CodexUsageService?
    init(service: CodexUsageService) {
        self.service = service
        quota = CodexQuotaView(service: service, width: 260, onTap: {})
        refreshButton = TouchActionButton(label: "立即刷新", subtitle: "重新读取本地日志", symbol: "arrow.clockwise", width: 110, color: .lightGray) { [weak service] in
            service?.refresh(force: true)
        }
        info = TouchInfoView(width: TouchBarLayout.detailWidth - 260 - 110 - 12, color: .gray) { [weak service] in
            guard let snapshot = service?.snapshot else { return ["纯本地 · 未读取凭据", service?.status ?? "等待额度记录"] }
            let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "HH:mm:ss"
            return ["记录 \(fmt.string(from: snapshot.observedAt))", "读取 \(fmt.string(from: snapshot.readAt))"]
        }
        super.init(frame: NSRect(x: 0, y: 0, width: TouchBarLayout.detailWidth, height: 30))
        fixedSize(self, width: TouchBarLayout.detailWidth)
        placeStack([quota, refreshButton, info], in: self, spacing: 6)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        quota.refresh()
        refreshButton.label = service?.isRefreshing == true ? "读取中…" : "立即刷新"
        refreshButton.isEnabled = service?.isRefreshing != true
        refreshButton.needsDisplay = true; info.needsDisplay = true
    }
}

@MainActor func makeTouchBarPage(kind: MetricKind, model: AppModel, back: @escaping () -> Void) -> TouchBarPageView {
    switch kind {
    case .temperature, .cpu, .memory:
        let v = MetricChartTouchView(kind: kind, model: model)
        return TouchBarPageView(content: v, update: { [weak v] in v?.refresh() }, back: back)
    case .weather:
        let v = WeatherTouchDetailView(model: model)
        return TouchBarPageView(content: v, update: { [weak v] in v?.refresh() }, back: back)
    case .battery:
        preconditionFailure("Battery is a read-only overview item")
    case .codex:
        let v = CodexTouchDetailView(service: model.codex)
        return TouchBarPageView(content: v, update: { [weak v] in v?.refresh() }, back: back)
    }
}

struct TouchBarPreview: NSViewRepresentable {
    @ObservedObject var model: AppModel
    final class Coordinator { var selection: MetricKind? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TouchBarTransitionView {
        context.coordinator.selection = model.selectedMetric
        return TouchBarTransitionView(initialView: content())
    }
    func updateNSView(_ nsView: TouchBarTransitionView, context: Context) {
        if context.coordinator.selection != model.selectedMetric {
            let direction: TouchBarTransitionDirection = model.selectedMetric == nil ? .backward : .forward
            context.coordinator.selection = model.selectedMetric
            nsView.setContent(content(), direction: direction)
        }
        (nsView.currentContent as? TouchBarOverviewView)?.refresh()
        (nsView.currentContent as? TouchBarPageView)?.refresh()
    }
    private func content() -> NSView {
        if let kind = model.selectedMetric, kind.hasDetail {
            return makeTouchBarPage(kind: kind, model: model) { [weak model] in model?.returnToOverview?() }
        }
        return TouchBarOverviewView(model: model) { [weak model] kind in model?.selectMetric(kind) }
    }
}
