//
//  NetBoxClientFactory.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
    enum FactoryError: Error, Sendable {
        case missingServerURL
        case invalidServerURL(String)
    }

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
    static func makeClient() async throws -> Client {
        let raw = await Configuration.shared.getNetboxApiServer()
        guard !raw.isEmpty else { throw FactoryError.missingServerURL }
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw FactoryError.invalidServerURL(raw)
        }
        return makeClient(serverURL: url)
    }
}
