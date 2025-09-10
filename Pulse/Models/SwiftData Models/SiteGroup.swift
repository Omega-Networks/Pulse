//
//  SiteGroup.swift
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

import OSLog
import SwiftData

@Model
final class SiteGroup {
    @Attribute(.unique) var id: Int64
    var created: Date?
    var name: String = ""
    var lastUpdated: Date?
    var parent: SiteGroup?
    
    @Relationship(inverse: \SiteGroup.parent)
    var children: [SiteGroup]? = []
    @Relationship(inverse: \Site.group)
    var sites: [Site]? = []
    
    init(id: Int64) {
        self.id = id
    }
}

/// A struct for decoding JSON with the following structure:
/// {
///     "count": 10,
///     "next": null,
///     "previous": null,
///     "results": [
///         {
///             "id": 1,
///             "url": "https://netbox.example/api/dcim/site-groups/1/",
///             "display": "Examples",
///             "name": "Examples",
///             "slug": "example",
///             "parent": null,
///             "description": "",
///             "tags": [],
///             "custom_fields": {
///                 "latitude": null,
///                 "longitude": null
///             },
///             "created": "2022-10-06T04:34:12.069044Z",
///             "last_updated": "2022-11-28T00:42:11.162156Z",
///             "site_count": 11,
///             "_depth": 0
///         },
///     ]
/// }

/// A struct encapsulating the properties of a SiteGroup.
struct SiteGroupProperties: Codable {
    
    // MARK: Codable
    
    private enum CodingKeys: String, CodingKey {
        case id, name, created, parent
        case lastUpdated = "last_updated"
    }
    
    private enum ParentKeys: String, CodingKey {
        case parentId = "id"
    }
    
    let id: Int64
    let name: String
    let created: Date
    let lastUpdated: Date
    let parentId: Int64?
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date.self, forKey: .lastUpdated)
        
        // Nested SiteGroup Attributes
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
              let lastUpdated = rawLastUpdated
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
        self.lastUpdated = lastUpdated
        self.parentId = rawParentId
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(created, forKey: .created)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        
        var parentContainer = container.nestedContainer(keyedBy: ParentKeys.self, forKey: .parent)
        try parentContainer.encode(parentId, forKey: .parentId)
    }
    
    // The keys must have the same name as the attributes of the SiteGroup entity.
    var dictionaryValue: [String: Any] {
        [
            "id": id,
            "name": name,
            "created": created,
            "lastUpdated": lastUpdated
        ]
    }
}

