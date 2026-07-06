import SwiftUI

/// Threshold colors matching the claude.ai usage popup:
/// green < 40, yellow 40–69, orange 70–89, red ≥ 90.
func usageColor(_ percent: Double?) -> Color {
    guard let percent else { return .secondary }
    switch percent {
    case ..<40:   return .green
    case ..<70:   return .yellow
    case ..<90:   return .orange
    default:      return .red
    }
}

/// A single usage row: title, a capsule progress bar, the percentage, and a reset note.
struct UsageBar: View {
    let row: UsageRow
    let now: Date

    private var color: Color { usageColor(row.percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(row.percent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, min(1, row.percent / 100)) * geo.size.width)
                }
            }
            .frame(height: 6)

            if let text = resetText {
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resetText: String? {
        Self.formatReset(row.resetsAt, now: now)
    }

    /// "resets in 4h56m" when under a day away, else "resets Tue 9:00 PM".
    static func formatReset(_ resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return "resetting…" }

        if interval < 24 * 3600 {
            let totalMinutes = Int(interval / 60)
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours > 0 {
                return "resets in \(hours)h\(String(format: "%02d", minutes))m"
            }
            return "resets in \(minutes)m"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return "resets \(formatter.string(from: resetsAt))"
    }
}
