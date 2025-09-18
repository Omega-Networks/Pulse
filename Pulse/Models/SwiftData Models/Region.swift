//
//  Region.swift
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
final class Region {
    @Attribute(.unique) var id: Int64
    var created: Date?
    var name: String = ""
    var lastUpdated: Date?
    var siteCount: Int64 = 0
    var parent: Region?
    
    @Relationship(inverse: \Region.parent)
    var children: [Region]? = []
    
    @Relationship(inverse: \Site.region)
    var sites: [Site]? = []
    
    init(id: Int64) {
        self.id = id
    }
    
    public init (_ properties: RegionProperties){
        self.id = properties.id
        self.name = properties.name
        self.created = properties.created
        self.siteCount = properties.siteCount
        self.lastUpdated = properties.lastUpdated
    }
}

/// A struct for decoding JSON with the following structure;
///{
///    "id": 66,
///    "url": "https://netbox.example.com/api/dcim/regions/1/",
///    "display": "Palmerston North",
///    "name": "Palmerston North",
///    "slug": "palmerston-north",
///    "parent": {
///        "id": 1,
///        "url": "https://netbox.example.com/api/dcim/regions/1/",
///        "display": "07 - Manawatū-Whanganui",
///        "name": "07 - Manawatū-Whanganui",
///        "slug": "07-manawat-whanganui",
///        "_depth": 0
///    },
///    "description": "",
///    "tags": [],
///    "custom_fields": {},
///    "created": "2022-07-12T04:39:06.729612Z",
///    "last_updated": "2022-07-12T04:39:06.729643Z",
///    "site_count": 1,
///    "_depth": 1
///}


struct RegionProperties: Codable {
    
    // MARK: Codable
    
    private enum CodingKeys: String, CodingKey {
        case id, name, created, parent
        case lastUpdated = "last_updated"
        case siteCount = "site_count"
    }
    
    private enum ParentKeys: String, CodingKey {
        case parentId = "id"
    }
    
    let id: Int64
    let name: String
    let created: Date
    let lastUpdated: Date
    let siteCount: Int64
    let parentId: Int64?
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date.self, forKey: .lastUpdated)
        let rawSiteCount = try? values.decode(Int64.self, forKey: .siteCount)
        
        // Nested Region Attributes
        var rawParentId: Int64?
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let parentContainer = try? codingContainer.nestedContainer(keyedBy: ParentKeys.self, forKey: .parent) {
                rawParentId = try? parentContainer.decode(Int64.self, forKey: .parentId)
            }
        }
        
        // Ignore records with missing data.
        guard let id = rawId,
              let name = rawName,
              let created = rawCreated,
              let lastUpdated = rawLastUpdated,
              let siteCount = rawSiteCount
        else {
            let values = "id = \(rawId?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "created = \(rawCreated?.description ?? "nil"), "
            + "lastUpdated = \(rawLastUpdated?.description ?? "nil"), "
            + "siteCount = \(rawSiteCount?.description ?? "nil")"
            
            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        
        self.id = id
        self.name = name
        self.created = created
        self.lastUpdated = lastUpdated
        self.siteCount = siteCount
        self.parentId = rawParentId ?? 0
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(created, forKey: .created)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(siteCount, forKey: .siteCount)
        
        var parentContainer = container.nestedContainer(keyedBy: ParentKeys.self, forKey: .parent)
        try parentContainer.encode(parentId, forKey: .parentId)
    }
    
    // The keys must have the same name as the attributes of the Region entity.
    var dictionaryValue: [String: Any] {
        [
            "id": id,
            "name": name,
            "created": created,
            "lastUpdated": lastUpdated,
            "siteCount": siteCount
        ]
    }
}
