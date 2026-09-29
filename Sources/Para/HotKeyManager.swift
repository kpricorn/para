import Carbon.HIToolbox
import Foundation

/// Registers system-wide hot keys through Carbon's `RegisterEventHotKey`, which
/// works without Accessibility permission and fires regardless of the front app.
final class HotKeyManager {
    typealias Handler = () -> Void

    private struct Registration {
        let ref: EventHotKeyRef
        let handler: Handler
    }

    private static let signature: OSType = 0x50_41_52_41 // 'PARA'

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        installEventHandler()
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    // MARK: - Registration

    /// Registers a hot key. Returns an opaque id that can be passed to `unregister(_:)`,
    /// or `nil` when the combination is already claimed by another application.
    @discardableResult
    func register(_ shortcut: Shortcut, handler: @escaping Handler) -> UInt32? {
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else { return nil }
        registrations[id] = Registration(ref: ref, handler: handler)
        return id
    }

    func unregister(_ id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.ref)
    }

    func unregister(_ ids: [UInt32]) {
        ids.forEach(unregister)
    }

    func unregisterAll() {
        registrations.keys.forEach(unregister)
    }

    /// True when the shortcut can be registered (i.e. nothing else owns it).
    func isAvailable(_ shortcut: Shortcut) -> Bool {
        var ref: EventHotKeyRef?
        let probeID = EventHotKeyID(signature: Self.signature, id: UInt32.max)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            probeID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        UnregisterEventHotKey(ref)
        return true
    }

    // MARK: - Dispatch

    fileprivate func handle(id: UInt32) {
        registrations[id]?.handler()
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}

private let hotKeyEventCallback: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return noErr }

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handle(id: hotKeyID.id)
    return noErr
}
