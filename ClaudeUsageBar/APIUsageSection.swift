import SwiftUI

/// The "API usage" block in the popover: month-to-date cost and tokens for the API
/// organization tied to the stored Admin key, or a prompt to add one.
struct APIUsageSection: View {
    let store: APIUsageStore
    let now: Date

    @State private var showingKeyField = false
    @State private var keyInput = ""

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
                        showingKeyField = true
                    }
                    Button("Remove Admin key", role: .destructive) {
                        showingKeyField = false
                        store.clearAdminKey()
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
                    store.setAdminKey(keyInput)
                    keyInput = ""
                    showingKeyField = false
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") {
                    keyInput = ""
                    showingKeyField = false
                }
                .buttonStyle(.borderless)
            }
        }
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
        if let updated = store.lastUpdated {
            parts.append("updated \(UsageMenuView.relativeAge(updated, now: now))")
        }
        if let error = store.errorReason {
            parts.append(error)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
