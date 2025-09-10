//
//  DeviceType.swift
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
final class DeviceType {
    @Attribute(.unique) var id: Int64
    var model: String? = ""
    var created: Date?
    var lastUpdated: Date?
    var uHeight: Float?
    
    @Relationship(inverse: \Device.deviceType)
        var devices: [Device]?
    
    init(id: Int64) {
        self.id = id
    }
}

/// API For Device Type
//{
//    "id": 1,
//    "url": "https://netbox.example.com/api/dcim/device-types/1/",
//    "display": "FortiGate 50E",
//    "manufacturer": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/manufacturers/1/",
//        "display": "Fortinet",
//        "name": "Fortinet",
//        "slug": "fortinet"
//    },
//    "default_platform": null,
//    "model": "FortiGate 50E",
//    "slug": "fg-50e",
//    "part_number": "FGT_50E",
//    "u_height": 1.0,
//    "is_full_depth": false,
//    "subdevice_role": null,
//    "airflow": null,
//    "weight": null,
//    "weight_unit": null,
//    "front_image": null,
//    "rear_image": null,
//    "description": "",
//    "comments": "",
//    "tags": [],
//    "custom_fields": {},
//    "created": "2022-04-26T09:39:03.189910Z",
//    "last_updated": "2022-04-26T09:39:03.189928Z",
//    "device_count": 0
//}


struct DeviceTypeProperties: Codable {
    
    // MARK: Codable
    
    private enum CodingKeys: String, CodingKey {
        case id, model, created
        case lastUpdated = "last_updated"
        case uHeight = "u_height"
    }
    
    let id: Int64
    let model: String
    let created: Date
    let lastUpdated: Date?
    let uHeight: Float?
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawModel = try? values.decode(String.self, forKey: .model)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date?.self, forKey: .lastUpdated)
        let rawuHeight = try? values.decode(Float?.self, forKey: .uHeight)
        
        // Ignore records with missing data.
        guard let id = rawId,
              let model = rawModel,
              let created = rawCreated
        else {
            let values = "id = \(rawId?.description ?? "nil"), "
            + "display = \(rawModel?.description ?? "nil"), "
            + "created = \(rawCreated?.description ?? "nil"), "
            + "lastUpdated = \(rawLastUpdated?.description ?? "nil")"
            
            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        
        self.id = id
        self.model = model
        self.created = created
        self.lastUpdated = rawLastUpdated
        self.uHeight = rawuHeight
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(created, forKey: .created)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(model, forKey: .model)
        try container.encode(uHeight, forKey: .uHeight)
    }
    
    // The keys must have the same name as the attributes of the DeviceType entity.
    var dictionaryValue: [String: Any] {
        [
            "id": id,
            "model": model,
            "created": created,
            "lastUpdated": lastUpdated as Any
        ]
    }
}
