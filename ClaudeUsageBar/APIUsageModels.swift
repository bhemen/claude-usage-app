import Foundation

// MARK: - Wire models
//
// These decode the two Admin API endpoints used to report an API organization's usage:
//   GET /v1/organizations/usage_report/messages   (token counts)
//   GET /v1/organizations/cost_report             (USD, as cents)
// Both share a { data: [buckets], has_more, next_page } envelope where each bucket is a
// day (bucket_width=1d) holding a `results` array — one entry per group_by combination.
//
// Field names are spelled out with explicit CodingKeys rather than relying on
// `.convertFromSnakeCase`, which mangles digit-bearing keys like `ephemeral_1h_input_tokens`.
// Every value is optional so a schema change degrades to "count what we can" instead of
// failing to decode.

protocol PagedReport: Decodable {
    var hasMore: Bool? { get }
    var nextPage: String? { get }
}

// MARK: Usage report (tokens)

struct APIUsageReport: PagedReport {
    let data: [Bucket]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }

    struct Bucket: Decodable {
        let startingAt: String?
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startingAt = "starting_at"
            case results
        }
    }

    struct Result: Decodable {
        let model: String?
        let uncachedInputTokens: Int?
        let cacheReadInputTokens: Int?
        let outputTokens: Int?
        let cacheCreation: CacheCreation?

        enum CodingKeys: String, CodingKey {
            case model
            case uncachedInputTokens = "uncached_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreation = "cache_creation"
        }

        struct CacheCreation: Decodable {
            let ephemeral1h: Int?
            let ephemeral5m: Int?

            enum CodingKeys: String, CodingKey {
                case ephemeral1h = "ephemeral_1h_input_tokens"
                case ephemeral5m = "ephemeral_5m_input_tokens"
            }
        }

        /// All input token kinds combined — matches the console's "tokens in".
        var inputTokens: Int {
            (uncachedInputTokens ?? 0)
                + (cacheReadInputTokens ?? 0)
                + (cacheCreation?.ephemeral1h ?? 0)
                + (cacheCreation?.ephemeral5m ?? 0)
        }

        var output: Int { outputTokens ?? 0 }
    }
}

// MARK: Cost report (USD)

struct APICostReport: PagedReport {
    let data: [Bucket]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }

    struct Bucket: Decodable {
        let startingAt: String?
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startingAt = "starting_at"
            case results
        }
    }

    struct Result: Decodable {
        /// Cost in **cents**, as a decimal string (e.g. "123.78912" == $1.24).
        let amount: String?
        let model: String?
        let costType: String?

        enum CodingKeys: String, CodingKey {
            case amount
            case model
            case costType = "cost_type"
        }

        var cents: Double { Double(amount ?? "") ?? 0 }
    }
}

// MARK: - View model

/// The month-to-date rollup rendered in the popover's API section.
struct APIUsageSummary {
    let monthLabel: String          // e.g. "July"
    let monthCostUSD: Double
    let todayCostUSD: Double
    let monthInputTokens: Int
    let monthOutputTokens: Int
    let perModel: [ModelUsage]      // sorted by cost, then token volume, descending
    /// The latest UTC day the reports actually cover, e.g. "Jul 6". The Admin reporting
    /// pipeline lags the console's live billing, so today's usage usually isn't included
    /// yet — surfacing this lets an empty "Today" read as "not reported yet", not "zero".
    /// `nil` only when the API returned no day buckets at all.
    let lastReportedDayLabel: String?

    struct ModelUsage: Identifiable {
        let id: String              // model name
        var model: String { id }
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double
    }
}

// MARK: - Formatting

enum TokenFormat {
    /// Compact token count: 4,481,160 → "4.5M", 232,409 → "232K", 900 → "900".
    static func short(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000...: return String(format: "%.1fM", d / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", d / 1_000)
        default:           return "\(n)"
        }
    }
}
