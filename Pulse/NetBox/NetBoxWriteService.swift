//
//  NetBoxWriteService.swift
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

/// Shipped write posture. Device/site methods exist but refuse to send.
/// `If-Match` stays off until the lab proves NetBox's weak ETag
/// (`W/"<last_updated>"`) actually matches under RFC 7232.
struct NetBoxWritePolicy: Sendable, Equatable {
    var deviceAndSiteWritesEnabled: Bool
    var sendIfMatch: Bool

    static let shipped = NetBoxWritePolicy(
        deviceAndSiteWritesEnabled: true,
        sendIfMatch: false
    )
}

/// Encodes and sends MACD writes. Does not touch SwiftData — the engine
/// re-fetches through the delta-apply path after a successful response.
struct NetBoxWriteService: Sendable {
    var fetcher: any NetBoxFetching
    var policy: NetBoxWritePolicy

    func patchInterface(
        id: Int64,
        body: NetBoxWriteBody.InterfacePatch
    ) async throws -> NetBoxHTTPResponse {
        try await patch(
            path: "/api/dcim/interfaces/\(id)/",
            body: body
        )
    }

    func createCable(
        _ body: NetBoxWriteBody.CableCreate
    ) async throws -> NetBoxRecord.Cable {
        let response = try await fetcher.send(
            NetBoxHTTPRequest(
                method: "POST",
                path: "/api/dcim/cables/",
                body: try NetBoxWriteJSON.encode(body)
            )
        )
        return try NetBoxListDecoder.decodeObject(NetBoxRecord.Cable.self, from: response.body)
    }

    func deleteCable(id: Int64) async throws {
        _ = try await fetcher.send(
            NetBoxHTTPRequest(method: "DELETE", path: "/api/dcim/cables/\(id)/")
        )
    }

    func patchDevice(
        id: Int64,
        body: NetBoxWriteBody.DevicePatch
    ) async throws -> NetBoxHTTPResponse {
        try requireDeviceAndSiteWrites()
        return try await patch(path: "/api/dcim/devices/\(id)/", body: body)
    }

    func createDevice(_ body: NetBoxWriteBody.DeviceCreate) async throws -> NetBoxHTTPResponse {
        try requireDeviceAndSiteWrites()
        return try await fetcher.send(
            NetBoxHTTPRequest(
                method: "POST",
                path: "/api/dcim/devices/",
                body: try NetBoxWriteJSON.encode(body)
            )
        )
    }

    func createSite(_ body: NetBoxWriteBody.SiteCreate) async throws -> NetBoxHTTPResponse {
        try requireDeviceAndSiteWrites()
        return try await fetcher.send(
            NetBoxHTTPRequest(
                method: "POST",
                path: "/api/dcim/sites/",
                body: try NetBoxWriteJSON.encode(body)
            )
        )
    }

    private func requireDeviceAndSiteWrites() throws {
        guard policy.deviceAndSiteWritesEnabled else {
            throw NetBoxSyncError.writesDisabled(
                "Device and site writes are implemented but gated off"
            )
        }
    }

    private func patch(path: String, body: some Encodable) async throws -> NetBoxHTTPResponse {
        var ifMatch: String?
        if policy.sendIfMatch {
            let current = try await fetcher.send(
                NetBoxHTTPRequest(method: "GET", path: path)
            )
            ifMatch = current.etag
        }
        return try await fetcher.send(
            NetBoxHTTPRequest(
                method: "PATCH",
                path: path,
                body: try NetBoxWriteJSON.encode(body),
                ifMatch: ifMatch
            )
        )
    }
}
