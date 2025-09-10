//
//  Tenant.swift
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
import OSLog

@Model
final class Tenant {
    @Attribute(.unique) var id: Int64
    var name: String = ""
    var created: Date?
    var lastUpdated: Date?
    var group: TenantGroup?
    
    @Relationship(inverse: \Site.tenant)
    var sites: [Site]? = []
    
    init(id: Int64) {
        self.id = id
    }
}

/// API For Tenant
//{
//    "id": 1,
//    "url": "https://netbox.example.com/api/tenancy/tenants/1/",
//    "display": "Example",
//    "name": "Example",
//    "slug": "example",
//    "group": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/tenancy/tenant-groups/1/",
//        "display": "Examples",
//        "name": "Examples",
//        "slug": "wxamples",
//        "_depth": 0
//    },
//    "description": "",
//    "comments": "",
//    "tags": [],
//    "custom_fields": {},
//    "created": "2022-04-27T09:47:32.110929Z",
//    "last_updated": "2022-04-27T09:50:23.049511Z",
//    "circuit_count": 0,
//    "device_count": 7,
//    "ipaddress_count": 29,
//    "prefix_count": 0,
//    "rack_count": 0,
//    "site_count": 6,
//    "virtualmachine_count": 0,
//    "vlan_count": 0,
//    "vrf_count": 0,
//    "cluster_count": 0
//}

struct TenantProperties: Codable {
    
    // MARK: Codable
    
    private enum CodingKeys: String, CodingKey {
        case id, name, group, created
        case lastUpdated = "last_updated"
    }
    
    private enum GroupKeys: String, CodingKey {
        case groupId = "id"
    }
    
    let id: Int64
    let name: String
    let created: Date
    let lastUpdated: Date
    let groupId: Int64?
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date.self, forKey: .lastUpdated)
        
        // Nested TenantGroup Attributes
        var rawGroupId: Int64?
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let groupContainer = try? codingContainer.nestedContainer(keyedBy: GroupKeys.self, forKey: .group) {
                rawGroupId = try? groupContainer.decode(Int64.self, forKey: .groupId)
            }
        }
        
        // Ignore records with missing data.
        guard let id = rawId,
              let name = rawName,
              let created = rawCreated,
              let lastUpdated = rawLastUpdated
        else {
            let values = "id = \(rawId?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "lastUpdated = \(rawLastUpdated?.description ?? "nil")"
            
            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        
        /// Assign default values for properties with potential 'nil' return
        let groupId = rawGroupId ?? 0
        
        self.id = id
        self.name = name
        self.created = created
        self.lastUpdated = lastUpdated
        self.groupId = groupId
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(created, forKey: .created)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        
        if let groupId = groupId {
            var groupContainer = container.nestedContainer(keyedBy: GroupKeys.self, forKey: .group)
            try groupContainer.encode(groupId, forKey: .groupId)
        }
    }
    
    // The keys must have the same name as the attributes of the Tenant entity.
    var dictionaryValue: [String: Any] {
        [
            "id": id,
            "name": name,
            "lastUpdated": lastUpdated
        ]
    }
}
