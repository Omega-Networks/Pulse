//
//  VirtualMachine.swift
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
import SwiftData

/// NetBox virtual machine. Keyed by id. The name is unique only inside
/// a cluster and tenant, so it is never a key.
@Model
final class VirtualMachine {
    #Index<VirtualMachine>([\.siteId], [\.clusterId], [\.zabbixId])

    @Attribute(.unique) var id: Int64
    var name: String?
    var display: String?
    var status: String = ""
    var serial: String = ""

    /// NetBox `vcpus`. A decimal, stored as given.
    var vcpus: Double?
    /// NetBox `memory`, megabytes.
    var memoryMB: Int64?
    /// NetBox `disk`, megabytes.
    var diskMB: Int64?

    /// CIDR form, display only. Connections come from services.
    var primaryIP: String?
    var created: Date?
    var lastUpdated: Date?
    var url: String?

    var siteId: Int64 = 0
    var clusterId: Int64 = 0
    var hostDeviceId: Int64 = 0

    var zabbixId: Int64 = 0
    var zabbixInstance: Int64?
    var defaultCredentialID: UUID?
    var defaultUsername: String?
    var seatGrantedAt: Date?

    var highestSeverityStored: Int = -2
    var highestUnacknowledgedSeverityStored: Int = -1
    var activeCountsBySeverity: [Int] = [0, 0, 0, 0, 0, 0]

    var site: Site?
    var cluster: Cluster?
    var hostDevice: Device?
    var role: DeviceRole?

    @Relationship(deleteRule: .cascade, inverse: \Service.virtualMachine)
    var services: [Service]?

    @Relationship(deleteRule: .cascade, inverse: \Event.virtualMachine)
    var events: [Event]?

    init(id: Int64) {
        self.id = id
    }

    var objectRef: NetBoxObjectRef { .virtualMachine(id) }

    /// Bare address from `primaryIP`, CIDR prefix removed.
    var primaryIPAddress: String? {
        guard let primaryIP else { return nil }
        if let slash = primaryIP.firstIndex(of: "/") {
            return String(primaryIP[..<slash])
        }
        return primaryIP
    }
}
