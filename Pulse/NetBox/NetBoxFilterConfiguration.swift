//
//  NetBoxFilterConfiguration.swift
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

/// Fetch-scope, delete-scope, and (later) delta-filter for NetBox sync.
///
/// One value object so the three consumers cannot drift. Defaults match the
/// IDs previously baked into `NetboxResource` paths so Gate 1 is a parity run,
/// not a scope change. Camera role IDs 11/35 on `Device` are display filters
/// and do not belong here.
struct NetBoxFilterConfiguration: Sendable, Equatable, Hashable {
    /// Manufacturers omitted from device and device-type pulls (`manufacturer_id__n`).
    var excludedManufacturerIDs: Set<Int>

    /// Roles omitted from device and device-role pulls (`role_id__n` / `id__n`).
    var excludedRoleIDs: Set<Int>

    /// Roles that identify static rack fillers (blank plate, cable management,
    /// patch panel). On-demand only in P1; not part of the boot device pull.
    var staticDeviceRoleIDs: Set<Int>

    /// Today's Omega instance IDs so Gate 1 matches the previous baked-in
    /// scope. A Settings control belongs later; do not scatter new literals.
    static let `default` = NetBoxFilterConfiguration(
        excludedManufacturerIDs: [5],
        excludedRoleIDs: [29, 30],
        staticDeviceRoleIDs: [6, 7, 18, 27]
    )

    /// Stable, sorted arrays for generated query parameters.
    var excludedManufacturerQuery: [Int] {
        excludedManufacturerIDs.sorted()
    }

    /// Device list `role_id__n` is typed `[String]` in the 4.6.2 schema.
    var excludedRoleQueryAsStrings: [String] {
        excludedRoleIDs.sorted().map(String.init)
    }

    var excludedRoleQueryAsInts: [Int] {
        excludedRoleIDs.sorted()
    }

    var staticDeviceRoleQuery: [Int] {
        staticDeviceRoleIDs.sorted()
    }

    var staticDeviceRoleQueryItems: [URLQueryItem] {
        staticDeviceRoleQuery.map { URLQueryItem(name: "role_id", value: String($0)) }
    }

    /// True if a device with these foreign keys belongs in the local store.
    func includesDevice(manufacturerID: Int?, roleID: Int?) -> Bool {
        if let manufacturerID, excludedManufacturerIDs.contains(manufacturerID) {
            return false
        }
        if let roleID, excludedRoleIDs.contains(roleID) {
            return false
        }
        return true
    }

    /// True if a device-type with this manufacturer belongs in the local store.
    func includesDeviceType(manufacturerID: Int?) -> Bool {
        guard let manufacturerID else { return true }
        return !excludedManufacturerIDs.contains(manufacturerID)
    }

    /// True if a device-role belongs in the local store.
    func includesDeviceRole(id: Int) -> Bool {
        !excludedRoleIDs.contains(id)
    }

    func isStaticDeviceRole(id: Int) -> Bool {
        staticDeviceRoleIDs.contains(id)
    }
}
