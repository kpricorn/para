import AppKit
import Carbon.HIToolbox

/// Owns the switcher lifecycle: hot key triggers, selection cycling, the overlay
/// panel and the "release the modifier to commit" behaviour.
final class SwitcherController {
    private let hotKeys: HotKeyManager

    private let panel = SwitcherPanel()
    private let contentView = SwitcherView()
    private let backdrop = NSVisualEffectView()

    private var windows: [WindowInfo] = []
    private var selection = 0
    private var isVisible = false
    /// True when the trigger has no held modifier, so the panel stays up until
    /// the user explicitly confirms or cancels.
    private var isSticky = false

    private var triggerHotKeyIDs: [UInt32] = []
    private var navigationHotKeyIDs: [UInt32] = []
    private var modifierWatcher: Timer?
    private var isShowingPermissionAlert = false

    /// Used by `Para --self-test` to verify the overlay renders headlessly.
    var debugState: (visible: Bool, count: Int, frame: NSRect) {
        (isVisible, windows.count, panel.frame)
    }

    init(hotKeys: HotKeyManager) {
        self.hotKeys = hotKeys
        setupPanel()
        trackTargetApp()
    }

    // MARK: - Target app

    /// The app whose windows are switched: the most recently active app other than Para,
    /// so the switcher still works while Para's own Settings window is focused.
    private var targetApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    private func trackTargetApp() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            targetApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID
            else { return }
            self?.targetApp = app
        }
    }

    private func currentTargetApp() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            return front
        }
        if let targetApp, !targetApp.isTerminated { return targetApp }
        return nil
    }

    // MARK: - Setup

    private func setupPanel() {
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.masksToBounds = true
        backdrop.autoresizingMask = [.width, .height]

        contentView.autoresizingMask = [.width, .height]
        contentView.onHover = { [weak self] index in self?.select(index) }
        contentView.onClick = { [weak self] index in
            self?.select(index)
            self?.confirm()
        }

        backdrop.addSubview(contentView)
        panel.contentView = backdrop
    }

    // MARK: - Hot keys

    func registerTriggers() {
        hotKeys.unregister(triggerHotKeyIDs)
        triggerHotKeyIDs.removeAll()

        let shortcut = Settings.shortcut
        let reverse = Shortcut(
            keyCode: shortcut.keyCode,
            carbonModifiers: shortcut.carbonModifiers ^ UInt32(shiftKey)
        )

        if let id = hotKeys.register(shortcut, handler: { [weak self] in self?.trigger(reverse: false) }) {
            triggerHotKeyIDs.append(id)
        }
        if let id = hotKeys.register(reverse, handler: { [weak self] in self?.trigger(reverse: true) }) {
            triggerHotKeyIDs.append(id)
        }
    }

    private func registerNavigationHotKeys() {
        let modifiers = Settings.shortcut.carbonModifiers & ~UInt32(shiftKey)
        let keys: [(Int, () -> Void)] = [
            (kVK_Escape, { [weak self] in self?.cancel() }),
            (kVK_Return, { [weak self] in self?.confirm() }),
            (kVK_ANSI_KeypadEnter, { [weak self] in self?.confirm() }),
            (kVK_RightArrow, { [weak self] in self?.move(by: 1) }),
            (kVK_LeftArrow, { [weak self] in self?.move(by: -1) }),
            (kVK_DownArrow, { [weak self] in self?.move(by: 1) }),
            (kVK_UpArrow, { [weak self] in self?.move(by: -1) }),
        ]

        // Register with and without the held modifiers so navigation works in both
        // hold-to-preview and sticky mode.
        for (keyCode, handler) in keys {
            for mask in Set([modifiers, 0]) {
                let shortcut = Shortcut(keyCode: UInt32(keyCode), carbonModifiers: mask)
                if let id = hotKeys.register(shortcut, handler: handler) {
                    navigationHotKeyIDs.append(id)
                }
            }
        }
    }

    private func unregisterNavigationHotKeys() {
        hotKeys.unregister(navigationHotKeyIDs)
        navigationHotKeyIDs.removeAll()
    }

    // MARK: - Triggering

    func trigger(reverse: Bool) {
        if isVisible {
            move(by: reverse ? -1 : 1)
        } else {
            show(reverse: reverse)
        }
    }

    func showFromMenu() {
        guard !isVisible else { return }
        show(reverse: false, forceSticky: true)
    }

    private func show(reverse: Bool, forceSticky: Bool = false) {
        // Titles and raising individual windows are only possible through Accessibility;
        // without it the overlay could only show identical tiles that don't switch.
        guard Permissions.isAccessibilityTrusted else {
            presentAccessibilityAlert()
            return
        }

        windows = WindowLister.list(for: currentTargetApp())
        guard !windows.isEmpty else {
            NSSound.beep()
            return
        }

        let heldModifiers = Settings.shortcut.cocoaModifiers.subtracting(.shift)
        let currentFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        isSticky = forceSticky || heldModifiers.isEmpty || !currentFlags.contains(heldModifiers)

        selection = windows.count > 1 ? (reverse ? windows.count - 1 : 1) : 0

        let screen = currentScreen()
        let maxSize = CGSize(
            width: screen.visibleFrame.width * 0.92,
            height: screen.visibleFrame.height * 0.86
        )
        let size = contentView.configure(items: windows, maxSize: maxSize)
        contentView.selectedIndex = selection

        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        isVisible = true
        registerNavigationHotKeys()
        if !isSticky { startModifierWatcher(requiring: heldModifiers) }
    }

    private func move(by offset: Int) {
        guard isVisible, !windows.isEmpty else { return }
        let count = windows.count
        select(((selection + offset) % count + count) % count)
    }

    private func select(_ index: Int) {
        guard isVisible, windows.indices.contains(index), index != selection else { return }
        selection = index
        contentView.selectedIndex = index
    }

    private func confirm() {
        guard isVisible else { return }
        let target = windows.indices.contains(selection) ? windows[selection] : nil
        hide()
        if let target { WindowLister.focus(target) }
    }

    private func cancel() {
        guard isVisible else { return }
        hide()
    }

    private func hide() {
        isVisible = false
        isSticky = false
        stopModifierWatcher()
        unregisterNavigationHotKeys()
        panel.orderOut(nil)
        windows = []
    }

    // MARK: - Modifier release

    private func startModifierWatcher(requiring modifiers: NSEvent.ModifierFlags) {
        stopModifierWatcher()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(modifiers) { self.confirm() }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierWatcher = timer
    }

    private func stopModifierWatcher() {
        modifierWatcher?.invalidate()
        modifierWatcher = nil
    }

    // MARK: - Helpers

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func presentAccessibilityAlert() {
        guard !isShowingPermissionAlert else { return }
        isShowingPermissionAlert = true
        defer { isShowingPermissionAlert = false }

        let alert = NSAlert()
        alert.messageText = "Para needs Accessibility permission"
        alert.informativeText = """
            To list and switch between an app's windows, enable Para in \
            System Settings → Privacy & Security → Accessibility.

            If Para is already listed there, remove it with “−” and add it again — \
            macOS keeps the old entry after the app is rebuilt.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        }
    }
}
