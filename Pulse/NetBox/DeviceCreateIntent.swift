//
//  DeviceCreateIntent.swift
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

import CoreGraphics
import Foundation

/// What the site graph and the rack draw for a device that NetBox has
/// not confirmed. Not a `@Model`. Rack U and face are the body's.
/// The site graph draws it at `fallbackPoint`.
struct DeviceGhost: Equatable, Sendable {
    var token: WriteToken
    var name: String
    var roleID: Int64
    /// Role name when the ask was made. The graph resolves the icon
    /// from this, the same names `Device.symbolName` switches on.
    var roleName: String = ""
    /// Device-type model when the ask was made. The graph draws it
    /// under the name, the same line a stored device draws, so the
    /// icon stays put when the stored device replaces the ask.
    var typeModel: String = ""
    var typeID: Int64
    var status: String?
    var tenantID: Int64?
    var rackID: Int64?
    var position: Float?
    var face: String?
    var uHeight: Float

    /// Same point `SiteGraphView` uses when a device has no layout slot.
    static let fallbackPoint = CGPoint(x: 150, y: 150)
}

/// POST `/api/dcim/devices/`. The ghost is this value. `perform` calls
/// the engine's device-create path, which calls `send`.
struct DeviceCreateIntent: NetBoxWriteIntent {
    static var kind: NetBoxChangeKind { .device }

    var body: NetBoxWriteBody.DeviceCreate
    var uHeight: Float
    var roleName: String = ""
    var typeModel: String = ""

    var siteId: Int64 { body.site }

    func ghost(token: WriteToken) -> DeviceGhost {
        DeviceGhost(
            token: token,
            name: body.name,
            roleID: body.role,
            roleName: roleName,
            typeModel: typeModel,
            typeID: body.deviceType,
            status: body.status,
            tenantID: body.tenant,
            rackID: body.rack,
            position: body.position,
            face: body.face,
            uHeight: uHeight
        )
    }

    func send(
        through writer: NetBoxWriteService
    ) async throws -> (record: NetBoxRecord.Device, raw: Data) {
        let response = try await writer.createDevice(body)
        let record = try NetBoxListDecoder.decodeObject(NetBoxRecord.Device.self, from: response.body)
        return (record, response.body)
    }

    func perform(on engine: NetBoxSyncEngine, token: WriteToken) async throws {
        try await engine.runDeviceCreate(self, token: token)
    }
}
