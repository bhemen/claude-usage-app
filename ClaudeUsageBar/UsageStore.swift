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

    /// Mirrors the real login-item status (not the user's last click), so the toggle can't
    /// show "on" after a failed or approval-pending registration. Change via `setLaunchAtLogin`;
    /// re-read via `refreshLoginItemStatus`, since System Settings can change it too.
    private(set) var launchAtLogin: Bool
    /// Registered but not allowed in System Settings (pending approval, or switched off there).
    private(set) var loginItemNeedsApproval = false
    /// Why the last login-item change didn't take effect. Kept separate from `errorReason`
    /// so the next successful poll doesn't wipe it.
    private(set) var loginItemError: String?

    private let service = UsageService()
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    init() {
        launchAtLogin = LoginItemControl.isEnabled
        refreshLoginItemStatus()
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
            // Never sleep less than 5 s, as a hard backstop against any code path (or a
            // bogus Retry-After) that could otherwise spin the loop and hammer the API.
            let delay = max(await refresh(), 5)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Fetches once and returns the number of seconds to wait before the next poll.
    @discardableResult
    private func refresh() async -> Double {
        isRefreshing = true
        // A superseded poll must not clear the spinner of the poll that replaced it.
        defer { if !Task.isCancelled { isRefreshing = false } }

        let result: Result<UsageResponse, Error>
        do {
            result = .success(try await service.fetch())
        } catch {
            result = .failure(error)
        }
        // `start()` cancelled this poll (e.g. a manual refresh) while the request was in
        // flight. Its failure is just URLSession's cancellation, not "Offline", and the
        // replacement poll now owns the state — so touch nothing.
        guard !Task.isCancelled else { return 0 }

        do {
            let resp = try result.get()
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
                // Honor Retry-After, but never retry faster than 60 s. A 429 with a small
                // or zero Retry-After (which the endpoint sends under load) would otherwise
                // drive a near-zero sleep and hammer the API — the "flickering" symptom.
                let base = max(retryAfter ?? 90, 60)
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

    /// Applies the toggle, then re-reads the actual status so the checkbox reflects reality.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemControl.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Login item failed: \(error.localizedDescription)"
        }
        refreshLoginItemStatus()
    }

    /// Re-reads the real login-item status. The user can approve or switch off the item in
    /// System Settings at any time, so the popover calls this whenever it opens.
    func refreshLoginItemStatus() {
        launchAtLogin = LoginItemControl.isEnabled
        loginItemNeedsApproval = LoginItemControl.requiresApproval
        if launchAtLogin { loginItemError = nil }
    }
}
