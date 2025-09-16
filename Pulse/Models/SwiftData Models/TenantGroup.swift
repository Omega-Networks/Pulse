//
//  TenantGroup.swift
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
final class TenantGroup {
    @Attribute(.unique) var id: Int64
    var name: String?
    var created: Date?
    var lastUpdated: Date?
    
    @Relationship(inverse: \Tenant.group)
    var tenants: [Tenant]? = []
    
    init(id: Int64) {
        self.id = id
    }
    
}

/// API For TenantGroup
// {
//"id": 1,
//"url": "https://netbox.example.com/api/tenancy/tenant-groups/1/",
//"display": "Examples",
//"name": "Examples",
//"slug": "examples",
//"parent": null,
//"description": "",
//"tags": [],
//"custom_fields": {},
//"created": "2022-04-27T09:50:09.336100Z",
//"last_updated": "2022-04-27T09:50:09.336121Z",
//"tenant_count": 12,
//"_depth": 0
//}

struct TenantGroupProperties: Codable {
    
    // MARK: Codable
    
    private enum CodingKeys: String, CodingKey {
        case id, name, created, lastUpdated
    }
    
    let id: Int64
    let name: String
    let created: Date
    let lastUpdated: Date
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date?.self, forKey: .lastUpdated)
        
        // Ignore records with missing data.
        guard let id = rawId,
              let name = rawName,
              let created = rawCreated
        else {
            let values = "id = \(rawId?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "created = \(rawCreated?.description ?? "nil"), "
            + "lastUpdated = \(rawLastUpdated?.description ?? "nil")"
            
            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        
        self.id = id
        self.name = name
        self.created = created
        self.lastUpdated = rawLastUpdated ?? Date.distantPast
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(created, forKey: .created)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }
    
    // The keys must have the same name as the attributes of the TenantGroup entity.
    var dictionaryValue: [String: Any] {
        [
            "id": id,
            "name": name,
            "created": created,
            "lastUpdated": lastUpdated as Any
        ]
    }
}

