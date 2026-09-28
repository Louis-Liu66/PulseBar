import AppKit
import QuartzCore

#if PULSEBAR_TRANSITION_STANDALONE
// Host-only fixture matching the shipped 620pt viewport; this keeps lifecycle
// tests independent of weather/model edits and never constructs those services.
enum TouchBarLayout {
    static let width: CGFloat = 620
    static let height: CGFloat = 30
}
#endif

private final class WeakTransitionView {
    weak var value: NSView?
    init(_ value: NSView) { self.value = value }
}

@MainActor private final class TransitionProbePage: NSView {
    private(set) var taps = 0
    let button: NSButton
    init(_ title: String) {
        button = NSButton(title: title, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: TouchBarLayout.width, height: 30))
        button.frame = NSRect(x: 12, y: 0, width: 160, height: 30)
        button.target = self
        button.action = #selector(tapped)
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func tapped() { taps += 1 }
}

/// Hidden dummy-view tests. No AppModel or service is initialized; no hardware,
/// network, login setting, power setting or physical Touch Bar is touched.
@main struct TransitionTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError("FAIL: \(message)") }
            checks += 1
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: TouchBarLayout.width, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var host: TouchBarTransitionView? = TouchBarTransitionView(initialView: TransitionProbePage("Initial"))
        let weakHost = WeakTransitionView(host!)
        window.contentView = host
        host!.layoutSubtreeIfNeeded()
        require(host!.bounds.size == NSSize(width: TouchBarLayout.width, height: 30), "fixed viewport")
        require(host!.layer?.masksToBounds == true, "compositor clips viewport")
        require(host!.subviews.count == 1, "one initial page")
        require(host!.hitTest(NSPoint(x: -2, y: 15)) == nil, "outside viewport cannot receive input")

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var weakPages: [WeakTransitionView] = []
        for index in 0..<60 {
            autoreleasepool {
                let page = TransitionProbePage("Page \(index)")
                weakPages.append(WeakTransitionView(page))
                host!.setContent(page, direction: index.isMultiple(of: 2) ? .forward : .backward)
                host!.layoutSubtreeIfNeeded()
                require(host!.currentContent === page, "latest request wins \(index)")
                require(host!.subviews.count <= 2, "bounded outgoing pages \(index)")
                require(host!.isTransitioning == !reduceMotion, "respects Reduce Motion \(index)")
                let hit = host!.hitTest(NSPoint(x: 40, y: 15))
                require(hit === page.button, "only newest page receives input \(index)")
                page.button.performClick(nil)
                require(page.taps == 1 && page.button.isEnabled, "interaction remains enabled \(index)")
                if !reduceMotion {
                    let animations = page.layer?.animationKeys()?.compactMap { page.layer?.animation(forKey: $0) } ?? []
                    require(animations.count == 2, "fade and slide installed \(index)")
                    require(animations.allSatisfy { (0.18...0.22).contains($0.duration) }, "bounded animation duration \(index)")
                }
            }
        }
        CATransaction.flush()
        try await Task.sleep(nanoseconds: 400_000_000)
        require(!host!.isTransitioning && host!.subviews.count == 1, "animation finishes and removes outgoing page")
        require(weakPages.dropLast().allSatisfy { $0.value == nil }, "superseded pages are released")
        require(host!.currentContent.layer?.opacity == 1, "final content is opaque")
        require(CATransform3DIsIdentity(host!.currentContent.layer!.transform), "final transform is identity")

        autoreleasepool {
            host!.setContent(TransitionProbePage("Immediate"), animated: false)
            require(!host!.isTransitioning && host!.subviews.count == 1, "explicit nonanimated replacement")
        }
        require(weakPages.allSatisfy { $0.value == nil }, "all tested pages released after replacement")
        weakPages.removeAll()
        for index in 0..<30 {
            autoreleasepool {
                let page = TransitionProbePage("Cancelled \(index)")
                weakPages.append(WeakTransitionView(page))
                host!.setContent(page)
                host!.cancelTransition()
                require(!host!.isTransitioning && host!.subviews.count == 1, "cancellation settles latest page \(index)")
                require(page.layer?.opacity == 1 && CATransform3DIsIdentity(page.layer!.transform),
                        "cancellation restores drawing state \(index)")
            }
        }
        autoreleasepool {
            host!.setContent(TransitionProbePage("Detached while animating"))
            window.contentView = nil
            require(!host!.isTransitioning && host!.subviews.count == 1, "window detachment cancels animation")
            host = nil
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        require(weakHost.value == nil, "host released despite pending completion blocks")
        require(weakPages.allSatisfy { $0.value == nil }, "cancelled pages released")
        window.close()
        print("PASS: \(checks) transition assertions; 60 rapid swaps, 30 cancellations, latest-input routing and release checks.")
        print("Reduce Motion was \(reduceMotion ? "enabled" : "disabled"); system setting was not changed.")
    }
}
