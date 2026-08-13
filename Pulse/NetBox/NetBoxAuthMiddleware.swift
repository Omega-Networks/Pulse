//
//  NetBoxAuthMiddleware.swift
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
        guard !token.isEmpty else {
            logger.error("NetBox token is empty; refusing request")
            throw NetBoxSyncError.missingToken
        }
        var authorized = request
        authorized.headerFields[.authorization] = try NetBoxAuthorization.headerValue(for: token)
        return try await next(authorized, body, baseURL)
    }
}
