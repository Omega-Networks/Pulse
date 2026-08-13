//
//  Interface.swift
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
import SwiftData

/// Persisted NetBox interface. `deviceId` and `siteId` are denormalized
/// scalars so per-device and per-site fetches resolve via `#Index` rather
/// than walking `device.site`. Optional reference ids are nil, never 0.
///
/// Do not express optional-id filters as `!= nil` / `!= 0` in `#Predicate`
/// (SwiftData NULL trap). Fetch by `deviceId` / `siteId` equality and
/// filter connected ends in memory.
@Model
final class Interface {
    #Index<Interface>([\.deviceId], [\.siteId])

    @Attribute(.unique) var id: Int64
    var name: String = ""
    var display: String?
    var label: String?
    var type: String?
    var enabled: Bool = false
    var mtu: Int?
    var speed: Int64?
    var interfaceDescription: String?
    var created: Date?
    var lastUpdated: Date?
    var url: String?
    var poeMode: String?
    var duplex: String?
    var occupied: Bool = false

    /// Denormalized owner device id. Indexed. Set before insert.
    var deviceId: Int64 = 0
    /// Denormalized site id of the owner device. Indexed. Set before insert.
    var siteId: Int64 = 0
    var deviceName: String?

    var connectedEndpointId: Int64?
    var connectedEndpointName: String?
    var connectedEndpointDeviceId: Int64?
    var lagId: Int64?
    var lagName: String?
    var bridgeId: Int64?
    var bridgeName: String?
    var parentId: Int64?
    var parentName: String?

    // Inverse declared on `Device.interfaces`. Cascade from the device.
    var device: Device?

    init(id: Int64) {
        self.id = id
    }
}

extension Interface: Identifiable {}
