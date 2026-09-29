import AppKit
import ApplicationServices

/// Private AX SPI used to correlate an `AXUIElement` window with its CoreGraphics
/// window id. This is the same approach AltTab uses; there is no public equivalent.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowInfo {
    /// `nil` when the window was discovered through CoreGraphics only, i.e. before
    /// Accessibility permission has been granted.
    let element: AXUIElement?
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let icon: NSImage?
    let isMinimized: Bool
    let isOnScreen: Bool

    var displayTitle: String { title.isEmpty ? appName : title }
}

enum WindowLister {
    /// Switchable windows of `app` (default: the frontmost app), ordered front-to-back
    /// like the window server sees them. Minimized / hidden windows are appended at the end.
    static func list(for app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> [WindowInfo] {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return [] }
        let zOrder = onScreenZOrder()
        let accessibility = accessibilityWindows(of: app, zOrder: zOrder)
        return accessibility.isEmpty ? coreGraphicsWindows(of: app, zOrder: zOrder) : accessibility
    }

    /// Brings a window to the front, un-minimizing and un-hiding as needed.
    static func focus(_ window: WindowInfo) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }

        if let element = window.element {
            if boolValue(element, kAXMinimizedAttribute) {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)

            let axApp = AXUIElementCreateApplication(window.pid)
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }

        app?.activate()
    }

    // MARK: - Accessibility source (authoritative)

    private static func accessibilityWindows(of app: NSRunningApplication, zOrder: [CGWindowID: Int]) -> [WindowInfo] {
        guard AXIsProcessTrusted() else { return [] }

        var onScreen: [(index: Int, window: WindowInfo)] = []
        var offScreen: [WindowInfo] = []
        var seen = Set<CGWindowID>()

        do {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.5)

            for element in windows(of: axApp) {
                // When Accessibility is not truly granted the system echoes the
                // application element back instead of real windows.
                guard !CFEqual(element, axApp), isSwitchable(element) else { continue }

                var windowID: CGWindowID = 0
                guard _AXUIElementGetWindow(element, &windowID) == .success,
                      windowID != 0,
                      seen.insert(windowID).inserted
                else { continue }

                let minimized = boolValue(element, kAXMinimizedAttribute) || app.isHidden
                let visibleIndex = zOrder[windowID]

                if minimized, !Settings.includeMinimized { continue }
                if visibleIndex == nil, !minimized, !Settings.includeOtherSpaces { continue }

                let info = WindowInfo(
                    element: element,
                    windowID: windowID,
                    pid: app.processIdentifier,
                    title: stringValue(element, kAXTitleAttribute) ?? "",
                    appName: app.localizedName ?? "Unknown",
                    icon: app.icon,
                    isMinimized: minimized,
                    isOnScreen: visibleIndex != nil
                )

                if let visibleIndex {
                    onScreen.append((visibleIndex, info))
                } else {
                    offScreen.append(info)
                }
            }
        }

        onScreen.sort { $0.index < $1.index }
        return onScreen.map(\.window) + offScreen
    }

    // MARK: - CoreGraphics fallback (no permission required)

    /// Used until Accessibility is granted. Titles are only available with Screen
    /// Recording permission, so we fall back to the application name.
    private static func coreGraphicsWindows(of app: NSRunningApplication, zOrder: [CGWindowID: Int]) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let targetPID = app.processIdentifier
        var result: [WindowInfo] = []
        var seen = Set<CGWindowID>()

        for entry in raw {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == targetPID,
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  seen.insert(windowID).inserted
            else { continue }

            let bounds = (entry[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            guard bounds.width >= 120, bounds.height >= 80 else { continue }

            result.append(WindowInfo(
                element: nil,
                windowID: windowID,
                pid: pid,
                title: entry[kCGWindowName as String] as? String ?? "",
                appName: app.localizedName ?? "Unknown",
                icon: app.icon,
                isMinimized: false,
                isOnScreen: true
            ))
        }

        return result.sorted { (zOrder[$0.windowID] ?? .max) < (zOrder[$1.windowID] ?? .max) }
    }

    // MARK: - Helpers

    private static func onScreenZOrder() -> [CGWindowID: Int] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var order: [CGWindowID: Int] = [:]
        var index = 0
        for entry in raw {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            order[id] = index
            index += 1
        }
        return order
    }

    private static func windows(of axApp: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func isSwitchable(_ element: AXUIElement) -> Bool {
        guard let role = stringValue(element, kAXRoleAttribute), role == kAXWindowRole else { return false }
        let subrole = stringValue(element, kAXSubroleAttribute)
        // Standard windows only — skip palettes, sheets, popovers and system dialogs.
        return subrole == nil || subrole == kAXStandardWindowSubrole
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

enum Permissions {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility(prompt: Bool = true) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
