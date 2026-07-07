import Foundation

/// Stores the Anthropic **Admin API key** (`sk-ant-admin01-…`) used to read the
/// organization's API usage & cost reports.
///
/// Unlike the Max-plan OAuth token — which Claude Code owns and we only read — this key is
/// entered by the user, so the app owns it. We keep it in the login Keychain via the
/// `security` CLI, mirroring `KeychainReader`: the CLI reads and writes the item without a
/// GUI prompt, which the in-process Security-framework API can't guarantee for an
/// ad-hoc-signed app. The key never leaves the machine except as the `x-api-key` header on
/// requests to `api.anthropic.com`, and is never logged.
///
/// Note: `save` passes the key as a `security` argument, so it is briefly visible to `ps`
/// for other processes running as the same user. That's an acceptable trade for a personal,
/// single-user app; a shared machine would want a different mechanism.
enum AdminKeyStore {
    private static let service = "ClaudeUsageBar-admin-key"
    private static let account = "admin"

    /// Returns the stored Admin key, or `nil` if none has been saved.
    static func load() -> String? {
        let output = run(["find-generic-password", "-a", account, "-s", service, "-w"])
        guard let output else { return nil }
        let key = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Saves (or replaces) the Admin key. Returns whether the write succeeded.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // -U updates the item in place if it already exists instead of erroring.
        return run(["add-generic-password", "-U", "-a", account, "-s", service, "-w", trimmed]) != nil
    }

    /// Removes the stored Admin key. Returns whether an item was deleted.
    @discardableResult
    static func clear() -> Bool {
        run(["delete-generic-password", "-a", account, "-s", service]) != nil
    }

    /// Runs `/usr/bin/security` with the given arguments. Returns stdout on exit code 0,
    /// or `nil` on any failure (item absent, spawn error, non-zero exit).
    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
