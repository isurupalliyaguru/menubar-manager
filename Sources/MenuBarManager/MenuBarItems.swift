import AppKit
import ApplicationServices

/// One status item that some app has put in the menu bar.
struct MenuBarItem: Identifiable {
    enum Section { case visible, hidden }

    let id: String
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let label: String
    /// Frame in global CoreGraphics coordinates (origin top-left of main screen).
    let frame: CGRect
    let element: AXUIElement
    let appIcon: NSImage?
    let movable: Bool
    var section: Section = .visible
    var image: NSImage?

    var displayName: String {
        if !label.isEmpty, label != appName, label.count < 28 { return label }
        return appName
    }
}

/// Finds menu bar extras via the Accessibility API (`AXExtrasMenuBar`).
enum MenuBarItemScanner {
    static func scan() -> [MenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [MenuBarItem] = []
        var problems: [String] = []

        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 1.0)
            var barRef: CFTypeRef?
            let barErr = AXUIElementCopyAttributeValue(appEl, "AXExtrasMenuBar" as CFString, &barRef)
            guard barErr == .success, let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else {
                // Most apps simply have no menu bar extra (-25212 / -25205); log anything else.
                if barErr != .noValue && barErr != .attributeUnsupported && barErr != .success {
                    problems.append("\(app.localizedName ?? "?") AXExtrasMenuBar error \(barErr.rawValue)")
                }
                continue
            }
            let bar = barRef as! AXUIElement
            guard let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute) else {
                problems.append("\(app.localizedName ?? "?") children unreadable")
                continue
            }

            let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
            for (index, el) in kids.enumerated() {
                guard let frame = frame(of: el) else {
                    problems.append("\(app.localizedName ?? "?")#\(index) frame unreadable")
                    continue
                }
                guard frame.width > 0, frame.minY < 60 else { continue } // skip off-bar placeholders
                let label = [attr(el, kAXTitleAttribute) as String?,
                             attr(el, kAXDescriptionAttribute) as String?,
                             attr(el, kAXHelpAttribute) as String?]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                let key = app.bundleIdentifier ?? appName
                result.append(MenuBarItem(
                    id: "\(key)#\(index)",
                    pid: app.processIdentifier,
                    appName: appName,
                    bundleID: app.bundleIdentifier,
                    label: label,
                    frame: frame,
                    element: el,
                    appIcon: app.icon,
                    movable: !isFixed(bundleID: app.bundleIdentifier, label: label)
                ))
            }
        }
        DiagnosticsLog.write(trusted: AXIsProcessTrusted(), found: result.map { "\($0.id) \($0.frame)" }, problems: problems)
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Re-reads an element's live frame (positions change when we expand/collapse).
    static func frame(of el: AXUIElement) -> CGRect? {
        guard let posVal: AXValue = attr(el, kAXPositionAttribute),
              let sizeVal: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posVal, .cgPoint, &p)
        AXValueGetValue(sizeVal, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Clock and Control Center can't be reordered by the user.
    private static func isFixed(bundleID: String?, label: String) -> Bool {
        guard bundleID == "com.apple.controlcenter" else { return false }
        let l = label.lowercased()
        return l.contains("clock") || l.hasPrefix("control cent")
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// Writes the latest scan to ~/Library/Logs/MenuBarManager.log so problems can be diagnosed.
/// Local only; overwritten on every scan.
enum DiagnosticsLog {
    static func write(trusted: Bool, found: [String], problems: [String]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MenuBarManager.log")
        let text = (["scan at \(Date()) trusted=\(trusted)", "problems:"] + problems.map { "  " + $0 }
                    + ["found:"] + found.map { "  " + $0 }).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
