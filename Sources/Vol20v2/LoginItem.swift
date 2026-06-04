//
// LoginItem.swift — register Vol20v2 as a macOS login item.
//
// Apple's `SMAppService.mainApp` API (macOS 13+) replaces the old
// LSSharedFileList / launchd-plist dances. One call to `register()`
// and macOS launches our app at every login; `unregister()` undoes it.
// The OS is the source of truth — there's no UserDefaults bookkeeping
// to keep in sync. We just read `.status` to render the toggle.
//
// Three states matter:
//   .enabled        → app launches at login (user-toggled on)
//   .notRegistered  → not in the login-item list
//   .requiresApproval → user must approve in System Settings > Login Items
//   .notFound       → SMAppService can't locate our bundle (rare)
//
// Notes specific to our setup:
//   - The app lives at .../vol20-v2/Vol20v2.app. As long as the user
//     doesn't move the bundle, the registration stays valid across
//     rebuilds (the binary hash changes; the bundle path doesn't).
//   - If the user moves Vol20v2.app, they must re-toggle.
//   - macOS sometimes requires user approval the first time. We surface
//     this via `lastError` so the user sees what's happening.
//

import Foundation
import ServiceManagement
import os

@MainActor
final class LoginItem: ObservableObject {

    private static let logger = Logger(subsystem: "com.tlmattson.vol20v2",
                                       category: "LoginItem")

    /// True if macOS will launch Vol20v2 at login. Reads from the OS at
    /// init and after each set(); the UI binds to this.
    @Published private(set) var isEnabled: Bool = false

    /// Most recent error message from register / unregister, suitable for
    /// surfacing in the menu. nil when everything's healthy.
    @Published private(set) var lastError: String?

    /// Last raw status SMAppService reported — useful for diagnostics
    /// (e.g. "requires approval").
    @Published private(set) var rawStatusDescription: String = "?"

    init() {
        refresh()
    }

    /// Flip auto-launch on or off. Updates published state to match
    /// whatever the OS reports afterward — including failures.
    func set(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
                Self.logger.notice("SMAppService.register OK")
            } else {
                try SMAppService.mainApp.unregister()
                Self.logger.notice("SMAppService.unregister OK")
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("SMAppService set(\(value, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Re-read the OS state and update published properties.
    func refresh() {
        let s = SMAppService.mainApp.status
        isEnabled = (s == .enabled)
        rawStatusDescription = describe(s)
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    return "not registered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requires user approval in System Settings"
        case .notFound:         return "not found (bundle moved?)"
        @unknown default:       return "unknown (\(status.rawValue))"
        }
    }
}
