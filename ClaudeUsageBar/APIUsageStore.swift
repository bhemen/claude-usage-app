import Foundation
import Observation

/// Owns the polling loop for the API organization's usage & cost, holding the latest
/// snapshot for the UI.
///
/// The Admin API data refreshes roughly every 5 minutes, so we poll every 300 s on success
/// (well under the API's ~1 req/min guidance) and back off on errors. Everything is gated on
/// an Admin key being present; without one the store stays idle and the UI shows a
/// configuration prompt.
@MainActor
@Observable
final class APIUsageStore {
    private(set) var summary: APIUsageSummary?
    private(set) var lastUpdated: Date?
    private(set) var errorReason: String?
    private(set) var isRefreshing = false
    private(set) var isConfigured: Bool

    private let service = APIUsageService()
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    init() {
        isConfigured = AdminKeyStore.load() != nil
        if isConfigured { start() }
    }

    /// Saves a new Admin key and (re)starts polling from now.
    func setAdminKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard AdminKeyStore.save(trimmed) else {
            errorReason = "Couldn't save key to Keychain"
            return
        }
        summary = nil
        errorReason = nil
        consecutiveFailures = 0
        isConfigured = true
        start()
    }

    /// Removes the Admin key and stops polling; the API section returns to its prompt state.
    func clearAdminKey() {
        pollTask?.cancel()
        AdminKeyStore.clear()
        isConfigured = false
        summary = nil
        lastUpdated = nil
        errorReason = nil
        consecutiveFailures = 0
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
        guard let key = AdminKeyStore.load() else {
            isConfigured = false
            return 600
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            summary = try await service.fetch(adminKey: key)
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
