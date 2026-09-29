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

// Docs helper: `Para --render-screenshot <out.png>` renders the overlay with sample
// windows offscreen (no Screen Recording permission needed) for the README.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-screenshot"),
   CommandLine.arguments.indices.contains(flagIndex + 1) {
    let output = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let icon = NSImage(contentsOfFile: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns")
        ?? NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    func sample(_ title: String, minimized: Bool = false, onScreen: Bool = true) -> WindowInfo {
        WindowInfo(element: nil, windowID: 0, pid: 0, title: title, appName: "Finder",
                   icon: icon, isMinimized: minimized, isOnScreen: onScreen)
    }
    let items = [
        sample("Projekte"), sample("Downloads"), sample("Documents"),
        sample("Applications", onScreen: false), sample("Desktop", minimized: true),
    ]

    let view = SwitcherView()
    view.appearance = NSAppearance(named: .darkAqua)
    let size = view.configure(items: items, maxSize: CGSize(width: 2000, height: 1000))
    view.selectedIndex = 1
    view.layoutSubtreeIfNeeded()
    let host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                        backing: .buffered, defer: false)
    host.backgroundColor = .clear
    host.isOpaque = false
    host.appearance = NSAppearance(named: .darkAqua)
    host.contentView = view
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: rep)

    let scale: CGFloat = 2
    let canvas = CGSize(width: size.width + 160, height: size.height + 120)
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    image.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.75, alpha: 1),
        NSColor(calibratedRed: 0.52, green: 0.28, blue: 0.70, alpha: 1),
    ])!.draw(in: NSRect(origin: .zero, size: canvas), angle: -35)

    let card = NSRect(x: 80, y: 60, width: size.width, height: size.height)
    let path = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.set()
    NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.9).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
    path.lineWidth = 1
    path.stroke()
    rep.draw(in: card, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()

    do {
        try image.representation(using: .png, properties: [:])!.write(to: output)
        print("wrote \(output.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
