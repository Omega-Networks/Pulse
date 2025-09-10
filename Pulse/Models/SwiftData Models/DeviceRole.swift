//
//  DeviceRole.swift
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
import UniformTypeIdentifiers
import SwiftUI

@Model
final class DeviceRole {
    @Attribute(.unique) var id: Int64
    var name: String? = ""
    var created: Date?
    var lastUpdated: Date?
    var colour: String?
    
    @Relationship(inverse: \Device.deviceRole)
        var devices: [Device]?
    
    init(id: Int64) {
        self.id = id
    }
}

extension DeviceRole {
    var allowedDeviceTypes: [String] {
        var allowedDeviceTypesArray: [String] = []
        
        for device in devices ?? [] {
            if let deviceType = device.deviceType {
                if let display = deviceType.model {
                    allowedDeviceTypesArray.append(display)
                }
            }
        }
        let uniqueAllowedDeviceTypes = Array(Set(allowedDeviceTypesArray)).sorted()
        return uniqueAllowedDeviceTypes
    }
}

#if os(macOS)
struct DeviceRoleRecord: Codable, Transferable {
    let id: Int64
    let name: String
    let created: Date
    let lastUpdated: Date
    let allowedDeviceTypes: [String]
    
    init(deviceRole: DeviceRole) {
        self.id = deviceRole.id
        self.name = deviceRole.name ?? ""
        self.created = deviceRole.created ?? Date()
        self.lastUpdated = deviceRole.lastUpdated ?? Date()
        self.allowedDeviceTypes = deviceRole.allowedDeviceTypes
    }
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .deviceRoleRecord)
    }
}

extension UTType {
    static var deviceRoleRecord: UTType {
        UTType(exportedAs: "omega-networks.Pulse.DeviceRoleRecord")
    }
}

extension DeviceRole {
    var record: DeviceRoleRecord {
        DeviceRoleRecord(deviceRole: self)
    }
}
#endif



/// API For Device Role
//{
//    "id": 2,
//    "url": "https://netbox.example/api/dcim/device-roles/2/",
//    "display": "Access Point",
//    "name": "Access Point",
//    "slug": "access-point",
//    "color": "009688",
//    "vm_role": false,
//    "config_template": null,
//    "description": "Wireless Access point for client connectivity",
//    "tags": [],
//    "custom_fields": {},
//    "created": "2022-04-27T10:05:49.506279Z",
//    "last_updated": "2022-04-27T10:05:49.50 6298Z",
//    "device_count": 18,
//    "virtualmachine_count": 0
//}


struct DeviceRoleProperties: Codable {
    
    // MARK: Codable
    
    private enum CodingKeys: String, CodingKey {
        case id, name, created
        case lastUpdated = "last_updated"
        case colour = "color"
    }
    
    let id: Int64
    let name: String
    let created: Date
    let lastUpdated: Date?
    let colour: String?
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date?.self, forKey: .lastUpdated)
        let rawColour = try? values.decode(String.self, forKey: .colour)
        
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
        self.lastUpdated = rawLastUpdated
        self.colour = rawColour
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(created, forKey: .created)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(colour, forKey: .colour)
    }
    
    // The keys must have the same name as the attributes of the DeviceRole entity.
    var dictionaryValue: [String: Any] {
        [
            "id": id,
            "name": name,
            "created": created,
            "lastUpdated": lastUpdated as Any,
            "color": colour as Any
        ]
    }
}

