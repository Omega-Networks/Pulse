//
//  InterfaceVO.swift
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

/// Sendable snapshot of an `Interface` row. Views and `LayoutManager`
/// consume this; the `@Model` never crosses an actor boundary.
struct InterfaceVO: Identifiable, Equatable, Sendable {
    var id: Int64
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

    var deviceId: Int64?
    var deviceName: String?
    var siteId: Int64?

    var connectedEndpointId: Int64?
    var connectedEndpointName: String?
    var connectedEndpointDeviceId: Int64?
    var lagId: Int64?
    var lagName: String?
    var bridgeId: Int64?
    var bridgeName: String?
    var parentId: Int64?
    var parentName: String?

    init(id: Int64) {
        self.id = id
    }

    init(model: Interface) {
        self.id = model.id
        self.name = model.name
        self.display = model.display
        self.label = model.label
        self.type = model.type
        self.enabled = model.enabled
        self.mtu = model.mtu
        self.speed = model.speed
        self.interfaceDescription = model.interfaceDescription
        self.created = model.created
        self.lastUpdated = model.lastUpdated
        self.url = model.url
        self.poeMode = model.poeMode
        self.duplex = model.duplex
        self.occupied = model.occupied
        self.deviceId = model.deviceId
        self.deviceName = model.deviceName
        self.siteId = model.siteId
        self.connectedEndpointId = model.connectedEndpointId
        self.connectedEndpointName = model.connectedEndpointName
        self.connectedEndpointDeviceId = model.connectedEndpointDeviceId
        self.lagId = model.lagId
        self.lagName = model.lagName
        self.bridgeId = model.bridgeId
        self.bridgeName = model.bridgeName
        self.parentId = model.parentId
        self.parentName = model.parentName
    }

    var speedLabel: String {
        speed.map(String.init) ?? "N/A"
    }
}
