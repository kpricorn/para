import AppKit
import ScreenCaptureKit

/// Window thumbnails for the switcher, captured with ScreenCaptureKit.
/// Requires macOS 14 and the Screen Recording permission; tiles fall back to app icons otherwise.
enum WindowPreviews {
    static var isSupported: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user must use System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    static var isActive: Bool { Settings.showPreviews && isSupported && hasPermission }

    /// Last capture per window, so reopening the switcher shows previews instantly
    /// while fresh ones are captured. Only touched on the main thread.
    private static var cache: [CGWindowID: NSImage] = [:]

    static func cached(_ windowID: CGWindowID) -> NSImage? { cache[windowID] }

    /// Captures thumbnails for `windows`, calling `update` on the main thread per window.
    static func capture(
        _ windows: [WindowInfo],
        maxPointWidth: CGFloat,
        update: @escaping (CGWindowID, NSImage) -> Void
    ) {
        guard #available(macOS 14, *), isActive else { return }
        let wanted = Set(windows.map(\.windowID).filter { $0 != 0 })
        guard !wanted.isEmpty else { return }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2

        Task.detached(priority: .userInitiated) {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            ) else { return }

            await withTaskGroup(of: Void.self) { group in
                for window in content.windows where wanted.contains(window.windowID) {
                    group.addTask {
                        guard let image = await capture(window, maxPointWidth: maxPointWidth, scale: scale)
                        else { return }
                        let id = window.windowID
                        await MainActor.run {
                            cache[id] = image
                            update(id, image)
                        }
                    }
                }
            }
        }
    }

    @available(macOS 14, *)
    private static func capture(_ window: SCWindow, maxPointWidth: CGFloat, scale: CGFloat) async -> NSImage? {
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return nil }
        let fit = min(1, maxPointWidth / frame.width)
        let size = CGSize(width: frame.width * fit, height: frame.height * fit)

        let config = SCStreamConfiguration()
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}
