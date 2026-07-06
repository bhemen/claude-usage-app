import Foundation

enum UsageError: Error {
    case noToken
    case unauthorized
    case rateLimited(retryAfter: Double?)
    case http(status: Int)
    case transport(String)

    var userMessage: String {
        switch self {
        case .noToken:       return "Not logged in — run Claude Code once"
        case .unauthorized:  return "Stale token — sign in to Claude Code"
        case .rateLimited:   return "Rate limited — backing off"
        case .http(let s):   return "Server error (HTTP \(s))"
        case .transport:     return "Offline"
        }
    }
}

/// Performs the authenticated GET against the usage endpoint and decodes it.
struct UsageService {
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch() async throws -> UsageResponse {
        try await performFetch(retryOnUnauthorized: true)
    }

    private func performFetch(retryOnUnauthorized: Bool) async throws -> UsageResponse {
        guard let token = KeychainReader.accessToken() else {
            throw UsageError.noToken
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("No HTTP response")
        }

        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            do {
                return try decoder.decode(UsageResponse.self, from: data)
            } catch {
                throw UsageError.transport("Decode failed: \(error.localizedDescription)")
            }
        case 401, 403:
            // Claude Code may have just rotated the token; re-read and retry once.
            if retryOnUnauthorized {
                return try await performFetch(retryOnUnauthorized: false)
            }
            throw UsageError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.http(status: http.statusCode)
        }
    }
}
