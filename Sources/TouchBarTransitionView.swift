import AppKit
import Combine
import QuartzCore

enum TouchBarTransitionDirection { case forward, backward }

/// A permanent Touch Bar viewport. Only the latest page receives input; outgoing
/// pages exist briefly for compositor-driven animation, then are released.
@MainActor final class TouchBarTransitionView: NSView {
    private(set) var currentContent: NSView
    private(set) var isTransitioning = false
    private var outgoing: NSView?
    private var transitionID = UUID()
    private var cleanup: DispatchWorkItem?
    private var accessibilityObservation: AnyCancellable?
    private static let opacityKey = "app.pulsebar.page.opacity"
    private static let slideKey = "app.pulsebar.page.slide"

    init(initialView: NSView) {
        currentContent = initialView
        super.init(frame: NSRect(x: 0, y: 0, width: TouchBarLayout.width, height: TouchBarLayout.height))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: TouchBarLayout.width),
            heightAnchor.constraint(equalToConstant: TouchBarLayout.height)])
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        install(initialView)
        setAccessibilityElement(false)
        accessibilityObservation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self?.cancelTransition() }
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize {
        NSSize(width: TouchBarLayout.width, height: TouchBarLayout.height)
    }

    func setContent(_ view: NSView, direction: TouchBarTransitionDirection = .forward, animated: Bool = true) {
        guard currentContent !== view else { return }
        let previous = currentContent
        let previousOpacity = previous.layer?.presentation()?.opacity ?? 1
        let previousX = previous.layer?.presentation()?.transform.m41 ?? 0
        cancelTransition()
        currentContent = view
        install(view)
        layoutSubtreeIfNeeded()
        let canAnimate = animated && window != nil &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard canAnimate, let incomingLayer = view.layer, let outgoingLayer = previous.layer else {
            previous.removeFromSuperview()
            normalize(view)
            return
        }
        outgoing = previous
        isTransitioning = true
        let id = UUID()
        transitionID = id
        let offset: CGFloat = direction == .forward ? 8 : -8
        let duration: CFTimeInterval = 0.2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingLayer.opacity = 1
        incomingLayer.transform = CATransform3DIdentity
        outgoingLayer.opacity = 0
        outgoingLayer.transform = CATransform3DMakeTranslation(-offset, 0, 0)
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.transitionID == id else { return }
                self.cancelTransition()
            }
        }
        animate(incomingLayer, path: "opacity", from: 0, to: 1, duration: duration, key: Self.opacityKey)
        animate(incomingLayer, path: "transform.translation.x", from: offset, to: 0, duration: duration, key: Self.slideKey)
        animate(outgoingLayer, path: "opacity", from: previousOpacity, to: 0, duration: duration, key: Self.opacityKey)
        animate(outgoingLayer, path: "transform.translation.x", from: previousX, to: -offset, duration: duration, key: Self.slideKey)
        CATransaction.commit()
        // A one-shot fallback handles a window detaching before Core Animation's
        // completion callback. There is no display link or continuously running timer.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transitionID == id else { return }
            self.cancelTransition()
        }
        cleanup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1, execute: work)
    }

    /// Snap to the newest page. Safe on rapid taps, hiding, sleep and teardown.
    func cancelTransition() {
        transitionID = UUID()
        cleanup?.cancel()
        cleanup = nil
        if let outgoing {
            normalize(outgoing)
            outgoing.removeFromSuperview()
        }
        outgoing = nil
        normalize(currentContent)
        isTransitioning = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelTransition() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        // AppKit passes a point in this view's superview coordinates. Its child
        // hitTest expects coordinates in this viewport, so convert exactly once.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return currentContent.hitTest(local) ?? self
    }

    private func install(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        addSubview(view, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)])
        normalize(view)
    }

    private func normalize(_ view: NSView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.removeAnimation(forKey: Self.opacityKey)
        view.layer?.removeAnimation(forKey: Self.slideKey)
        view.layer?.opacity = 1
        view.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func animate(_ layer: CALayer, path: String, from: Any, to: Any,
                         duration: CFTimeInterval, key: String) {
        let animation = CABasicAnimation(keyPath: path)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
    }
}
