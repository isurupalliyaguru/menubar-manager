import AppKit
import ScreenCaptureKit

/// Captures the real menu bar icon images (needs Screen Recording permission).
/// Falls back to app icons when permission is missing.
@MainActor
final class IconCapture {
    private var cache: [String: NSImage] = [:]

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func requestPermission() { CGRequestScreenCaptureAccess() }

    func cached(_ id: String) -> NSImage? { cache[id] }

    /// Captures images for items that are currently on screen and stores them in the cache.
    func capture(_ items: [MenuBarItem]) async {
        guard hasPermission else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        let barWindows = content.windows.filter { $0.windowLayer == Int(CGWindowLevelForKey(.statusWindow)) }
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        for item in items where item.frame.minX >= 0 {
            let midX = item.frame.midX
            let candidates = barWindows.filter { $0.frame.minX <= midX && $0.frame.maxX >= midX && $0.frame.height < 60 }
            guard let window = candidates.min(by: {
                abs($0.frame.width - item.frame.width) < abs($1.frame.width - item.frame.width)
            }) else { continue }

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
               !Self.isBlank(cg) {
                cache[item.id] = NSImage(cgImage: cg, size: window.frame.size)
            }
        }
    }

    private static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return true }
        let len = CFDataGetLength(data)
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 4 else { return false }
        var i = 3
        while i < len { if ptr[i] > 10 { return false }; i += bpp * 7 }
        return true
    }
}
