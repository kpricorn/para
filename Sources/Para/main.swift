import AppKit

// Debug helper: `Para --list-windows [App Name]` prints what the switcher would show
// for the given app (default: the frontmost app) and exits.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--list-windows") {
    Permissions.requestAccessibility()
    let arguments = CommandLine.arguments
    let target: NSRunningApplication?
    if arguments.indices.contains(flagIndex + 1) {
        let name = arguments[flagIndex + 1]
        target = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }
        if target == nil {
            FileHandle.standardError.write(Data("No running app named \"\(name)\".\n".utf8))
            exit(1)
        }
    } else {
        target = NSWorkspace.shared.frontmostApplication
    }
    let windows = WindowLister.list(for: target)
    let source = windows.contains(where: { $0.element != nil }) ? "Accessibility" : "CoreGraphics fallback"
    print("accessibility trusted: \(Permissions.isAccessibilityTrusted)")
    print("\(windows.count) window(s) of \(target?.localizedName ?? "?") via \(source):")
    for (index, window) in windows.enumerated() {
        let state = window.isMinimized ? "minimized/hidden" : (window.isOnScreen ? "onscreen" : "other space")
        print(String(format: "%3d. [%@] %@ — %@", index, state, window.appName, window.displayTitle))
    }
    exit(0)
}

// Debug helper: `Para --self-test` renders the overlay headlessly and reports state.
if CommandLine.arguments.contains("--self-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let hotKeys = HotKeyManager()
    let shortcut = Settings.shortcut
    print("shortcut: \(shortcut.displayString) available: \(hotKeys.isAvailable(shortcut))")

    let controller = SwitcherController(hotKeys: hotKeys)
    controller.registerTriggers()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        controller.showFromMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let state = controller.debugState
            print("overlay visible: \(state.visible) items: \(state.count)")
            print("overlay frame: \(NSStringFromRect(state.frame))")
            exit(state.visible && state.count > 0 ? 0 : 1)
        }
    }
    app.run()
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
