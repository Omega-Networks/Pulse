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

/// GET-only transport for list ingest. Returns raw JSON so `NetBoxListDecoder`
/// can skip a poisoned element without aborting the page.
protocol NetBoxFetching: Sendable {
    func get(path: String, query: [URLQueryItem]) async throws -> Data
}

enum NetBoxSyncError: Error, Equatable {
    case missingServerURL
    case missingToken
    case invalidServerURL(String)
    case httpStatus(code: Int, body: String)
    case transport(String)
    case emptyPageWithNext
    case pageLimitExceeded

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
                .authenticationFailure(code: code, message: body)
            )
        case .httpStatus(let code, let body):
            RequestStatusManager.shared.updateStatus(
                .netbox,
                .dataError(code: code, message: body)
            )
        case .transport(let message):
            RequestStatusManager.shared.updateStatus(.netbox, .connectionError(message))
        case .missingToken:
            RequestStatusManager.shared.updateStatus(
                .netbox,
                .authenticationFailure(code: 0, message: localizedDescription)
            )
        case .missingServerURL, .invalidServerURL, .emptyPageWithNext, .pageLimitExceeded:
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
        case .httpStatus(let code, let body):
            return "NetBox HTTP \(code): \(body)"
        case .transport(let message):
            return message
        case .emptyPageWithNext:
            return "NetBox returned an empty page that still claimed a next page"
        case .pageLimitExceeded:
            return "NetBox pagination exceeded the page safety limit"
        }
    }
}

/// Live GET using `Configuration.shared` per request (URL and token are
/// runtime-mutable). Same Token / Bearer rule as `NetBoxAuthMiddleware`.
struct NetBoxLiveFetcher: NetBoxFetching {
    private let logger = Logger(subsystem: "netbox", category: "http")

    func get(path: String, query: [URLQueryItem]) async throws -> Data {
        let server = await Configuration.shared.getNetboxApiServer()
        let token = await Configuration.shared.getNetboxApiToken()
        let authorization = try NetBoxAuthorization.headerValue(for: token)
        let serverURL = try NetBoxServerURL.parse(server)

        let base = serverURL.absoluteString.hasSuffix("/")
            ? String(serverURL.absoluteString.dropLast())
            : serverURL.absoluteString
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard var components = URLComponents(string: base + suffix) else {
            throw NetBoxSyncError.invalidServerURL(server)
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw NetBoxSyncError.invalidServerURL(server)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            logger.error("NetBox GET \(url.absoluteString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw NetBoxSyncError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetBoxSyncError.transport("Invalid response type")
        }
        guard (200...299).contains(http.statusCode) else {
            logger.error("NetBox GET \(url.absoluteString, privacy: .public) status \(http.statusCode)")
            throw NetBoxSyncError.httpStatus(
                code: http.statusCode,
                body: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        return data
    }
}
