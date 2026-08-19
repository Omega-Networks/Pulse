//
//  CableVO.swift
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

/// Sendable snapshot of a `Cable` row. Views and `SiteTopologyEdges`
/// consume this; the `@Model` never crosses an actor boundary.
struct CableVO: Identifiable, Equatable, Sendable {
    var id: Int64
    var display: String?
    var url: String?
    var created: Date?
    var lastUpdated: Date?
    var status: String?
    var type: String?
    var label: String?
    var cableDescription: String?
    var colour: String?
    var length: Double?
    var lengthUnit: String?
    var siteId: Int64 = 0
    var aInterfaceId: Int64?
    var bInterfaceId: Int64?
    var tenantId: Int64?
    var tenantName: String?
    var bundleId: Int64?

    init(id: Int64) {
        self.id = id
    }

    init(model: Cable) {
        self.id = model.id
        self.display = model.display
        self.url = model.url
        self.created = model.created
        self.lastUpdated = model.lastUpdated
        self.status = model.status
        self.type = model.type
        self.label = model.label
        self.cableDescription = model.cableDescription
        self.colour = model.colour
        self.length = model.length
        self.lengthUnit = model.lengthUnit
        self.siteId = model.siteId
        self.aInterfaceId = model.aInterfaceId
        self.bInterfaceId = model.bInterfaceId
        self.tenantId = model.tenantId
        self.tenantName = model.tenantName
        self.bundleId = model.bundleId
    }

    var interfaceIDs: [Int64] {
        [aInterfaceId, bInterfaceId].compactMap { $0 }
    }
}
