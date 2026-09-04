//
//  NetBoxClientFactory.swift
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
import NetBoxAPI
import OpenAPIRuntime
import OpenAPIURLSession

/// Builds a generated NetBox `Client` with the current Settings values.
///
/// The generated client binds `serverURL` at init. Settings can change the
/// URL mid-session, so callers construct a fresh client per request (cheap:
/// URL + transport + middleware, no connection). Auth middleware re-reads
/// the token on every request for the same reason.
enum NetBoxClientFactory {
    /// Default configuration: lenient dates. Transport is injectable so tests
    /// can supply a mock `ClientTransport` without hitting the network.
    static func makeClient(
        serverURL: URL,
        transport: any ClientTransport = URLSessionTransport(),
        middlewares: [any ClientMiddleware] = [NetBoxAuthMiddleware()]
    ) -> Client {
        Client(
            serverURL: serverURL,
            configuration: OpenAPIRuntime.Configuration(dateTranscoder: NetBoxLenientDateTranscoder()),
            transport: transport,
            middlewares: middlewares
        )
    }

    /// Reads the server URL from `Configuration.shared` and builds a client.
    /// Rejects anything that is not `https` with a host.
    static func makeClient() async throws -> Client {
        let raw = await Configuration.shared.getNetboxApiServer()
        return makeClient(serverURL: try NetBoxServerURL.parse(raw))
    }
}
