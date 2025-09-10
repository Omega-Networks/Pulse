//
//  Rack.swift
//  PulseSync
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
import SwiftUI


//    TODO: Add status property
@Model
final class Rack {
    @Attribute(.unique) var id: Int64
    var created: Date?
    var display: String?
    var lastUpdated: Date?
    var name: String?
    var url: String?
    var uHeight: Int64?
    var startingUnit: Int64 = 1
    var deviceCount: Int64?
    var status: String?
    
    var site: Site?
    var formFactor: String?
    
    init(id: Int64) {
        self.id = id
    }
    
    @Relationship(deleteRule: .cascade, inverse: \Device.rack)
    var devices: [Device]?
}

// API For Rack
//{
//    "id": 1,
//    "url": "https://netbox.example.com/api/dcim/racks/1/",
//    "display_url": "https://netbox.example.com/dcim/racks/1/",
//    "display": "A.0.A.1",
//    "name": "A.0.A.1",
//    "facility_id": null,
//    "site": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/sites/1/",
//        "display": "001 - Museum",
//        "name": "001 - Museum",
//        "slug": "001-museum",
//        "description": "Museum"
//    },
//    "location": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/locations/1/",
//        "display": "FD - 0.a",
//        "name": "FD - 0.A",
//        "slug": "fd-0-a",
//        "description": "Ground floor",
//        "rack_count": 0,
//        "_depth": 2
//    },
//    "tenant": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/tenancy/tenants/1/",
//        "display": "Example",
//        "name": "Example",
//        "slug": "example",
//        "description": ""
//    },
//    "status": {
//        "value": "active",
//        "label": "Active"
//    },
//    "role": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/rack-roles/1/",
//        "display": "Primary",
//        "name": "Primary",
//        "slug": "primary",
//        "description": "Primary Comms Rack"
//    },
//    "serial": "",
//    "asset_tag": null,
//    "rack_type": null,
//    "form_factor": null,
//    "width": {
//        "value": 19,
//        "label": "19 inches"
//    },
//    "u_height": 45,
//    "starting_unit": 1,
//    "weight": null,
//    "max_weight": null,
//    "weight_unit": null,
//    "desc_units": false,
//    "outer_width": null,
//    "outer_depth": null,
//    "outer_unit": null,
//    "mounting_depth": null,
//    "airflow": null,
//    "description": "",
//    "comments": "",
//    "tags": [],
//    "custom_fields": {},
//    "created": "2022-06-08T00:25:40.759962Z",
//    "last_updated": "2024-04-24T00:06:46.017955Z",
//    "device_count": 21,
//    "powerfeed_count": 0
//}

import OSLog
import Foundation

struct RackProperties: Codable {
    // MARK: Decodable
    
    private enum CodingKeys: String, CodingKey {
        case id, name, display, url, created, site, status
        case uHeight = "u_height"
        case startingUnit = "starting_unit"
        case deviceCount = "device_count"
        case formFactor = "form_factor"
        case lastUpdated = "last_updated"
    }
    
    private enum SiteKeys: String, CodingKey {
        case siteId = "id"
        case siteName = "name"
    }
    
    private enum StatusKeys: String, CodingKey {
        case status = "value"
    }
    
    var id: Int64?
    let name: String
    let display: String
    let url: String
    let created: Date?
    let lastUpdated: Date?
    let uHeight: Int64
    let startingUnit: Int64
    let deviceCount: Int64
    
    let siteId: Int64
    let siteName: String
    
    let status: String
    let formFactor: String?
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawDisplay = try? values.decode(String.self, forKey: .display)
        let rawURL = try? values.decode(String.self, forKey: .url)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date.self, forKey: .lastUpdated)
        let rawUHeight = try? values.decode(Int64.self, forKey: .uHeight)
        let rawStartingUnit = try? values.decode(Int64.self, forKey: .startingUnit)
        let rawDeviceCount = try? values.decode(Int64.self, forKey: .deviceCount)
        let rawFormFactor = try? values.decode(String.self, forKey: .formFactor)
        
        // Nested Site Attributes
        var rawSiteId: Int64 = 0
        var rawSiteName: String = ""
        
        // Nested status attributes
        var rawStatus: String?
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let siteContainer = try? codingContainer.nestedContainer(keyedBy: SiteKeys.self, forKey: .site) {
                rawSiteId = try! siteContainer.decode(Int64.self, forKey: .siteId)
                rawSiteName = try! siteContainer.decode(String.self, forKey: .siteName)
            }
            
            if let statusContainer = try? codingContainer.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
                rawStatus = try? statusContainer.decode(String.self, forKey: .status)
            }
        }
        
        // Ignore records with missing data.
        guard let id = rawId,
              let name = rawName,
              let url = rawURL,
              let created = rawCreated,
              let lastUpdated = rawLastUpdated,
              let display = rawDisplay,
              let uHeight = rawUHeight,
              let startingUnit = rawStartingUnit,
              let deviceCount = rawDeviceCount
        else {
            let values = "id = \(rawId?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "created = \(rawCreated?.description ?? "nil"), "
            + "lastUpdated = \(rawLastUpdated?.description ?? "nil"), "
            + "display = \(rawDisplay?.description ?? "nil"), "
            + "url = \(rawURL?.description ?? "nil"), "
            + "uHeight = \(rawUHeight?.description ?? "nil"), "
            + "startingUnit = \(rawStartingUnit?.description ?? "nil"), "
            + "deviceCount = \(rawDeviceCount?.description ?? "nil")"
            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        
        // Assign defaults for values with potential 'nil' return
        let siteId = rawSiteId
        let siteName = rawSiteName
        let status = rawStatus ?? ""
        let formFactor = rawFormFactor
        
        self.id = id
        self.name = name
        self.created = created
        self.lastUpdated = lastUpdated
        self.status = status
        self.display = display
        self.url = url
        self.uHeight = uHeight
        self.startingUnit = startingUnit
        self.deviceCount = deviceCount
        
        self.siteId = siteId
        self.siteName = siteName
        self.formFactor = formFactor
    }
    
    init(id: Int64? = nil, name: String, display: String, url: String, created: Date?, lastUpdated: Date?, status: String, uHeight: Int64, startingUnit: Int64, deviceCount: Int64, siteId: Int64, siteName: String, formFactor: String?) {
        self.id = id
        self.name = name
        self.display = display
        self.url = url
        self.created = created
        self.lastUpdated = lastUpdated
        self.status = status
        self.uHeight = uHeight
        self.startingUnit = startingUnit
        self.deviceCount = deviceCount
        self.siteId = siteId
        self.siteName = siteName
        self.formFactor = formFactor
    }
    
    // MARK: Encodable
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(display, forKey: .display)
        try container.encode(url, forKey: .url)
        try container.encode(uHeight, forKey: .uHeight)
        try container.encode(startingUnit, forKey: .startingUnit)
        try container.encode(deviceCount, forKey: .deviceCount)
        
        var siteContainer = container.nestedContainer(keyedBy: SiteKeys.self, forKey: .site)
        try siteContainer.encode(siteId, forKey: .siteId)
        try siteContainer.encode(siteName, forKey: .siteName)
        
        var statusContainer = container.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        try statusContainer.encode(status, forKey: .status)
        
        try container.encodeIfPresent(formFactor, forKey: .formFactor)
    }
}
