import Foundation
import Security

/// Reads the Claude Code OAuth access token that already lives on this machine.
///
/// Claude Code stores its credentials as a generic-password Keychain item under the
/// service `Claude Code-credentials`; the password value is a JSON blob whose
/// `claudeAiOauth.accessToken` field is the bearer token we need. Claude Code keeps that
/// token refreshed, so we simply re-read it on every poll rather than implementing our own
/// OAuth refresh (which would rotate the refresh token and log Claude Code out).
///
/// The primary read path shells out to the `security` CLI, which reads the item *without* a
/// keychain prompt (see `accessToken()` for why the in-process API isn't tried first).
enum KeychainReader {
    private static let service = "Claude Code-credentials"

    struct Credentials: Decodable {
        struct OAuth: Decodable { let accessToken: String? }
        let claudeAiOauth: OAuth?
    }

    /// Returns the current access token, or `nil` if it can't be found.
    ///
    /// Order matters. We try the `security` CLI *first* because it reads the item without
    /// showing a keychain prompt, whereas the in-process Security-framework API
    /// (`SecItemCopyMatching`) prompts on every launch for an app that isn't signed with a
    /// stable Developer ID — and for such an app macOS greys out "Always Allow", so the
    /// prompt can never be silenced. The direct API is kept as a secondary path: if this
    /// app is ever signed with a stable identity and granted access, it works too, and it's
    /// a backstop if the CLI is unavailable — but only when the CLI *read* fails, never when
    /// it read the item and the contents didn't decode. The credentials file is a last resort.
    static func accessToken() -> String? {
        if let data = readViaSecurityCLI() {
            if let token = decodeToken(from: data) { return token }
            // The CLI found the item but it holds no OAuth token. Don't fall through to
            // `SecItemCopyMatching`: it would read the same item but show a keychain prompt,
            // and the store retries every couple of minutes — a prompt loop.
        } else if let data = readKeychainData(), let token = decodeToken(from: data) {
            return token
        }
        if let data = readCredentialsFile(), let token = decodeToken(from: data) {
            return token
        }
        return nil
    }

    // MARK: - Sources

    private static func readKeychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func readViaSecurityCLI() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // The CLI appends a trailing newline; trim it before JSON decoding.
        return data.isEmpty ? nil : data
    }

    private static func readCredentialsFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    // MARK: - Decode

    private static func decodeToken(from data: Data) -> String? {
        let trimmed = trimmedJSON(data)
        if let creds = try? JSONDecoder().decode(Credentials.self, from: trimmed),
           let token = creds.claudeAiOauth?.accessToken, !token.isEmpty {
            return token
        }
        return nil
    }

    /// The `security` CLI can append whitespace/newlines around the JSON payload.
    private static func trimmedJSON(_ data: Data) -> Data {
        guard let string = String(data: data, encoding: .utf8) else { return data }
        return Data(string.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}
