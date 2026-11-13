import AppKit

/// Owns our two status items:
///
///     [hidden icons…] [│ separator] [always-visible icons…] [⌄ chevron] [system icons]
///
/// Collapsing stretches the separator to a huge width, which pushes every
/// item to its left off the screen.
@MainActor
final class StatusBarController {
    private static let collapsedLength: CGFloat = 10_000

    let chevron: NSStatusItem
    let separator: NSStatusItem
    private(set) var isCollapsed = false

    var onChevronClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    init() {
        Self.seedInitialPositions()
        // Items created later appear further left, so chevron first.
        chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevron.autosaveName = "MenuBarManager.chevron"
        separator = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        separator.autosaveName = "MenuBarManager.separator"

        if let b = chevron.button {
            b.image = NSImage(systemSymbolName: "chevron.compact.down", accessibilityDescription: "MenuBar Manager")
            b.target = self
            b.action = #selector(chevronClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if let b = separator.button {
            b.image = Self.separatorImage()
            b.target = self
            b.action = #selector(separatorClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "⌘-drag icons left of this line to hide them"
        }
    }

    /// New status items normally appear at the far left, which on a notched Mac is
    /// often behind the notch. On first launch, place the chevron and separator just
    /// left of Apple's system items, so every third-party icon starts out hidden.
    private static func seedInitialPositions() {
        let d = UserDefaults.standard
        let chevronKey = "NSStatusItem Preferred Position MenuBarManager.chevron"
        let sepKey = "NSStatusItem Preferred Position MenuBarManager.separator"
        guard d.object(forKey: chevronKey) == nil else { return }

        let screenMaxX = NSScreen.screens.first?.frame.maxX ?? 1440
        let systemIDs: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight"]
        let systemMinX = MenuBarItemScanner.scan()
            .filter { systemIDs.contains($0.bundleID ?? "") }
            .map(\.frame.minX)
            .min()
        let fromRight = systemMinX.map { screenMaxX - $0 + 2 } ?? 360
        d.set(fromRight, forKey: chevronKey)
        d.set(fromRight + 30, forKey: sepKey)
    }

    // MARK: Collapse / expand

    /// Hides everything left of the separator. Refuses if the layout is broken
    /// (separator dragged right of the chevron would hide the chevron too).
    @discardableResult
    func collapse() -> Bool {
        guard layoutIsValid else { return false }
        separator.button?.image = nil
        separator.length = Self.collapsedLength
        isCollapsed = true
        return true
    }

    func expand() {
        separator.length = NSStatusItem.variableLength
        separator.button?.image = Self.separatorImage()
        isCollapsed = false
    }

    var layoutIsValid: Bool {
        guard let s = frame(of: separator), let c = frame(of: chevron) else { return true }
        return s.maxX <= c.minX + 1
    }

    // MARK: Geometry (global CG coordinates, origin top-left)

    func cgFrame(of item: NSStatusItem) -> CGRect? { frame(of: item) }

    var chevronScreen: NSScreen? { chevron.button?.window?.screen }

    private func frame(of item: NSStatusItem) -> CGRect? {
        guard let w = item.button?.window else { return nil }
        let f = w.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? f.maxY
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    // MARK: Actions

    @objc private func chevronClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu(from: chevron)
        } else {
            onChevronClick?()
        }
    }

    @objc private func separatorClicked(_ sender: NSStatusBarButton) {
        showMenu(from: separator)
    }

    private func showMenu(from item: NSStatusItem) {
        guard let menu = menuProvider?() else { return }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private static func separatorImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 8, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3.25, y: 2, width: 1.5, height: 12), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
