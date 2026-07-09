import SwiftUI
import ServiceManagement

@main
struct ClaudeUsageBarApp: App {
    @State private var store: UsageStore
    @State private var apiStore: APIUsageStore

    init() {
        // Support headless (un)registration of the login item so it can be set up from a
        // script without clicking the in-app toggle. `SMAppService.mainApp` registers the
        // *running* bundle, so this must be invoked from the installed copy. Exits when a
        // flag is handled, before any window/polling starts.
        LoginItemControl.handleLaunchFlagsIfNeeded()
        _store = State(initialValue: UsageStore())
        _apiStore = State(initialValue: APIUsageStore())
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(store: store, apiStore: apiStore)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu-bar label

/// Compact status shown in the menu bar: an icon plus the weekly all-models usage
/// (falling back to the tightest active limit when no all-models cap is reported).
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        let percent = store.snapshot?.allUsagePercent

        HStack(spacing: 3) {
            Image(systemName: symbol(percent: percent))
            if let percent {
                Text("\(Int(percent.rounded()))%")
                    .monospacedDigit()
            }
        }
        .foregroundStyle(usageColor(percent))
    }

    private func symbol(percent: Double?) -> String {
        if store.snapshot == nil {
            return store.errorReason == nil ? "hourglass" : "exclamationmark.triangle.fill"
        }
        return "gauge.with.dots.needle.bottom.50percent"
    }
}

// MARK: - Popover content

struct UsageMenuView: View {
    let store: UsageStore
    let apiStore: APIUsageStore

    var body: some View {
        // A 1 s ticker so reset countdowns and "updated Ns ago" stay live.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .frame(width: 288)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().padding(.vertical, 8)

            let rows = store.snapshot?.displayRows ?? []
            if rows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 12) {
                    ForEach(rows) { row in
                        UsageBar(row: row, now: now)
                    }
                }
                .padding(.horizontal, 14)
            }

            Divider().padding(.vertical, 8)

            APIUsageSection(store: apiStore, now: now)

            Divider().padding(.vertical, 8)

            footer(now: now)
        }
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkle")
                .foregroundStyle(.tint)
            Text("Claude Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            if store.errorReason == nil {
                ProgressView().controlSize(.small)
                Text("Loading…")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(store.errorReason ?? "Unavailable")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func footer(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status line: last-updated, plus any current error while stale data shows.
            HStack(spacing: 6) {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Text(statusText(now: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.manualRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }

            Toggle(isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.launchAtLogin = $0 }
            )) {
                Text("Launch at login").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 14)
    }

    private func statusText(now: Date) -> String {
        if let error = store.errorReason, store.snapshot == nil {
            return error
        }
        var parts: [String] = []
        if let updated = store.lastUpdated {
            parts.append("updated \(Self.relativeAge(updated, now: now))")
        }
        if let error = store.errorReason {
            parts.append(error)
        }
        return parts.joined(separator: " · ")
    }

    static func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}
