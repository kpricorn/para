import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotKeys = HotKeyManager()
    private lazy var switcher = SwitcherController(hotKeys: hotKeys)
    private let updater = Updater()
    private lazy var preferences = PreferencesWindowController(hotKeys: hotKeys, updater: updater)

    private var statusItem: NSStatusItem?
    private var shortcutMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        switcher.registerTriggers()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutChanged),
            name: .paraShortcutChanged,
            object: nil
        )

        if !Permissions.isAccessibilityTrusted {
            Permissions.requestAccessibility()
        }

        updater.onChange = { [weak self] in self?.refreshUpdateMenuItem() }
        updater.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.stack.3d.down.right",
            accessibilityDescription: "Para"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()

        let showItem = NSMenuItem(
            title: "Show Window Switcher",
            action: #selector(showSwitcher),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)

        let shortcutItem = NSMenuItem(title: shortcutTitle(), action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        shortcutMenuItem = shortcutItem

        let accessibilityItem = NSMenuItem(
            title: "Grant Accessibility Permission…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        accessibilityItem.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Permission missing"
        )
        menu.addItem(accessibilityItem)
        accessibilityMenuItem = accessibilityItem

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: "", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        updateMenuItem = updateItem
        refreshUpdateMenuItem()

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Para", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func shortcutTitle() -> String {
        "Shortcut: \(Settings.shortcut.displayString)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        accessibilityMenuItem?.isHidden = Permissions.isAccessibilityTrusted
        refreshUpdateMenuItem()
    }

    private func refreshUpdateMenuItem() {
        guard let item = updateMenuItem else { return }
        switch updater.state {
        case .checking:
            item.title = "Checking for Updates…"
            item.isEnabled = false
        case .installing:
            item.title = "Installing Update…"
            item.isEnabled = false
        case .idle:
            if let release = updater.availableRelease {
                item.title = "Install Para \(release.version)…"
            } else {
                item.title = "Check for Updates…"
            }
            item.isEnabled = true
        }
        item.image = updater.availableRelease == nil ? nil : NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: "Update available"
        )
    }

    // MARK: - Actions

    @objc private func openAccessibilitySettings() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func showSwitcher() {
        switcher.showFromMenu()
    }

    @objc private func showPreferences() {
        preferences.present()
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func shortcutChanged() {
        switcher.registerTriggers()
        shortcutMenuItem?.title = shortcutTitle()
    }
}
