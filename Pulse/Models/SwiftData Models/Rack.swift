//
//  Rack.swift
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

/// Persisted NetBox rack. `siteId` is denormalized so per-site fetches
/// resolve via `#Index` rather than walking `site.racks`.
@Model
final class Rack {
    #Index<Rack>([\.siteId])

    @Attribute(.unique) var id: Int64
    var created: Date?
    var display: String?
    var lastUpdated: Date?
    var name: String?
    var url: String?
    var uHeight: Int64?
    var startingUnit: Int64 = 1
    var deviceCount: Int64?
    var status: String?
    var formFactor: String?
    /// NetBox location id. 0 means none.
    var locationId: Int64 = 0
    /// NetBox rack-role id. 0 means none.
    var rackRoleId: Int64 = 0

    /// Denormalized owner site id. Indexed. Set before insert.
    var siteId: Int64 = 0

    var site: Site?

    @Relationship(deleteRule: .nullify, inverse: \Device.rack)
    var devices: [Device]?

    init(id: Int64) {
        self.id = id
    }
}

extension Rack: Identifiable {}
