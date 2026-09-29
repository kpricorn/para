import AppKit
import Carbon.HIToolbox

/// Click to record, then press any key combination. Escape cancels, Delete resets.
final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut = Settings.shortcut {
        didSet { refreshTitle() }
    }

    var onChange: ((Shortcut) -> Void)?
    var validate: ((Shortcut) -> Bool)?

    private var isRecording = false {
        didSet { refreshTitle() }
    }
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { removeMonitor() }

    private func refreshTitle() {
        title = isRecording ? "Press keys…" : shortcut.displayString
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        NSApp.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)

        if keyCode == UInt32(kVK_Escape) {
            stopRecording()
            return
        }
        if keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete) {
            stopRecording()
            apply(.default)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let candidate = Shortcut(keyCode: keyCode, carbonModifiers: Shortcut.carbonModifiers(from: flags))

        guard validate?(candidate) ?? true else {
            NSSound.beep()
            return
        }

        stopRecording()
        apply(candidate)
    }

    private func apply(_ newShortcut: Shortcut) {
        shortcut = newShortcut
        onChange?(newShortcut)
    }
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let hotKeys: HotKeyManager
    private let recorder = ShortcutRecorderButton()
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton()
    private let previewsToggle = NSButton()
    private let previewsPermissionLabel = NSTextField(labelWithString: "")
    private let previewsPermissionButton = NSButton()

    init(hotKeys: HotKeyManager) {
        self.hotKeys = hotKeys

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Para Settings"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        refreshPermissionState()
        recorder.shortcut = Settings.shortcut
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        recorder.shortcut = Settings.shortcut
        recorder.validate = { [weak self] candidate in
            guard let self else { return false }
            if candidate == Settings.shortcut { return true }
            return self.hotKeys.isAvailable(candidate)
        }
        recorder.onChange = { shortcut in
            Settings.shortcut = shortcut
        }

        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetShortcut))
        resetButton.bezelStyle = .rounded

        let shortcutRow = NSStackView(views: [
            label("Shortcut:", width: 110, alignment: .right),
            recorder,
            resetButton,
        ])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 8
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let hint = NSTextField(wrappingLabelWithString:
            "Hold the modifier and tap the key to cycle forward, add ⇧ to cycle backwards. "
            + "Release the modifier to switch. Arrow keys navigate, ⎋ cancels.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let launchToggle = NSButton(
            checkboxWithTitle: "Launch Para at login",
            target: self,
            action: #selector(toggleLaunchAtLogin)
        )
        launchToggle.state = LaunchAtLogin.isEnabled ? .on : .off

        let minimizedToggle = NSButton(
            checkboxWithTitle: "Include minimized and hidden windows",
            target: self,
            action: #selector(toggleMinimized)
        )
        minimizedToggle.state = Settings.includeMinimized ? .on : .off

        let spacesToggle = NSButton(
            checkboxWithTitle: "Include windows from other Spaces",
            target: self,
            action: #selector(toggleSpaces)
        )
        spacesToggle.state = Settings.includeOtherSpaces ? .on : .off

        previewsToggle.setButtonType(.switch)
        previewsToggle.title = "Show window previews"
        previewsToggle.target = self
        previewsToggle.action = #selector(togglePreviews)
        previewsToggle.state = Settings.showPreviews ? .on : .off
        previewsToggle.isEnabled = WindowPreviews.isSupported
        if !WindowPreviews.isSupported { previewsToggle.title += " (macOS 14 or later)" }

        previewsPermissionLabel.font = .systemFont(ofSize: 11)
        previewsPermissionLabel.stringValue = "⚠︎ Needs Screen Recording access (relaunch Para after granting)"
        previewsPermissionLabel.textColor = .systemOrange
        previewsPermissionButton.bezelStyle = .rounded
        previewsPermissionButton.controlSize = .small
        previewsPermissionButton.title = "Open Screen Recording Settings…"
        previewsPermissionButton.target = self
        previewsPermissionButton.action = #selector(openScreenRecording)

        let previewsPermissionRow = NSStackView(views: [previewsPermissionLabel, previewsPermissionButton])
        previewsPermissionRow.orientation = .horizontal
        previewsPermissionRow.spacing = 8
        previewsPermissionRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        permissionLabel.font = .systemFont(ofSize: 11)
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(openAccessibility)
        permissionButton.title = "Open Accessibility Settings…"

        let permissionRow = NSStackView(views: [permissionLabel, permissionButton])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8

        let stack = NSStackView(views: [
            shortcutRow,
            hint,
            separator(),
            launchToggle,
            minimizedToggle,
            spacesToggle,
            previewsToggle,
            previewsPermissionRow,
            separator(),
            permissionRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
        return container
    }

    private func label(_ text: String, width: CGFloat, alignment: NSTextAlignment) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = alignment
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return box
    }

    // MARK: - Actions

    @objc private func resetShortcut() {
        Settings.resetShortcut()
        recorder.shortcut = Settings.shortcut
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let enabled = sender.state == .on
        if !LaunchAtLogin.set(enabled: enabled) {
            sender.state = LaunchAtLogin.isEnabled ? .on : .off
            NSSound.beep()
        }
    }

    @objc private func toggleMinimized(_ sender: NSButton) {
        Settings.includeMinimized = sender.state == .on
    }

    @objc private func toggleSpaces(_ sender: NSButton) {
        Settings.includeOtherSpaces = sender.state == .on
    }

    @objc private func togglePreviews(_ sender: NSButton) {
        Settings.showPreviews = sender.state == .on
        if Settings.showPreviews, !WindowPreviews.hasPermission {
            WindowPreviews.requestPermission()
        }
        refreshPermissionState()
    }

    @objc private func openScreenRecording() {
        WindowPreviews.requestPermission()
        WindowPreviews.openSettings()
    }

    @objc private func openAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    func refreshPermissionState() {
        let trusted = Permissions.isAccessibilityTrusted
        permissionLabel.stringValue = trusted
            ? "✓ Accessibility access granted"
            : "⚠︎ Accessibility access is required to switch windows"
        permissionLabel.textColor = trusted ? .secondaryLabelColor : .systemOrange
        permissionButton.isHidden = trusted

        let needsScreenRecording = Settings.showPreviews && WindowPreviews.isSupported && !WindowPreviews.hasPermission
        previewsPermissionLabel.superview?.isHidden = !needsScreenRecording
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermissionState()
    }
}
