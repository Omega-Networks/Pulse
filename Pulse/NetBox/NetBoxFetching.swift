//
//  NetBoxFetching.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
    case invalidServerURL(String)
    case httpStatus(code: Int, body: String)
    case transport(String)
    case emptyPageWithNext

    static func == (lhs: NetBoxSyncError, rhs: NetBoxSyncError) -> Bool {
        switch (lhs, rhs) {
        case (.missingServerURL, .missingServerURL):
            return true
        case (.invalidServerURL(let a), .invalidServerURL(let b)):
            return a == b
        case (.httpStatus(let c1, let b1), .httpStatus(let c2, let b2)):
            return c1 == c2 && b1 == b2
        case (.transport(let a), .transport(let b)):
            return a == b
        case (.emptyPageWithNext, .emptyPageWithNext):
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
        case .missingServerURL, .invalidServerURL:
            RequestStatusManager.shared.updateStatus(
                .netbox,
                .dataError(code: 0, message: localizedDescription)
            )
        case .emptyPageWithNext:
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
        case .invalidServerURL(let value):
            return "NetBox server URL is invalid: \(value)"
        case .httpStatus(let code, let body):
            return "NetBox HTTP \(code): \(body)"
        case .transport(let message):
            return message
        case .emptyPageWithNext:
            return "NetBox returned an empty page that still claimed a next page"
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
        guard !server.isEmpty else { throw NetBoxSyncError.missingServerURL }

        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
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
        if !token.isEmpty {
            if token.hasPrefix("nbt_") {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            logger.error("NetBox GET \(url.absoluteString) failed: \(error.localizedDescription)")
            throw NetBoxSyncError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetBoxSyncError.transport("Invalid response type")
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-UTF-8 \(data.count) bytes>"
            let body = raw.count > 8192 ? String(raw.prefix(8192)) + "…" : raw
            logger.error("NetBox GET \(url.absoluteString) status \(http.statusCode): \(body)")
            throw NetBoxSyncError.httpStatus(code: http.statusCode, body: body)
        }
        return data
    }
}
