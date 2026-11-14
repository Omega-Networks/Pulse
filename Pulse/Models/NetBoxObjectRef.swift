//
//  NetBoxObjectRef.swift
//  Pulse
//
//  Copyright © 2025-present Omega Networks Limited.
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
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation

/// One NetBox object. A value, so it can cross an actor and sit in a
/// window target. Device, virtual machine, and cluster ids are not
/// unique against each other.
enum NetBoxObjectRef: Hashable, Codable, Sendable {
    case device(Int64)
    case virtualMachine(Int64)
    case cluster(Int64)

    var id: Int64 {
        switch self {
        case .device(let id), .virtualMachine(let id), .cluster(let id):
            return id
        }
    }

    /// NetBox `object_type` string for this case.
    var objectType: String {
        switch self {
        case .device: return "dcim.device"
        case .virtualMachine: return "virtualization.virtualmachine"
        case .cluster: return "virtualization.cluster"
        }
    }
}
