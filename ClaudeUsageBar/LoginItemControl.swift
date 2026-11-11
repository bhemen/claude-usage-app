import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` login-item registration and provides a headless entry point
/// so the login item can be enabled/disabled from a script (`--register-login-item` /
/// `--unregister-login-item`) without clicking the in-app toggle. Registration always
/// targets the *running* bundle, so these flags must be run from the installed copy
/// (e.g. `/Applications/ClaudeUsageBar.app`).
enum LoginItemControl {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registered, but not allowed to run at login: either the user hasn't approved it yet,
    /// or switched it off in System Settings.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Opens the Login Items pane (named "Login Items & Extensions" on macOS 15+).
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Registers or unregisters as needed. Idempotent. Throws the underlying error.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            // Also unregister a pending/blocked item, so unticking clears it completely.
            let status = SMAppService.mainApp.status
            if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    /// Inspects launch arguments; if a login-item flag is present, applies it, prints the
    /// resulting status, and exits the process. Otherwise returns and normal launch proceeds.
    static func handleLaunchFlagsIfNeeded() {
        let args = CommandLine.arguments
        let register = args.contains("--register-login-item")
        let unregister = args.contains("--unregister-login-item")
        guard register || unregister else { return }

        do {
            try setEnabled(register)
            FileHandle.standardOutput.write(Data(
                "login-item \(register ? "registered" : "unregistered"); status=\(SMAppService.mainApp.status.rawValue) enabled=\(isEnabled)\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(
                "login-item change failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
