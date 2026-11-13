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
    /// Processes known to have no menu bar extra, so later scans can skip them.
    /// Re-checked every 30 s (an app can add a status item at any time).
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var noExtras: Set<pid_t> = []
    nonisolated(unsafe) private static var noExtrasStamp = Date.distantPast

    static func scan() -> [MenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        cacheLock.lock()
        if Date().timeIntervalSince(noExtrasStamp) > 30 { noExtras.removeAll(); noExtrasStamp = Date() }
        let skip = noExtras
        cacheLock.unlock()

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ownPID && !skip.contains($0.processIdentifier)
        }

        // Query every app in parallel with a short timeout, so one unresponsive app
        // can't stall the whole scan.
        let lock = NSLock()
        var result: [MenuBarItem] = []
        var problems: [String] = []
        var empty: [pid_t] = []

        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            let (items, problem, hasNone) = scanApp(app)
            lock.lock()
            result += items
            if let problem { problems.append(problem) }
            if hasNone { empty.append(app.processIdentifier) }
            lock.unlock()
        }

        cacheLock.lock()
        noExtras.formUnion(empty)
        cacheLock.unlock()

        DiagnosticsLog.write(trusted: AXIsProcessTrusted(), found: result.map { "\($0.id) \($0.frame)" }, problems: problems)
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Returns the app's menu bar items, an optional problem description, and whether the
    /// app definitely has no menu bar extra (safe to skip next time).
    private static func scanApp(_ app: NSRunningApplication) -> ([MenuBarItem], String?, Bool) {
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        var barRef: CFTypeRef?
        let barErr = AXUIElementCopyAttributeValue(appEl, "AXExtrasMenuBar" as CFString, &barRef)
        guard barErr == .success, let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else {
            switch barErr {
            case .noValue, .attributeUnsupported, .success:
                return ([], nil, true)            // no menu bar extra
            case .apiDisabled:
                return ([], "\(name) AXExtrasMenuBar error \(barErr.rawValue)", false)
            default:
                // Timeouts etc.: skip for now (re-checked when the cache expires).
                return ([], "\(name) AXExtrasMenuBar error \(barErr.rawValue)", true)
            }
        }
        let bar = barRef as! AXUIElement
        guard let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute) else {
            return ([], "\(name) children unreadable", false)
        }

        var items: [MenuBarItem] = []
        for (index, el) in kids.enumerated() {
            guard let frame = frame(of: el) else { continue }
            guard frame.width > 0, frame.minY < 60 else { continue } // skip off-bar placeholders
            let label = [attr(el, kAXTitleAttribute) as String?,
                         attr(el, kAXDescriptionAttribute) as String?,
                         attr(el, kAXHelpAttribute) as String?]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let key = app.bundleIdentifier ?? name
            items.append(MenuBarItem(
                id: "\(key)#\(index)",
                pid: app.processIdentifier,
                appName: name,
                bundleID: app.bundleIdentifier,
                label: label,
                frame: frame,
                element: el,
                appIcon: app.icon,
                movable: !isFixed(bundleID: app.bundleIdentifier, label: label)
            ))
        }
        return (items, nil, false)
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
