import Foundation
import ServiceManagement

/// The `Launch at Login` toggle's backing store (SPEC §2, §5). The login-item
/// registration itself is the persistence — the OS carries it across reboots,
/// which is what "survives reboot" means — so there is deliberately no
/// `config.json` key and no UserDefaults mirror to keep in sync. Behind a
/// protocol so tests can fake the registration database.
public protocol LaunchAtLogin: Sendable {
    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool { get }
    /// Registers (`true`) or unregisters (`false`) the app as a login item.
    /// Throws when the registration can't be changed; the caller re-reads
    /// `isEnabled` afterwards so the toggle always shows the true state.
    func setEnabled(_ enabled: Bool) throws
}

/// `LaunchAtLogin` over `SMAppService.mainApp` (macOS 13+): registers this
/// app's own bundle as a login item. Registering requires a real `.app`
/// bundle — a bare `swift run` binary has nothing `SMAppService` can point
/// at — so both calls report that plainly instead of surfacing
/// ServiceManagement's raw error.
public struct SMAppServiceLaunchAtLogin: LaunchAtLogin {
    public enum Failure: LocalizedError {
        /// The binary wasn't launched from a `.app` bundle, so there is
        /// nothing to register as a login item.
        case notBundled
        /// `SMAppService.register()`/`.unregister()` threw.
        case registrationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notBundled:
                "Launch at Login needs the packaged Mikey.app — build it with Scripts/package-app.sh."
            case .registrationFailed(let detail):
                "Couldn't update Launch at Login: \(detail)"
            }
        }
    }

    public init() {}

    public var isEnabled: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        // `.requiresApproval` means the registration exists and is only
        // waiting on the System Settings nod — the user already opted in,
        // so the toggle reads on.
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard Bundle.main.bundleIdentifier != nil else {
            throw Failure.notBundled
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                // `unregister()` throws on a not-registered item; turning an
                // already-off toggle off should just stay off.
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw Failure.registrationFailed(error.localizedDescription)
        }
    }
}
