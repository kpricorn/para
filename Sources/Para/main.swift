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

// Docs helper: `Para --render-screenshot <out.png> [--previews]` renders the overlay
// with sample windows offscreen (no Screen Recording permission needed) for the README.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-screenshot"),
   CommandLine.arguments.indices.contains(flagIndex + 1) {
    let output = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let icon = NSImage(contentsOfFile: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns")
        ?? NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    var nextID: CGWindowID = 0
    func sample(_ title: String, minimized: Bool = false, onScreen: Bool = true) -> WindowInfo {
        nextID += 1
        return WindowInfo(element: nil, windowID: nextID, pid: 0, title: title, appName: "Finder",
                          icon: icon, isMinimized: minimized, isOnScreen: onScreen)
    }
    let items = [
        sample("Projekte"), sample("Downloads"), sample("Documents"),
        sample("Applications", onScreen: false), sample("Desktop", minimized: true),
    ]

    let view = SwitcherView()
    view.appearance = NSAppearance(named: .darkAqua)
    let previews = CommandLine.arguments.contains("--previews")
    let size = view.configure(items: items, maxSize: CGSize(width: 2000, height: 1000), previews: previews)
    if previews {
        for (index, item) in items.enumerated() {
            view.setPreview(MockWindow.render(title: item.title, seed: index), for: item.windowID)
        }
    }
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

/// Finder-like window artwork for `--render-screenshot --previews`.
enum MockWindow {
    private static let iconDir = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

    private static func icon(_ name: String) -> NSImage? {
        NSImage(contentsOfFile: iconDir + name + ".icns")
    }

    static func render(title: String, seed: Int) -> NSImage {
        let size = NSSize(width: 800, height: 500 + CGFloat(seed % 3) * 20)
        return NSImage(size: size, flipped: true) { rect in
            let window = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
            window.addClip()
            NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1).setFill()
            rect.fill()

            let sidebar = NSRect(x: 0, y: 0, width: 190, height: rect.height)
            NSColor(srgbRed: 0.21, green: 0.21, blue: 0.24, alpha: 1).setFill()
            sidebar.fill()

            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18 + CGFloat(i) * 22, y: 18, width: 13, height: 13)).fill()
            }

            let sidebarText: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.85, alpha: 1),
            ]
            for (i, name) in ["Recents", "Applications", "Desktop", "Documents", "Downloads"].enumerated() {
                let y = 64 + CGFloat(i) * 32
                if name == title {
                    NSColor(white: 1, alpha: 0.12).setFill()
                    NSBezierPath(roundedRect: NSRect(x: 10, y: y - 6, width: 170, height: 28), xRadius: 6, yRadius: 6).fill()
                }
                name.draw(at: NSPoint(x: 24, y: y), withAttributes: sidebarText)
            }

            title.draw(at: NSPoint(x: 214, y: 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .bold), .foregroundColor: NSColor.white,
            ])

            let names = ["Para", "Notes", "Invoices", "Photos", "Report.pdf", "Slides.key",
                         "Archive", "Budget.numbers", "Music", "Design", "todo.txt", "Travel"]
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.9, alpha: 1),
            ]
            let folder = icon("GenericFolderIcon")
            let document = icon("GenericDocumentIcon")
            let count = 5 + (seed * 3) % 8
            for i in 0..<count {
                let name = names[(i + seed * 2) % names.count]
                let column = CGFloat(i % 5), row = CGFloat(i / 5)
                let origin = NSPoint(x: 222 + column * 112, y: 70 + row * 130)
                let image = name.contains(".") ? document : folder
                image?.draw(in: NSRect(x: origin.x + 16, y: origin.y, width: 72, height: 72),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                let width = (name as NSString).size(withAttributes: labelAttributes).width
                name.draw(at: NSPoint(x: origin.x + 52 - width / 2, y: origin.y + 80), withAttributes: labelAttributes)
            }
            return true
        }
    }
}
