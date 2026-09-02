//
//  NetBoxFetching.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Pulse
//  The Platform for Unified Leadership in Smart Environments.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  This program is free software: communities can deploy it for sovereignty, academia can
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import OSLog

/// One HTTP hop. Writes send a JSON body; GET/DELETE leave `body` nil.
struct NetBoxHTTPRequest: Sendable, Equatable {
    var method: String
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var ifMatch: String?
}

/// Success response. Callers that need the ETag read `etag`; ingest uses `body`.
struct NetBoxHTTPResponse: Sendable, Equatable {
    var status: Int
    var body: Data
    var etag: String?
}

/// Transport for list ingest and MACD writes. `get` returns raw JSON so
/// `NetBoxListDecoder` can skip a poisoned element without aborting the page.
protocol NetBoxFetching: Sendable {
    func get(path: String, query: [URLQueryItem]) async throws -> Data
    func send(_ request: NetBoxHTTPRequest) async throws -> NetBoxHTTPResponse
}

extension NetBoxFetching {
    /// Mocks that only implement `get` can still be constructed. Writes fail closed.
    func send(_ request: NetBoxHTTPRequest) async throws -> NetBoxHTTPResponse {
        guard request.method.uppercased() == "GET" else {
            throw NetBoxSyncError.httpStatus(
                code: 405,
                body: "Write transport not implemented"
            )
        }
        let data = try await get(path: request.path, query: request.query)
        return NetBoxHTTPResponse(status: 200, body: data, etag: nil)
    }
}

enum NetBoxSyncError: Error, Equatable {
    case missingServerURL
    case missingToken
    case invalidServerURL(String)
    case httpStatus(code: Int, body: String)
    case transport(String)
    case emptyPageWithNext
    case pageLimitExceeded
    case writesDisabled(String)

    static func == (lhs: NetBoxSyncError, rhs: NetBoxSyncError) -> Bool {
        switch (lhs, rhs) {
        case (.missingServerURL, .missingServerURL):
            return true
        case (.missingToken, .missingToken):
            return true
        case (.invalidServerURL(let a), .invalidServerURL(let b)):
            return a == b
        case (.httpStatus(let c1, let b1), .httpStatus(let c2, let b2)):
            return c1 == c2 && b1 == b2
        case (.transport(let a), .transport(let b)):
            return a == b
        case (.emptyPageWithNext, .emptyPageWithNext):
            return true
        case (.pageLimitExceeded, .pageLimitExceeded):
            return true
        case (.writesDisabled(let a), .writesDisabled(let b)):
            return a == b
        default:
            return false
        }
    }

    @MainActor
    func publish() {
        switch self {
        case .httpStatus(let code, let body) where code == 401 || code == 403:
            RequestStatusManager.shared.updateStatus(
                .netbox,
                .authenticationFailure(code: code, message: Self.operatorMessage(code: code, body: body))
            )
        case .httpStatus(let code, let body):
            RequestStatusManager.shared.updateStatus(
                .netbox,
                .dataError(code: code, message: Self.operatorMessage(code: code, body: body))
            )
        case .transport(let message):
            RequestStatusManager.shared.updateStatus(.netbox, .connectionError(message))
        case .missingToken:
            RequestStatusManager.shared.updateStatus(
                .netbox,
                .authenticationFailure(code: 0, message: localizedDescription)
            )
        case .missingServerURL, .invalidServerURL, .emptyPageWithNext, .pageLimitExceeded, .writesDisabled:
            RequestStatusManager.shared.updateStatus(
                .netbox,
                .dataError(code: 0, message: localizedDescription)
            )
        }
    }
}

