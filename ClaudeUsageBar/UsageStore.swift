import Foundation
import Observation
import ServiceManagement

/// Owns the polling loop and holds the latest snapshot for the UI.
///
/// Polling cadence: 60 s on success. On failure we back off so we never hammer the
/// rate-limited endpoint — 429 backs off aggressively (90 s, doubling, capped at 600 s),
/// other transport/server errors back off gently (20 s, doubling, capped at 300 s). The
/// last good snapshot is retained across failures so the UI shows stale-but-useful data
/// with an error note rather than going blank.
@MainActor
@Observable
final class UsageStore {
    private(set) var snapshot: UsageResponse?
    private(set) var lastUpdated: Date?
    private(set) var errorReason: String?
    private(set) var isRefreshing = false

    /// Bound to the "Launch at login" toggle. `didSet` is not invoked for the initial
    /// value set in `init`, so reading the current status there is safe.
    var launchAtLogin: Bool {
        didSet { updateLoginItem(launchAtLogin) }
    }

    private let service = UsageService()
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    init() {
        launchAtLogin = LoginItemControl.isEnabled
        start()
    }

    /// Cancels any running loop and starts a fresh one that refreshes immediately.
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// User-initiated refresh: resets backoff and restarts the cadence from now.
    func manualRefresh() {
        consecutiveFailures = 0
        start()
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let delay = await refresh()
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Fetches once and returns the number of seconds to wait before the next poll.
    @discardableResult
    private func refresh() async -> Double {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let resp = try await service.fetch()
            snapshot = resp
            lastUpdated = Date()
            errorReason = nil
            consecutiveFailures = 0
            return 60
        } catch let error as UsageError {
            consecutiveFailures += 1
            errorReason = error.userMessage
            switch error {
            case .rateLimited(let retryAfter):
                let base = retryAfter ?? 90
                return min(base * pow(2, Double(consecutiveFailures - 1)), 600)
            case .noToken, .unauthorized:
                // Token problems won't fix themselves quickly; check back in 2 min.
                return 120
            default:
                return min(20 * pow(2, Double(consecutiveFailures - 1)), 300)
            }
        } catch {
            consecutiveFailures += 1
            errorReason = error.localizedDescription
            return min(20 * pow(2, Double(consecutiveFailures - 1)), 300)
        }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            try LoginItemControl.setEnabled(enabled)
        } catch {
            errorReason = "Login item failed: \(error.localizedDescription)"
        }
    }
}
