import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    private var controller: TouchBarController!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.pulsebar.local")
        if let existing = siblings.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        makeMenu()
        makeWindow()
        controller = TouchBarController(model: model)
        model.onSample = { [weak self] in self?.controller.refresh() }
        model.showBar = { [weak self] in self?.controller.show() }
        model.hideBar = { [weak self] in self?.controller.hide() }
        model.openWindow = { [weak self] in self?.showWindow() }
        model.showTouchDetail = { [weak self] kind in self?.controller.showDetail(kind) }
        model.returnToOverview = { [weak self] in self?.controller.showOverview() }
        model.configureLoginOnLaunch()
        model.start()
        if !UserDefaults.standard.bool(forKey: "PulseBar.hasLaunched.v2.3") {
            showWindow()
            UserDefaults.standard.set(true, forKey: "PulseBar.hasLaunched.v2.3")
        }
        model.weather.start()
        model.codex.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.controller.show()
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller.suspend()
                self?.model.pause()
                self?.model.weather.stop()
                self?.model.codex.stop()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.model.start()
                self?.model.weather.start()
                self?.model.codex.start()
                self?.controller.resume()
            }
        })
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard controller != nil, !model.isPaused else { return }
        model.weather.start()
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 670),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "PulseBar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 670)
        window.backgroundColor = NSColor(red: 0.045, green: 0.055, blue: 0.078, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ScrollView {
            Dashboard(model: model, weather: model.weather, codex: model.codex).padding(.top, 23)
        }.background(Color(red: 0.045, green: 0.055, blue: 0.078)))
        window.center()
        window.setFrameAutosaveName("PulseBar.mainWindow")
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 PulseBar", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(closeWindow), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 PulseBar", action: #selector(quit), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "PulseBar")
        statusItem.button?.toolTip = "PulseBar · Touch Bar 实时监测"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "打开监控面板", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "显示 Touch Bar", action: #selector(showTouchBar), keyEquivalent: "")
        menu.addItem(withTitle: "恢复系统触控栏", action: #selector(hideTouchBar), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PulseBar", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first(where: { $0.action == #selector(showTouchBar) })?.isEnabled = model.touchBarSupported
    }
    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func closeWindow() { window.close() }
    @objc private func showTouchBar() { controller.show() }
    @objc private func hideTouchBar() { controller.hide() }
    @objc private func about() { showWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        model.pause()
        model.weather.stop()
        model.codex.stop()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}

@main struct PulseBarMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            let sampler = SystemSampler()
            print("PulseBar 2.9.1 | \(ProcessInfo.processInfo.operatingSystemVersionString) | TouchBar API: \(PBTouchBarSupported())")
            for i in 0..<6 {
                let s = sampler.sample()
                let cpu = s.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "baseline"
                let mem = s.memoryUsedBytes.map { String(format: "%.2f / %.0f GB", Double($0) / 1_073_741_824, Double(s.memoryTotalBytes) / 1_073_741_824) } ?? "unavailable"
                print("sample \(i): CPU \(cpu), memory \(mem), temperature \(s.temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "unavailable") (\(s.sensorCount) sensors), battery \(s.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "unavailable"), AC \(s.onACPower)")
                if i < 5 { Thread.sleep(forTimeInterval: 2) }
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
