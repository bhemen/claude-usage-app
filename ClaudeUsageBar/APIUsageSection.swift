import SwiftUI

/// The "API usage" block in the popover: month-to-date cost and tokens for the API
/// organization tied to the stored Admin key, or a prompt to add one.
struct APIUsageSection: View {
    let store: APIUsageStore
    let now: Date

    @State private var showingKeyField = false
    @State private var keyInput = ""
    /// A failed Keychain save/remove. View-local so a successful poll can't clear it.
    @State private var keyActionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if store.isConfigured {
                configuredBody
            } else {
                unconfiguredBody
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(.secondary)
            Text("API usage")
                .font(.system(size: 12, weight: .semibold))
            if store.isConfigured, let summary = store.summary {
                Text("· \(summary.monthLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isConfigured {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    store.manualRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh API usage")

                Menu {
                    Button("Replace Admin key…") {
                        keyInput = ""
                        keyActionError = nil
                        showingKeyField = true
                    }
                    Button("Remove Admin key", role: .destructive) {
                        showingKeyField = false
                        keyActionError = store.clearAdminKey()
                            ? nil
                            : "Couldn't remove the key from the Keychain; it's still in use."
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("API key options")
            }
        }
    }

    // MARK: Configured

    @ViewBuilder
    private var configuredBody: some View {
        if let summary = store.summary {
            VStack(alignment: .leading, spacing: 6) {
                metricRow("This month", money(summary.monthCostUSD), strong: true)
                metricRow("Today", money(summary.todayCostUSD))
                metricRow("Tokens",
                          "\(TokenFormat.short(summary.monthInputTokens)) in · "
                          + "\(TokenFormat.short(summary.monthOutputTokens)) out")

                if !summary.perModel.isEmpty {
                    Divider().padding(.vertical, 2)
                    ForEach(summary.perModel.prefix(4)) { model in
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.model)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(TokenFormat.short(model.inputTokens + model.outputTokens)) · \(money(model.costUSD))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            if let status = statusText {
                Text(status)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else if let error = store.errorReason {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }

        if showingKeyField {
            keyEntry
        } else if let keyActionError {
            keyErrorText(keyActionError)
        }
    }

    // MARK: Unconfigured

    @ViewBuilder
    private var unconfiguredBody: some View {
        Text("Show your Anthropic API organization's tokens and cost.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if showingKeyField {
            keyEntry
        } else {
            Button {
                keyInput = ""
                keyActionError = nil
                showingKeyField = true
            } label: {
                Text("Add Admin API key…").font(.system(size: 12))
            }
            .buttonStyle(.link)
        }

        Text("Requires a multi-user org Admin key (sk-ant-admin01…).")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Key entry

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("sk-ant-admin01-…", text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            HStack {
                Button("Save") {
                    if store.setAdminKey(keyInput) {
                        keyInput = ""
                        keyActionError = nil
                        showingKeyField = false
                    } else {
                        // Keep the field open with the input so the user can retry.
                        keyActionError = store.isConfigured
                            ? "Couldn't save the key to the Keychain; the previous key is still in use."
                            : "Couldn't save the key to the Keychain."
                    }
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") {
                    keyInput = ""
                    keyActionError = nil
                    showingKeyField = false
                }
                .buttonStyle(.borderless)
            }
            if let keyActionError {
                keyErrorText(keyActionError)
            }
        }
    }

    private func keyErrorText(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10.5))
    }

    // MARK: Helpers

    private func metricRow(_ label: String, _ value: String, strong: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: strong ? .semibold : .regular))
                .monospacedDigit()
        }
    }

    private func money(_ usd: Double) -> String {
        if usd > 0 && usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    private var statusText: String? {
        var parts: [String] = []
        if let day = store.summary?.lastReportedDayLabel {
            parts.append("reported through \(day)")
        }
        if let updated = store.lastUpdated {
            parts.append("updated \(UsageMenuView.relativeAge(updated, now: now))")
        }
        if let error = store.errorReason {
            parts.append(error)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
