//
//  Cluster.swift
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

import SwiftData

/// NetBox virtualization cluster. Type and group are names. A rename
/// arrives on the next full mirror. This is not a map spatial cluster.
@Model
final class Cluster {
    #Index<Cluster>([\.siteId], [\.zabbixId])

    @Attribute(.unique) var id: Int64
    var name: String = ""
    var typeName: String = ""
    var groupName: String?
    var status: String = ""
    var tenant: Tenant?

    /// NetBox scope type, such as `dcim.site` or `dcim.location`.
    var scopeType: String?
    var scopeId: Int64?
    var scopeName: String?
    /// Site this cluster belongs to. 0 when the scope is a region, a
    /// site group, or a location that is not in the store.
    var siteId: Int64 = 0

    var zabbixId: Int64 = 0
    var zabbixInstance: Int64?

    var highestSeverityStored: Int = -2
    var highestUnacknowledgedSeverityStored: Int = -1
    var activeCountsBySeverity: [Int] = [0, 0, 0, 0, 0, 0]
    /// Worst of this cluster's own problems, its hosts, and its VMs.
    /// Display only. Site counts do not read it.
    var rollupSeverityStored: Int = -2

    @Relationship(deleteRule: .nullify, inverse: \Device.cluster)
    var devices: [Device]?

    @Relationship(deleteRule: .nullify, inverse: \VirtualMachine.cluster)
    var virtualMachines: [VirtualMachine]?

    @Relationship(deleteRule: .cascade, inverse: \Event.cluster)
    var events: [Event]?

    init(id: Int64) {
        self.id = id
    }

    var objectRef: NetBoxObjectRef { .cluster(id) }
}
