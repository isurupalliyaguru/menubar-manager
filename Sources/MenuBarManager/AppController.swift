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
    private var rehideTimer: Timer?

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

        if !AXIsProcessTrusted() { requestAccessibility() }

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

        DispatchQueue.main.asyncAfter(deadline: .now() + (wasCollapsed ? 0.35 : 0.05)) { [weak self] in
            guard let self else { return }
            Task { await self.captureVisibleIcons() } // good moment: everything is on screen
            let frame = MenuBarItemScanner.frame(of: item.element) ?? item.frame
            if frame.minX >= 0 {
                MouseSimulator.click(at: CGPoint(x: frame.midX, y: frame.midY))
            } else {
                // Didn't fit on screen even when expanded; ask the app directly.
                AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            }
            if wasCollapsed { self.scheduleRehide() }
        }
    }

    /// Collapse again once the user is done with the opened menu (next click anywhere, or a timeout).
    private func scheduleRehide() {
        cancelRehide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.rehideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyDown]) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.rehideNow() }
            }
            self.rehideTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.rehideNow() }
            }
        }
    }

    private func rehideNow() {
        cancelRehide()
        if !showAll { status.collapse() }
    }

    private func cancelRehide() {
        if let m = rehideMonitor { NSEvent.removeMonitor(m); rehideMonitor = nil }
        rehideTimer?.invalidate(); rehideTimer = nil
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard let from = MenuBarItemScanner.frame(of: item.element),
                  let sep = self.status.cgFrame(of: self.status.separator) else {
                self.finishPin(wasCollapsed: wasCollapsed, error: "Couldn't find that icon. Try refreshing.")
                return
            }
            let start = CGPoint(x: from.midX, y: from.midY)
            let end = CGPoint(x: toVisible ? sep.maxX + 2 : sep.minX - 2, y: sep.midY)
            DispatchQueue.global(qos: .userInitiated).async {
                MouseSimulator.commandDrag(from: start, to: end)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    let moved = MenuBarItemScanner.frame(of: item.element).map { f -> Bool in
                        let nowVisible = f.midX >= (self.status.cgFrame(of: self.status.separator)?.minX ?? 0)
                        return nowVisible == toVisible
                    } ?? false
                    self.finishPin(wasCollapsed: wasCollapsed, error: moved ? nil : "macOS didn't move that icon. Try ⌘-dragging it manually.")
                }
            }
        }
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

    private func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        requestAccessibility()
        model.axTrusted = false
        return false
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
