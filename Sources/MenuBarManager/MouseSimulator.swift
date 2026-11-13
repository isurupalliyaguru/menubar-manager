import CoreGraphics
import Foundation

/// Synthesizes mouse input. Requires Accessibility permission.
enum MouseSimulator {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Clicks at a global CG point, then puts the cursor back where it was.
    static func click(at point: CGPoint, right: Bool = false) {
        let original = cursorLocation
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        post(.mouseMoved, at: point, button: button)
        usleep(15_000)
        post(down, at: point, button: button)
        usleep(30_000)
        post(up, at: point, button: button)
        usleep(30_000)
        CGWarpMouseCursorPosition(original)
    }

    /// ⌘-drag from one point to another (how macOS reorders menu bar items).
    /// Blocking; call off the main thread.
    static func commandDrag(from start: CGPoint, to end: CGPoint) {
        let original = cursorLocation
        post(.mouseMoved, at: start, button: .left)
        usleep(30_000)
        post(.leftMouseDown, at: start, button: .left, flags: .maskCommand)
        usleep(150_000)
        let steps = 24
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(.leftMouseDragged, at: p, button: .left, flags: .maskCommand)
            usleep(12_000)
        }
        usleep(150_000)
        post(.leftMouseUp, at: end, button: .left, flags: .maskCommand)
        usleep(50_000)
        CGWarpMouseCursorPosition(original)
    }

    private static func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, flags: CGEventFlags = []) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}
