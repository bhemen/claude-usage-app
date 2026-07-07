import Foundation

enum APIUsageError: Error {
    case unauthorized
    case rateLimited(retryAfter: Double?)
    case http(status: Int)
    case transport(String)
    case decode(String)

    var userMessage: String {
        switch self {
        case .unauthorized:  return "Admin key rejected — check the key"
        case .rateLimited:   return "Rate limited — backing off"
        case .http(let s):   return "Server error (HTTP \(s))"
        case .transport:     return "Offline"
        case .decode:        return "Unexpected response"
        }
    }
}

/// Fetches an API organization's month-to-date token usage and cost via the Admin API and
/// rolls them into an `APIUsageSummary`. Read-only; authenticated with an Admin API key.
struct APIUsageService {
    private let base = "https://api.anthropic.com/v1/organizations"

    func fetch(adminKey: String, now: Date = Date()) async throws -> APIUsageSummary {
        let range = Self.monthRange(now: now)

        let usagePages: [APIUsageReport] = try await allPages(
            path: "usage_report/messages",
            query: [
                ("starting_at", range.start),
                ("ending_at", range.end),
                ("bucket_width", "1d"),
                ("limit", "31"),
                ("group_by[]", "model"),
            ],
            adminKey: adminKey
        )

        let costPages: [APICostReport] = try await allPages(
            path: "cost_report",
            query: [
                ("starting_at", range.start),
                ("ending_at", range.end),
                ("bucket_width", "1d"),
                ("limit", "31"),
                ("group_by[]", "description"),
            ],
            adminKey: adminKey
        )

        return Self.summarize(usagePages: usagePages, costPages: costPages,
                              now: now, monthLabel: range.label)
    }

    // MARK: - HTTP

    private func allPages<T: PagedReport>(path: String, query: [(String, String)],
                                         adminKey: String) async throws -> [T] {
        var pages: [T] = []
        var pageToken: String?
        var guardCount = 0
        repeat {
            var q = query
            if let pageToken { q.append(("page", pageToken)) }
            let page: T = try await get(path: path, query: q, adminKey: adminKey)
            pages.append(page)
            pageToken = (page.hasMore == true) ? page.nextPage : nil
            guardCount += 1
        } while pageToken != nil && guardCount < 20
        return pages
    }

    private func get<T: Decodable>(path: String, query: [(String, String)],
                                   adminKey: String) async throws -> T {
        var comps = URLComponents(string: "\(base)/\(path)")!
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else { throw APIUsageError.transport("Bad URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIUsageError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIUsageError.transport("No HTTP response")
        }

        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIUsageError.decode(error.localizedDescription)
            }
        case 401, 403:
            throw APIUsageError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw APIUsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw APIUsageError.http(status: http.statusCode)
        }
    }

    // MARK: - Date range

    /// Start-of-month (inclusive) to start-of-tomorrow (exclusive), in UTC, plus the full
    /// month name. The exclusive end includes today's in-progress daily bucket.
    static func monthRange(now: Date) -> (start: String, end: String, label: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let startOfToday = cal.startOfDay(for: now)
        let endExclusive = cal.date(byAdding: .day, value: 1, to: startOfToday)!

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")!

        let monthName = DateFormatter()
        monthName.dateFormat = "LLLL"
        monthName.timeZone = TimeZone(identifier: "UTC")!

        return (iso.string(from: startOfMonth), iso.string(from: endExclusive),
                monthName.string(from: now))
    }

    // MARK: - Rollup

    static func summarize(usagePages: [APIUsageReport], costPages: [APICostReport],
                          now: Date, monthLabel: String) -> APIUsageSummary {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")!
        // "2026-07-07" — matches the current UTC day bucket's starting_at prefix.
        let todayPrefix = String(iso.string(from: cal.startOfDay(for: now)).prefix(10))

        // Tokens (from the usage report, grouped by model).
        var monthIn = 0, monthOut = 0
        var tokensByModel: [String: (input: Int, output: Int)] = [:]
        for page in usagePages {
            for bucket in page.data {
                for r in bucket.results {
                    monthIn += r.inputTokens
                    monthOut += r.output
                    let model = r.model ?? "other"
                    var entry = tokensByModel[model] ?? (0, 0)
                    entry.input += r.inputTokens
                    entry.output += r.output
                    tokensByModel[model] = entry
                }
            }
        }

        // Cost (from the cost report, grouped by description → carries `model`).
        var monthCents = 0.0, todayCents = 0.0
        var centsByModel: [String: Double] = [:]
        for page in costPages {
            for bucket in page.data {
                let isToday = (bucket.startingAt ?? "").hasPrefix(todayPrefix)
                for r in bucket.results {
                    monthCents += r.cents
                    if isToday { todayCents += r.cents }
                    if let model = r.model { centsByModel[model, default: 0] += r.cents }
                }
            }
        }

        // The most recent day bucket the reports return, across both endpoints — the
        // reporting window's upper edge. The pipeline omits days it hasn't finalized, so
        // this typically lags today; we show it so a not-yet-reported "Today" isn't read
        // as a genuine zero.
        var lastReported: Date?
        for startingAt in (usagePages.flatMap { $0.data.map(\.startingAt) }
                           + costPages.flatMap { $0.data.map(\.startingAt) }) {
            guard let startingAt, let d = iso.date(from: startingAt) else { continue }
            if lastReported == nil || d > lastReported! { lastReported = d }
        }
        let dayLabel = DateFormatter()
        dayLabel.dateFormat = "MMM d"
        dayLabel.timeZone = TimeZone(identifier: "UTC")!
        let lastReportedDayLabel = lastReported.map { dayLabel.string(from: $0) }

        let models = Set(tokensByModel.keys).union(centsByModel.keys)
        let perModel = models.map { model in
            APIUsageSummary.ModelUsage(
                id: model,
                inputTokens: tokensByModel[model]?.input ?? 0,
                outputTokens: tokensByModel[model]?.output ?? 0,
                costUSD: (centsByModel[model] ?? 0) / 100
            )
        }.sorted {
            if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
            return ($0.inputTokens + $0.outputTokens) > ($1.inputTokens + $1.outputTokens)
        }

        return APIUsageSummary(
            monthLabel: monthLabel,
            monthCostUSD: monthCents / 100,
            todayCostUSD: todayCents / 100,
            monthInputTokens: monthIn,
            monthOutputTokens: monthOut,
            perModel: perModel,
            lastReportedDayLabel: lastReportedDayLabel
        )
    }
}
