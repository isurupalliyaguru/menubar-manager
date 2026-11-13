import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices

@MainActor
final class AppController: NSObject {
    private let status = StatusBarController()
    private let icons = IconCapture()
    private let model = PanelModel()
    private lazy var panel: DropdownPanel = {
        let host = NSHostingView(rootView: PanelView(model: model))
        return DropdownPanel(content: host)
    }()

    private var outsideClickMonitor: Any?
    private var rehideMonitor: Any?
    private var menuWatchTimer: Timer?

    private let defaults = UserDefaults.standard
    private var showAll: Bool {
        get { defaults.bool(forKey: "showAll") }
        set { defaults.set(newValue, forKey: "showAll") }
    }

    func start() {
        status.onChevronClick = { [weak self] in self?.togglePanel() }
        status.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }

        model.onActivate = { [weak self] in self?.activate($0) }
        model.onTogglePin = { [weak self] in self?.togglePin($0) }
        model.onRequestAX = { [weak self] in self?.requestAccessibility() }
        model.onRequestScreenCapture = { [weak self] in
            self?.icons.requestPermission()
            self?.openPrivacyPane("Privacy_ScreenCapture")
        }
        model.onRefresh = { [weak self] in self?.refresh(captureIcons: true) }
        model.onRelaunch = { Self.relaunch() }

        if !AXIsProcessTrusted() {
            requestAccessibility()
            watchForAccessibilityGrant()
        }

