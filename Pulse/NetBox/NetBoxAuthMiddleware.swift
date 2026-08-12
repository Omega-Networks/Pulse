//
//  NetBoxAuthMiddleware.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import OSLog

/// Injects `Authorization` on every request from `Configuration.shared`.
///
/// Token and server URL are runtime-mutable in Settings; reading them here
/// (not at client construction) is what makes a mid-session edit take effect
/// without a relaunch. v2 tokens (`nbt_…`) go out as `Bearer`; everything
/// else as `Token` (v1, deprecated in 4.6, removed in 5.0).
struct NetBoxAuthMiddleware: ClientMiddleware {
    private let logger = Logger(subsystem: "netbox", category: "auth")

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let token = await Configuration.shared.getNetboxApiToken()
        var authorized = request
        if token.isEmpty {
            logger.error("NetBox token is empty; sending request without Authorization")
        } else if token.hasPrefix("nbt_") {
            authorized.headerFields[.authorization] = "Bearer \(token)"
        } else {
            authorized.headerFields[.authorization] = "Token \(token)"
        }
        return try await next(authorized, body, baseURL)
    }
}
