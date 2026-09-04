//
//  Cable.swift
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

/// Persisted NetBox cable. `siteId` is denormalized from the A-end
/// interface (then B) so per-site topology fetches resolve via `#Index`.
/// Tenant is the cable's own field — defaulted from the device/site on
/// create in NetBox, changeable afterwards. `bundleId` is stored and
/// unused until bundles ship.
///
/// Optional reference ids are nil, never 0. Do not express optional-id
/// filters as `!= nil` in `#Predicate` (SwiftData NULL trap). Fetch by
/// `siteId` equality and join ends in memory.
@Model
final class Cable {
    #Index<Cable>([\.siteId])

    @Attribute(.unique) var id: Int64
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

    /// Denormalized site of the first resolved end. Indexed. 0 when
    /// neither interface is in the store yet.
    var siteId: Int64 = 0

    var aInterfaceId: Int64?
    var bInterfaceId: Int64?

    var tenantId: Int64?
    var tenantName: String?

    /// Reserved. Bundles are later work.
    var bundleId: Int64?

    init(id: Int64) {
        self.id = id
    }
}

extension Cable: Identifiable {}