        // Wait for status items to get windows before checking layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            Task { await self.captureVisibleIcons() }
            if !self.showAll { self.collapseOrWarn() }
        }
    }

    // MARK: Panel

    private func togglePanel() {
        panel.isVisible ? closePanel() : openPanel()
    }

    private func openPanel() {
        refresh(captureIcons: false)
        let size = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 300)
        guard let chevronFrame = status.chevron.button?.window?.frame,
              let screen = status.chevronScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var x = chevronFrame.maxX - size.width
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = chevronFrame.minY - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    private func resizePanelToFit() {
        guard panel.isVisible, let size = panel.contentView?.fittingSize else { return }
        var f = panel.frame
        f.origin.y += f.height - size.height
        f.size.height = size.height
        panel.setFrame(f, display: true, animate: false)
    }

    // MARK: Data

    private func refresh(captureIcons: Bool) {
        model.axTrusted = AXIsProcessTrusted()
        model.screenCaptureGranted = icons.hasPermission
        let sepX = status.cgFrame(of: status.separator)?.minX ?? -.infinity
        var items = MenuBarItemScanner.scan()
        for i in items.indices {
            items[i].section = items[i].frame.midX < sepX ? .hidden : .visible
            items[i].image = icons.cached(items[i].id)
        }
        model.items = items
        if ProcessInfo.processInfo.environment["MBM_DEBUG"] != nil {
            FileHandle.standardError.write("refresh sepX=\(sepX) count=\(items.count)\n".data(using: .utf8)!)
            for i in items { FileHandle.standardError.write("  \(i.id) \(i.section) \(i.frame)\n".data(using: .utf8)!) }
        }
        DispatchQueue.main.async { [weak self] in self?.resizePanelToFit() }
        if captureIcons { Task { await self.captureVisibleIcons() } }
    }

    private func captureVisibleIcons() async {
        await icons.capture(MenuBarItemScanner.scan())
        for i in model.items.indices { model.items[i].image = icons.cached(model.items[i].id) ?? model.items[i].image }
    }

    // MARK: Actions

    /// Opens a hidden item's menu: reveal the hidden section, click the item, hide again afterwards.
    private func activate(_ item: MenuBarItem) {
        guard ensureTrusted() else { return }
        closePanel()
        let wasCollapsed = status.isCollapsed
        if wasCollapsed { status.expand() }

        waitUntilOnScreen(item, deadline: Date().addingTimeInterval(1.5)) { [weak self] frame in
            guard let self else { return }
            // Synthetic clicks under the notch are swallowed by the system, so items that
            // land there get an Accessibility "press" instead (the menu still drops down
            // below the notch where it's visible). Everywhere else a real click is the most
            // compatible option.
            if let frame, !Self.isUnderNotch(frame) {
                MouseSimulator.click(at: CGPoint(x: frame.midX, y: frame.midY))
            } else if AXUIElementPerformAction(item.element, kAXPressAction as CFString) != .success, let frame {
                MouseSimulator.click(at: CGPoint(x: frame.midX, y: frame.midY))
            }
            Task { await self.captureVisibleIcons() } // good moment: everything is on screen
            if wasCollapsed { self.scheduleRehide(pid: item.pid) }
        }
    }

    /// True if a CG-coordinate frame overlaps the camera housing on a notched display.
    static func isUnderNotch(_ frame: CGRect) -> Bool { overlaps(frame, notchRange()) }

    /// macOS relayouts the bar asynchronously after the separator shrinks, so poll the
    /// item's live position until it lands on screen and stops moving.
    private func waitUntilOnScreen(_ item: MenuBarItem, deadline: Date, last: CGRect? = nil,
                                   completion: @escaping (CGRect?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let frame = MenuBarItemScanner.frame(of: item.element)
            if let frame, frame.minX >= 0, frame == last {
                completion(frame)
            } else if Date() > deadline {
                completion(frame.flatMap { $0.minX >= 0 ? $0 : nil })
            } else {
                self.waitUntilOnScreen(item, deadline: deadline, last: frame, completion: completion)
            }
        }
    }

    /// Collapse again once the user is done with the opened menu.
    ///
    /// Primary signal: the app's pop-up menu window appears and then goes away (works no
    /// matter how the menu is closed: click, Escape, choosing an item). Fallback for apps
    /// that open something other than a menu: the next click anywhere. Safety net: 5 min.
    private func scheduleRehide(pid: pid_t) {
        cancelRehide()
        var sawMenu = false
        var elapsed: TimeInterval = 0
        menuWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                elapsed += 0.3
                let open = Self.hasOpenMenu(pid: pid)
                if open { sawMenu = true }
                if (sawMenu && !open) || elapsed > 300 { self.rehideNow() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.menuWatchTimer != nil else { return }
            self.rehideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !sawMenu { self?.rehideNow() }
                }
            }
        }
    }

    /// Menus and popovers live in windows above the status bar level, owned by the app.
    private static func hasOpenMenu(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            (($0[kCGWindowLayer as String] as? Int) ?? 0) > statusLevel &&
            (($0[kCGWindowLayer as String] as? Int) ?? 0) < Int(CGWindowLevelForKey(.screenSaverWindow))
        }
    }

    private func rehideNow() {
        cancelRehide()
        if !showAll { status.collapse() }
    }

    private func cancelRehide() {
        if let m = rehideMonitor { NSEvent.removeMonitor(m); rehideMonitor = nil }
        menuWatchTimer?.invalidate(); menuWatchTimer = nil
    }

    /// Moves an item across the separator with a synthetic ⌘-drag.
    private func togglePin(_ item: MenuBarItem) {
        guard ensureTrusted(), item.movable else { return }
        let toVisible = item.section == .hidden
        let wasCollapsed = status.isCollapsed
        cancelRehide()
        if wasCollapsed { status.expand() }
        model.busy = true
        model.message = nil

        waitUntilOnScreen(item, deadline: Date().addingTimeInterval(1.5)) { [weak self] from in
            guard let self else { return }
            guard let from, self.status.cgFrame(of: self.status.separator) != nil else {
                self.finishPin(wasCollapsed: wasCollapsed, error: "Couldn't find that icon. Try refreshing.")
                return
            }
            let notch = Self.notchRange()
            let separatorFrame: () -> CGRect = { [weak self] in
                DispatchQueue.main.sync { self?.status.cgFrame(of: self!.status.separator) ?? .zero }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var frame = from
                // Nothing (not even a person) can drag an icon that sits behind the notch.
                // Make room instead: move hidden icons that ARE reachable to the far left,
                // one by one, until this icon slides out from under the notch.
                if let notch {
                    var attempts = 0
                    while Self.overlaps(frame, notch) && attempts < 15 {
                        attempts += 1
                        let sepMinX = separatorFrame().minX
                        guard let mover = MenuBarItemScanner.scan().first(where: {
                            $0.id != item.id && $0.movable && $0.frame.minX >= notch.upperBound && $0.frame.maxX <= sepMinX
                        }) else { break }
                        MouseSimulator.commandDrag(from: CGPoint(x: mover.frame.midX, y: mover.frame.midY),
                                                   to: CGPoint(x: notch.lowerBound - 40, y: mover.frame.midY))
                        usleep(350_000)
                        frame = MenuBarItemScanner.frame(of: item.element) ?? frame
                    }
                }
                let sep = separatorFrame()
                if !Self.overlaps(frame, notch) && frame.minX >= 0 {
                    MouseSimulator.commandDrag(from: CGPoint(x: frame.midX, y: frame.midY),
                                               to: CGPoint(x: toVisible ? sep.maxX + 2 : sep.minX - 2, y: sep.midY))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    let moved = MenuBarItemScanner.frame(of: item.element).map { f -> Bool in
                        let nowVisible = f.midX >= (self.status.cgFrame(of: self.status.separator)?.minX ?? 0)
                        return nowVisible == toVisible
                    } ?? false
                    self.finishPin(wasCollapsed: wasCollapsed, error: moved ? nil : "Couldn't move that icon. Try again, or ⌘-drag it across the │ separator.")
                }
            }
        }
    }

    /// Horizontal span of the notch in global coordinates, or nil on displays without one.
    static func notchRange() -> ClosedRange<CGFloat>? {
        guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return (screen.frame.minX + left.maxX)...(screen.frame.minX + right.minX)
    }

    static func overlaps(_ frame: CGRect, _ notch: ClosedRange<CGFloat>?) -> Bool {
        guard let notch else { return false }
        return frame.maxX > notch.lowerBound && frame.minX < notch.upperBound
    }

    private func finishPin(wasCollapsed: Bool, error: String?) {
        Task {
            await captureVisibleIcons()
            if wasCollapsed && !showAll { status.collapse() }
            model.busy = false
            model.message = error
            refresh(captureIcons: false)
        }
    }

    // MARK: Collapse state

    private func collapseOrWarn() {
        if !status.collapse() {
            let alert = NSAlert()
            alert.messageText = "Separator is in the wrong place"
            alert.informativeText = "⌘-drag the │ separator so it sits to the left of the chevron, then choose “Hide icons” from the chevron's right-click menu."
            alert.runModal()
        }
    }

    private func setShowAll(_ value: Bool) {
        showAll = value
        if value { status.expand() } else { collapseOrWarn() }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show all icons in menu bar", action: #selector(menuToggleShowAll), keyEquivalent: "")
        toggle.state = showAll ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at login", action: #selector(menuToggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        let ax = NSMenuItem(title: AXIsProcessTrusted() ? "Accessibility: granted" : "Grant Accessibility access…",
                            action: #selector(menuRequestAX), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
        let sc = NSMenuItem(title: icons.hasPermission ? "Screen Recording: granted" : "Allow Screen Recording (real icons)…",
                            action: #selector(menuRequestSC), keyEquivalent: "")
        sc.target = self
        menu.addItem(sc)

        menu.addItem(.separator())
        let help = NSMenuItem(title: "Tip: ⌘-drag icons left of │ to hide them", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        let about = NSMenuItem(title: "About MenuBar Manager", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func menuToggleShowAll() { setShowAll(!showAll) }

    @objc private func menuToggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func menuRequestAX() { requestAccessibility() }
    @objc private func menuRequestSC() {
        icons.requestPermission()
        openPrivacyPane("Privacy_ScreenCapture")
    }
    @objc private func menuAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "github.com/isurupalliyaguru/menubar-manager")
        ])
    }

    // MARK: Permissions

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        requestAccessibility()
        model.axTrusted = false
        return false
    }

    /// Polls until the user flips the switch in System Settings, then refreshes the panel.
    private func watchForAccessibilityGrant() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            Task { @MainActor in
                guard let self else { return }
                self.refresh(captureIcons: true)
            }
        }
    }

    private func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openPrivacyPane("Privacy_Accessibility") }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
