import AppKit
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns `false` when macOS rejected the change (e.g. the app is not in a
    /// signed bundle or the user disabled it in System Settings > Login Items).
    @discardableResult
    static func set(enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Para: launch at login change failed: \(error.localizedDescription)")
            return false
        }
    }
}
