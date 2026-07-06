import Foundation

// MARK: - Wire model
//
// The `/api/oauth/usage` endpoint returns several representations of the same data.
// The richest and most future-proof is the `limits` array, which carries a `kind`,
// a `percent`, a `severity`, a reset timestamp, and — for per-model weekly caps like
// Fable — a `scope.model.display_name`. We decode that array as the primary source and
// keep the legacy top-level `five_hour` / `seven_day` windows purely as a fallback for
// older token/server combinations. Every field is optional so a schema change degrades
// to "show what we can" instead of failing to decode.

struct UsageResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let limits: [UsageLimit]?
    let extraUsage: ExtraUsage?

    // Uses `.convertFromSnakeCase`, so `five_hour` -> `fiveHour`, `resets_at` -> `resetsAt`,
    // `display_name` -> `displayName`, etc. Unknown keys (the obfuscated `seven_day_*`
    // per-model buckets) are simply ignored.
}

struct UsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?
}

struct UsageLimit: Decodable {
    let kind: String?      // "session" | "weekly_all" | "weekly_scoped"
    let group: String?     // "session" | "weekly"
    let percent: Double?
    let severity: String?  // "normal" | "warning" | "critical"
    let resetsAt: String?
    let isActive: Bool?
    let scope: Scope?

    struct Scope: Decodable {
        let model: Model?
        struct Model: Decodable {
            let id: String?
            let displayName: String?
        }
    }
}

struct ExtraUsage: Decodable {
    let isEnabled: Bool?
    let utilization: Double?
}

// MARK: - View model

/// One rendered row in the popover (and a candidate for the menu-bar "worst" number).
struct UsageRow: Identifiable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let isActive: Bool

    /// Sort key: session first, then the all-models weekly cap, then scoped caps by
    /// descending utilization (tightest constraint on top).
    let order: Int
}

extension UsageResponse {
    /// Rows to display, derived from `limits` when present, else synthesized from the
    /// legacy `five_hour` / `seven_day` windows.
    var displayRows: [UsageRow] {
        if let limits, !limits.isEmpty {
            let rows = limits.enumerated().compactMap { index, limit -> UsageRow? in
                guard let percent = limit.percent else { return nil }
                let (title, order): (String, Int)
                switch limit.kind {
                case "session":
                    (title, order) = ("Current session", 0)
                case "weekly_all":
                    (title, order) = ("Weekly · all models", 1)
                case "weekly_scoped":
                    let name = limit.scope?.model?.displayName ?? "Scoped model"
                    (title, order) = ("Weekly · \(name)", 2)
                default:
                    (title, order) = (limit.kind?.capitalized ?? "Usage", 3)
                }
                return UsageRow(
                    id: "\(limit.kind ?? "limit")-\(index)",
                    title: title,
                    percent: percent,
                    resetsAt: Date.parseISO8601(limit.resetsAt),
                    isActive: limit.isActive ?? false,
                    order: order
                )
            }
            return rows.sorted {
                $0.order != $1.order ? $0.order < $1.order : $0.percent > $1.percent
            }
        }

        // Fallback: legacy top-level windows.
        var rows: [UsageRow] = []
        if let five = fiveHour, let pct = five.utilization {
            rows.append(UsageRow(id: "five_hour", title: "Current session", percent: pct,
                                 resetsAt: Date.parseISO8601(five.resetsAt), isActive: true, order: 0))
        }
        if let seven = sevenDay, let pct = seven.utilization {
            rows.append(UsageRow(id: "seven_day", title: "Weekly · all models", percent: pct,
                                 resetsAt: Date.parseISO8601(seven.resetsAt), isActive: true, order: 1))
        }
        return rows
    }

    /// The single highest utilization across all rendered rows — the tightest constraint.
    var worstPercent: Double? {
        displayRows.map(\.percent).max()
    }

    /// The all-models weekly utilization — the headline "All usage" number shown in the
    /// menu bar. Preferred over `worstPercent` because a single per-model scoped cap (e.g.
    /// Fable at 100%) shouldn't make the bar read 100% when overall usage is much lower.
    /// Falls back to the tightest constraint if no all-models cap is present.
    var allUsagePercent: Double? {
        if let limits, !limits.isEmpty {
            if let all = limits.first(where: { $0.kind == "weekly_all" })?.percent {
                return all
            }
            return limits.compactMap(\.percent).max()
        }
        return sevenDay?.utilization ?? fiveHour?.utilization
    }
}

// MARK: - Date parsing

extension Date {
    /// Parses the endpoint's ISO-8601 timestamps, which include fractional seconds and an
    /// explicit offset (e.g. "2026-07-06T17:10:00.343780+00:00"). Falls back to the
    /// non-fractional form.
    static func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
