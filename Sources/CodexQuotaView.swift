import AppKit
import Combine

/// Compact Touch Bar rendering inspired by QuotaStrip (MIT, hohocf).
/// Row labels come from the recorded durations, never from account plan guesses.
@MainActor
final class CodexQuotaView: NSButton {
    private let service: CodexUsageService
    private let preferredWidth: CGFloat
    private let onTap: () -> Void
    private let icon: NSImage?
    private var observation: AnyCancellable?
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(service: CodexUsageService, width: CGFloat = 240, onTap: @escaping () -> Void) {
        self.service = service
        self.preferredWidth = max(180, width)
        self.onTap = onTap
        self.icon = Bundle.main.url(forResource: "codex-logo", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
        super.init(frame: NSRect(x: 0, y: 0, width: max(180, width), height: 30))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: preferredWidth).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityLabel("Codex 本地额度")
        observation = service.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 30) }
    @objc private func pressed() { onTap() }

    func refresh() {
        let now = Date()
        if let snapshot = service.snapshot {
            let windows = snapshot.windows.map { $0.effective(at: now) }
            let values = windows.map { window -> String in
                let used = window.usedPercent.map { "已用\(Int($0.rounded()))%" } ?? "用量未知"
                return "\(window.label) \(used)"
            }.joined(separator: "，")
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm:ss"
            toolTip = "Codex \(snapshot.planType ?? "") · \(values)\n记录时间：\(formatter.string(from: snapshot.observedAt))\n本地读取：\(formatter.string(from: snapshot.readAt))\n点击查看详情；数据来自本地记录，不主动查询服务器。"
            setAccessibilityValue(values + "，来自本地会话记录")
        } else {
            toolTip = service.status
            setAccessibilityValue(service.status)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: isHighlighted ? 0.29 : 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 0.5), xRadius: 7, yRadius: 7).fill()
        if let icon {
            icon.draw(in: NSRect(x: 4, y: 3, width: 24, height: 24), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            drawText("CX", rect: NSRect(x: 4, y: 8, width: 25, height: 15), size: 10.5,
                     color: .white, weight: .bold)
        }
        guard let snapshot = service.snapshot else {
            drawText(service.isRefreshing ? "读取本地额度…" : "Codex · 暂无额度记录",
                     rect: NSRect(x: 34, y: 8, width: bounds.width - 41, height: 15),
                     size: 11, color: NSColor(white: 0.78, alpha: 1))
            return
        }
        guard !snapshot.windows.isEmpty else {
            drawText("Codex · 未报告额度窗口", rect: NSRect(x: 34, y: 8,
                     width: bounds.width - 41, height: 15), size: 11,
                     color: NSColor(white: 0.78, alpha: 1))
            return
        }
        let now = Date()
        for (index, raw) in snapshot.windows.prefix(2).enumerated() {
            let y = snapshot.windows.count == 1 ? 7.5 : CGFloat(index) * 15
            drawRow(raw.effective(at: now), y: y, now: now)
        }
        // A record older than 15 minutes gets a quiet amber indicator; its actual
        // timestamp remains available in details. Expired percentages are blank.
        if now.timeIntervalSince(snapshot.observedAt) > 900 {
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: 23, y: 2, width: 4, height: 4)).fill()
        }
    }

    private func drawRow(_ window: CodexQuotaWindow, y: CGFloat, now: Date) {
        let labelWidth: CGFloat = window.label.count > 3 ? 32 : 24
        let xBar: CGFloat = 33 + labelWidth
        let resetWidth: CGFloat = 50
        let pctWidth: CGFloat = 36
        let xReset = bounds.width - resetWidth - 5
        let xPercent = xReset - pctWidth - 4
        let barWidth = max(18, xPercent - xBar - 6)
        drawText(window.label, rect: NSRect(x: 32, y: y + 1.5, width: labelWidth, height: 13),
                 size: 10.5, color: NSColor(white: 0.85, alpha: 1))
        let track = NSRect(x: xBar, y: y + 4, width: barWidth, height: 7)
        NSColor(white: 0.36, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
        let used = window.usedPercent
        if let used, used > 0 {
            let fill = NSRect(x: track.minX, y: track.minY,
                              width: track.width * CGFloat(min(100, max(0, used))) / 100, height: track.height)
            Self.quotaColor(used).setFill()
            NSBezierPath(roundedRect: fill, xRadius: min(3.5, fill.width / 2), yRadius: 3.5).fill()
        }
        drawText(used.map { String(format: "%.0f%%", $0) } ?? "—",
                 rect: NSRect(x: xPercent, y: y + 0.5, width: pctWidth, height: 14),
                 size: 11.5, color: used.map { $0 >= 50 ? Self.quotaColor($0) : .white } ?? .lightGray,
                 weight: .bold, alignment: .right)
        let reset = resetText(window, now: now)
        drawText(reset, rect: NSRect(x: xReset, y: y + 1.5, width: resetWidth, height: 13),
                 size: 10, color: NSColor(white: 0.90, alpha: 1))
    }

    private static func quotaColor(_ used: Double) -> NSColor {
        if used >= 80 { return .systemRed }
        if used >= 50 { return .systemYellow }
        return .systemGreen
    }

    private func resetText(_ window: CodexQuotaWindow, now: Date) -> String {
        guard let reset = window.resetsAt, reset > now else { return "" }
        if window.windowMinutes > 0, window.windowMinutes <= 1440 {
            return "↻" + clockFormatter.string(from: reset)
        }
        let seconds = max(0, Int(reset.timeIntervalSince(now)))
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "↻\(days)d\(hours)h" }
        if hours > 0 { return "↻\(hours)h\(minutes)m" }
        return "↻\(max(1, minutes))m"
    }

    private func drawText(_ text: String, rect: NSRect, size: CGFloat, color: NSColor,
                          weight: NSFont.Weight = .medium, alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: style
        ])
    }
}
