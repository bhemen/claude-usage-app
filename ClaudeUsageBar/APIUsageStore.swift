import Foundation
import Observation

/// Owns the polling loop for the API organization's usage & cost, holding the latest
/// snapshot for the UI.
///
/// The Admin API data refreshes roughly every 5 minutes, so we poll every 300 s on success
/// (well under the API's ~1 req/min guidance) and back off on errors. Everything is gated on
/// an Admin key being present; without one the store stays idle and the UI shows a
/// configuration prompt.
///
/// The key is read from the Keychain once at launch and then held in memory. The app owns the
/// key, so `setAdminKey` / `clearAdminKey` are the only ways it changes, and caching avoids
/// spawning `/usr/bin/security` on the main actor every poll. Trade-off: deleting the item in
/// Keychain Access isn't noticed until relaunch — revoke a leaked key in the Console instead,
/// after which polls report "Admin key rejected".
@MainActor
@Observable
final class APIUsageStore {
    private(set) var summary: APIUsageSummary?
    private(set) var lastUpdated: Date?
    private(set) var errorReason: String?
    private(set) var isRefreshing = false
    private(set) var isConfigured: Bool

    /// The cached Admin key. Not observable state: nothing in the UI should read or track it.
    @ObservationIgnored private var adminKey: String?
    private let service = APIUsageService()
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    init() {
        // One synchronous Keychain read (~15 ms) at launch; polls use the cached copy.
        adminKey = AdminKeyStore.load()
        isConfigured = adminKey != nil
        if isConfigured { start() }
    }

    /// Saves a new Admin key and (re)starts polling from now. Returns `false` if the Keychain
    /// write failed; nothing changes then (an existing key keeps being used), and the caller
    /// reports the failure — not `errorReason`, which the next successful poll would clear.
    @discardableResult
    func setAdminKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard AdminKeyStore.save(trimmed) else { return false }
        adminKey = trimmed
        summary = nil
        errorReason = nil
        consecutiveFailures = 0
        isConfigured = true
        start()
        return true
    }

    /// Removes the Admin key and stops polling; the API section returns to its prompt state.
    /// Returns `false`, changing nothing, if the key is still in the Keychain afterwards —
    /// otherwise the section would look cleared but the key would come back at next launch.
    @discardableResult
    func clearAdminKey() -> Bool {
        // `clear()` also reports false when there was no item; only a surviving key is a failure.
        if !AdminKeyStore.clear() && AdminKeyStore.load() != nil { return false }
        pollTask?.cancel()
        adminKey = nil
        isConfigured = false
        isRefreshing = false  // the cancelled poll leaves this alone; see `refresh()`
        summary = nil
        lastUpdated = nil
        errorReason = nil
        consecutiveFailures = 0
        return true
    }

    /// User-initiated refresh: resets backoff and restarts the cadence from now.
    func manualRefresh() {
        guard isConfigured else { return }
        consecutiveFailures = 0
        start()
    }

    private func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            // Never sleep less than 30 s as a backstop against a spinning loop.
            let delay = max(await refresh(), 30)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    @discardableResult
    private func refresh() async -> Double {
        guard let key = adminKey else {
            isConfigured = false
            return 600
        }
        isRefreshing = true
        // A superseded poll must not clear the spinner of the poll that replaced it.
        defer { if !Task.isCancelled { isRefreshing = false } }

        let result: Result<APIUsageSummary, Error>
        do {
            result = .success(try await service.fetch(adminKey: key))
        } catch {
            result = .failure(error)
        }
        // A key change, key removal, or manual refresh cancelled this poll mid-request. Its
        // result is either a cancellation (not "Offline") or data for a key that's no longer
        // current, and any replacement poll owns the state — so touch nothing.
        guard !Task.isCancelled else { return 0 }

        do {
            summary = try result.get()
            lastUpdated = Date()
            errorReason = nil
            consecutiveFailures = 0
            return 300
        } catch let error as APIUsageError {
            consecutiveFailures += 1
            errorReason = error.userMessage
            switch error {
            case .rateLimited(let retryAfter):
                let base = max(retryAfter ?? 120, 60)
                return min(base * pow(2, Double(consecutiveFailures - 1)), 900)
            case .unauthorized:
                // A bad key won't fix itself; check back infrequently.
                return 900
            default:
                return min(60 * pow(2, Double(consecutiveFailures - 1)), 600)
            }
        } catch {
            consecutiveFailures += 1
            errorReason = error.localizedDescription
            return min(60 * pow(2, Double(consecutiveFailures - 1)), 600)
        }
    }
}
