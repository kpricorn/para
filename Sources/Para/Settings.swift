import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut expressed with Carbon key/modifier codes.
struct Shortcut: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    var carbonModifiers: UInt32

    static let `default` = Shortcut(
        keyCode: UInt32(kVK_ISO_Section),
        carbonModifiers: UInt32(cmdKey)
    )

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    var displayString: String {
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + KeyCodeNames.name(for: keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}

extension Notification.Name {
    static let paraShortcutChanged = Notification.Name("app.para.shortcutChanged")
}

enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let keyCode = "shortcut.keyCode"
        static let modifiers = "shortcut.modifiers"
        static let includeMinimized = "windows.includeMinimized"
        static let includeOtherSpaces = "windows.includeOtherSpaces"
        static let showPreviews = "windows.showPreviews"
    }

    static var shortcut: Shortcut {
        get {
            guard defaults.object(forKey: Key.keyCode) != nil else { return .default }
            return Shortcut(
                keyCode: UInt32(defaults.integer(forKey: Key.keyCode)),
                carbonModifiers: UInt32(defaults.integer(forKey: Key.modifiers))
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.keyCode)
            defaults.set(Int(newValue.carbonModifiers), forKey: Key.modifiers)
            NotificationCenter.default.post(name: .paraShortcutChanged, object: nil)
        }
    }

    static var includeMinimized: Bool {
        get { defaults.object(forKey: Key.includeMinimized) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.includeMinimized) }
    }

    static var includeOtherSpaces: Bool {
        get { defaults.object(forKey: Key.includeOtherSpaces) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.includeOtherSpaces) }
    }

    /// Show window thumbnails instead of just app icons (needs Screen Recording).
    static var showPreviews: Bool {
        get { defaults.bool(forKey: Key.showPreviews) }
        set { defaults.set(newValue, forKey: Key.showPreviews) }
    }

    static func resetShortcut() {
        defaults.removeObject(forKey: Key.keyCode)
        defaults.removeObject(forKey: Key.modifiers)
        NotificationCenter.default.post(name: .paraShortcutChanged, object: nil)
    }
}