extension NetBoxSyncError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingServerURL:
            return "NetBox server URL is not configured"
        case .missingToken:
            return "NetBox API token is not configured"
        case .invalidServerURL(let value):
            return "NetBox server URL is invalid: \(value)"
        case .httpStatus(let code, let body) where code == 412:
            return "NetBox conflict (412): \(Self.operatorMessage(code: code, body: body))"
        case .httpStatus(let code, let body):
            return "NetBox \(code): \(Self.operatorMessage(code: code, body: body))"
        case .transport(let message):
            return message
        case .emptyPageWithNext:
            return "NetBox returned an empty page that still claimed a next page"
        case .pageLimitExceeded:
            return "NetBox pagination exceeded the page safety limit"
        case .writesDisabled(let message):
            return message
        }
    }

    /// Operator-facing body. JSON `detail` is kept; HTML proxy pages
    /// (FortiADC 503, WAF 403) become a sentence keyed off the status.
    static func operatorMessage(code: Int, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallback(code)
        }
        if looksLikeMarkup(trimmed) {
            return fallback(code)
        }
        if let detail = jsonDetail(trimmed) {
            return detail
        }
        if trimmed.count > 280 {
            return fallback(code)
        }
        return trimmed
    }

    private static func looksLikeMarkup(_ body: String) -> Bool {
        let head = body.prefix(48).lowercased()
        return head.hasPrefix("<!")
            || head.hasPrefix("<html")
            || head.hasPrefix("<iframe")
            || head.hasPrefix("<head")
            || head.hasPrefix("<body")
    }

    private static func jsonDetail(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        return nil
    }

    private static func fallback(_ code: Int) -> String {
        switch code {
        case 401, 403:
            return "NetBox refused this request. Check the API token and permissions."
        case 404:
            return "NetBox could not find that object."
        case 408, 504:
            return "NetBox timed out. Try again."
        case 429:
            return "NetBox rate-limited this request. Try again shortly."
        case 500, 502, 503:
            return "NetBox is temporarily unavailable."
        default:
            return "NetBox returned an error (\(code))."
        }
    }
}

/// Live HTTP using `Configuration.shared` per request (URL and token are
/// runtime-mutable). Same Token / Bearer rule as `NetBoxAuthMiddleware`.
struct NetBoxLiveFetcher: NetBoxFetching {
    private let logger = Logger(subsystem: "netbox", category: "http")

    func get(path: String, query: [URLQueryItem]) async throws -> Data {
        try await send(NetBoxHTTPRequest(method: "GET", path: path, query: query)).body
    }

    func send(_ request: NetBoxHTTPRequest) async throws -> NetBoxHTTPResponse {
        let server = await Configuration.shared.getNetboxApiServer()
        let token = await Configuration.shared.getNetboxApiToken()
        let authorization = try NetBoxAuthorization.headerValue(for: token)
        let serverURL = try NetBoxServerURL.parse(server)

        let base = serverURL.absoluteString.hasSuffix("/")
            ? String(serverURL.absoluteString.dropLast())
            : serverURL.absoluteString
        let suffix = request.path.hasPrefix("/") ? request.path : "/" + request.path
        guard var components = URLComponents(string: base + suffix) else {
            throw NetBoxSyncError.invalidServerURL(server)
        }
        if !request.query.isEmpty {
            components.queryItems = request.query
        }
        guard let url = components.url else {
            throw NetBoxSyncError.invalidServerURL(server)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let ifMatch = request.ifMatch {
            urlRequest.setValue(ifMatch, forHTTPHeaderField: "If-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            logger.error(
                "NetBox \(request.method, privacy: .public) \(url.absoluteString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            throw NetBoxSyncError.transport(Self.transportMessage(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetBoxSyncError.transport("Invalid response type")
        }
        guard (200...299).contains(http.statusCode) else {
            logger.error(
                "NetBox \(request.method, privacy: .public) \(url.absoluteString, privacy: .public) status \(http.statusCode)"
            )
            throw NetBoxSyncError.httpStatus(
                code: http.statusCode,
                body: Self.bodyString(data)
            )
        }
        return NetBoxHTTPResponse(
            status: http.statusCode,
            body: data,
            etag: http.value(forHTTPHeaderField: "ETag")
        )
    }

    /// Operator-facing transport copy. Offline is not a URL dump.
    static func transportMessage(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDataNotAllowed:
                return "NetBox is unreachable. The change was not saved."
            case NSURLErrorTimedOut:
                return "NetBox timed out. The change was not saved."
            case NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return "Cannot reach the NetBox server. The change was not saved."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    /// Surface the server JSON verbatim. `HTTPURLResponse.localizedString`
    /// is not NetBox's validation body.
    static func bodyString(_ data: Data) -> String {
        if data.isEmpty { return "" }
        if let string = String(data: data, encoding: .utf8), !string.isEmpty {
            return string
        }
        return "\(data.count) bytes"
    }
}
