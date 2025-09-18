//
//  Site.swift
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

import SwiftData
import OSLog
import SwiftUI
import MapKit

// MARK: - SwiftData
//
// Managed object subclass for the Site entity.
//

@Model
final class Site {
    @Attribute(.unique) var id: Int64
    var created: Date?
    var deviceCount: Int64? = 0
    var display: String?
    var lastUpdated: Date?
    var latitude: Double? = 0.0
    var longitude: Double? = 0.0
    var name: String = ""
    var physicalAddress: String?
    var shippingAddress: String?
    var url: String?
    var group: SiteGroup?
    var region: Region?
    var tenant: Tenant?
    var status: String? // New property for status
    //Enables SiteRow to be updated in real time
    var highestSeverityStored: Int = -1
    
    @Relationship(inverse: \Device.site)
    var devices: [Device]? = []
    
    @Relationship(deleteRule: .cascade, inverse: \Rack.site)
    var racks: [Rack]? = []
    
    init(id: Int64) {
        self.id = id
    }
    
    public init (_ properties: SiteProperties){
        self.id = properties.id
        self.created = properties.created
        self.deviceCount = properties.deviceCount
        self.display = properties.display
        self.lastUpdated = properties.lastUpdated
        self.latitude = properties.latitude
        self.longitude = properties.longitude
        self.name = properties.name
        self.status = properties.status
        self.physicalAddress = properties.physicalAddress
        self.shippingAddress = properties.shippingAddress
        self.url = properties.url
    }
}

extension Site {
    // MARK: - Location Properties
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude ?? 0, longitude: longitude ?? 0)
    }
    
    // MARK: - Device and Event Status
    
    private var monitoredDevices: [Device] {
        devices?.filter { $0.zabbixId != 0 } ?? []
    }
    
    private var activeEvents: [Event] {
        monitoredDevices.compactMap { device in
            device.events?.filter {
                $0.rClock == "0" &&
                $0.suppressed == "0"
            }
        }.flatMap { $0 }
    }
    
    private var unacknowledgedActiveEvents: [Event] {
        activeEvents.filter { $0.acknowledged == "0" }
    }
    
    // MARK: - Severity Properties
    
    var highestSeverity: Int {
        if monitoredDevices.isEmpty { return -2 }
        if activeEvents.isEmpty { return -1 }
        return activeEvents.compactMap { Int($0.severity) }.max() ?? -1
    }
    
    var highestUnacknowledgedSeverity: Int {
        if monitoredDevices.isEmpty { return -1 }
        if unacknowledgedActiveEvents.isEmpty { return -1 }
        return unacknowledgedActiveEvents.compactMap { Int($0.severity) }.max() ?? -1
    }
    
    // MARK: - Visual Properties
    
    var severityColor: Color {
        switch highestSeverity {
        case 0: return .gray
        case 1: return .blue
        case 2: return .yellow
        case 3: return .orange
        case 4: return .red
        case 5: return .black
        case -1: return .green
        default: return .indigo
        }
    }
    
    var unacknowledgedSeverityColor: Color {
        switch highestUnacknowledgedSeverity {
        case 0: return .gray
        case 1: return .blue
        case 2: return .yellow
        case 3: return .orange
        case 4: return .red
        case 5: return .black
        case -1: return .white
        default: return .indigo
        }
    }
}

/// A struct for decoding JSON with the following structure:
/// {
///     "count": 10,
///     "next": null,
///     "previous": null,
///     "results": [
///                  {
///            "id": 1,
///            "url": "https://netbox.example.com/api/dcim/sites/1/",
///            "display": "001 - Museum",
///            "name": "001 - Museum",
///            "slug": "001-museum",
///            "status": {
///                "value": "active",
///                "label": "Active"
///            },
///            "region": {
///                "id": 1,
///                "url": "https://netbox.example.com/api/dcim/regions/1/",
///                "display": "Example",
///                "name": "Example",
///                "slug": "example",
///                "_depth": 1
///            },
///            "group": {
///                "id": 1,
///                "url": /"https://netbox.example.com/api/dcim/site-groups/1/",
///                "display": "Examples",
///                "name": "Examples",
///                "slug": "examples",
///                "_depth": 0
///            },
///            "tenant": {
///                "id": 1,
///                "url": /"https://netbox.example.com/api/tenancy/tenants/1/",
///                "display": "Example",
///                "name": "Example",
///                "slug": "example"
///            },
///            "facility": "",
///            "time_zone": "Pacific/Auckland",
///            "description": "Example",
///            "physical_address": "Example",
///            "shipping_address": "",
///            "latitude": null,
///            "longitude": null,
///            "comments": "",
///            "asns": [],
///            "tags": [],
///            "custom_fields": {
///                "Identifier": "000"
///            },
///            "created": "2022-04-26T10:32:45.731650Z",
///            "last_updated": "2022-09-30T01:12:58.346614Z",
///            "circuit_count": 0,
///            "device_count": 31,
///            "prefix_count": 10,
///            "rack_count": 1,
///            "virtualmachine_count": 0,
///            "vlan_count": 0
///            }
///     ]
/// }

/// A struct encapsulating the properties of a Site.


struct SiteProperties: Codable {
    
    // MARK: Codable
    private enum CodingKeys: String, CodingKey {
        case id, url, display, name, latitude, longitude, created, group, slug, tenant, region_netbox, status
        case physicalAddress = "physical_address"
        case shippingAddress = "shipping_address"
        case lastUpdated = "last_updated"
        case deviceCount = "device_count"
    }
    
    private enum GroupKeys: String, CodingKey {
        case groupId = "id"
    }
    
    private enum RegionKeys: String, CodingKey {
        case regionId = "id"
    }
    
    private enum TenantKeys: String, CodingKey {
        case tenantId = "id"
    }
    
    private enum StatusKeys: String, CodingKey {
           case status = "value"
    }
    
    let id: Int64
    let url: String
    let display: String
    let name: String
    let latitude: Double
    let longitude: Double
    let created: Date?
    let physicalAddress: String
    let shippingAddress: String
    let lastUpdated: Date
    let deviceCount: Int64?
    let groupId: Int64
    let tenantId: Int64
    let regionId: Int64
    let slug: String?
    let status: String // This will hold only the value, not the labe
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawURL = try? values.decode(String.self, forKey: .url)
        let rawDisplay = try? values.decode(String.self, forKey: .display)
        let rawSlug = try? values.decode(String.self, forKey: .slug)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawDeviceCount = try? values.decode(Int64.self, forKey: .deviceCount)
        let rawLatitude = try? values.decode(Double.self, forKey: .latitude)
        let rawLongitude = try? values.decode(Double.self, forKey: .longitude)
        let rawLastUpdated = try? values.decode(Date.self, forKey: .lastUpdated)
        let rawPhysicalAddress = try? values.decode(String.self, forKey: .physicalAddress)
        let rawShippingAddress = try? values.decode(String.self, forKey: .shippingAddress)
        
        // Nested attributes
        var rawGroupId: Int64?
        var rawTenantId: Int64?
        var rawRegionId: Int64?
        var rawStatus: String?
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let groupContainer = try? codingContainer.nestedContainer(keyedBy: GroupKeys.self, forKey: .group) {
                rawGroupId = try? groupContainer.decode(Int64.self, forKey: .groupId)
            }
        }
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let groupContainer = try? codingContainer.nestedContainer(keyedBy: TenantKeys.self, forKey: .tenant) {
                rawTenantId = try? groupContainer.decode(Int64.self, forKey: .tenantId)
            }
        }
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let groupContainer = try? codingContainer.nestedContainer(keyedBy: RegionKeys.self, forKey: .region_netbox) {
                rawRegionId = try? groupContainer.decode(Int64.self, forKey: .regionId)
            }
        }
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let groupContainer = try? codingContainer.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
                rawStatus = try? groupContainer.decode(String.self, forKey: .status)
            }
        }
        
        // Ignore records with missing data.
        guard let id = rawId,
              let url = rawURL,
              let display = rawDisplay,
              let name = rawName,
              let slug = rawSlug,
              let created = rawCreated,
              let lastUpdated = rawLastUpdated
        else {
            let values = "id = \(rawId?.description ?? "nil"), "
            + "url = \(rawURL?.description ?? "nil"), "
            + "display = \(rawDisplay?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "created = \(rawCreated?.description ?? "nil"), "
            + "deviceCount = \(rawDeviceCount?.description ?? "nil"), "
            + "lastUpdated = \(rawLastUpdated?.description ?? "nil"), "
            + "physicalAddress = \(rawPhysicalAddress?.description ?? "nil"), "
            + "shippingAddress = \(rawShippingAddress?.description ?? "nil"), "
            
            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        
        /// Assign defaults for value with potential 'nil' return
        let longitude = rawLongitude ?? 0.0
        let latitude = rawLatitude ?? 0.0
        let groupId = rawGroupId ?? 0
        let tenantId = rawTenantId ?? 0
        let regionId = rawRegionId ?? 0
        let status = rawStatus ?? ""
        
        self.id = id
        self.name = name
        self.slug = slug
        self.status = status
        self.created = created
        self.lastUpdated = lastUpdated
        self.display = display
        self.url = url
        //When creating a new Site, device count is always 0 so must be an optional
        self.deviceCount = rawDeviceCount
        self.longitude = longitude
        self.latitude = latitude
        //When creating a new Site, physical and shipping addresses are optional
        self.physicalAddress = rawPhysicalAddress ?? ""
        self.shippingAddress = rawShippingAddress ?? ""
        /// Relationship mapping value
        self.groupId = groupId
        self.tenantId = tenantId
        self.regionId = regionId
    }
    
    init(id: Int64, name: String, slug: String, status: String, display: String, url: String, latitude: Double, longitude: Double, physicalAddress: String, shippingAddress: String, groupId: Int64, regionId: Int64, tenantId: Int64) {
        self.id = id
        self.created = nil
        self.lastUpdated = Date.distantPast
        self.name = name
        self.status = status
        self.display = display
        self.url = url
        self.latitude = latitude
        self.longitude = longitude
        self.physicalAddress = physicalAddress
        self.shippingAddress = shippingAddress
        self.slug = slug
        self.deviceCount = nil
        self.groupId = groupId
        self.regionId = regionId
        self.tenantId = tenantId
    }
    
    // The keys must have the same name as the attributes of the Site entity.
//    var dictionaryValue: [String: Any] {
//        [
//            "id": id,
//            "name": name,
//            "created": created,
//            "lastUpdated": lastUpdated,
//            "display": display,
//            "url": url,
//            "deviceCount": deviceCount,
//            "longitude": longitude,
//            "latitude": latitude,
//            "physicalAddress": physicalAddress,
//            "shippingAddress": shippingAddress
//        ]
//    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(display, forKey: .display)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .slug)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(created, forKey: .created)
        try container.encode(physicalAddress, forKey: .physicalAddress)
        try container.encode(shippingAddress, forKey: .shippingAddress)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(deviceCount, forKey: .deviceCount)
        
        var groupContainer = container.nestedContainer(keyedBy: GroupKeys.self, forKey: .group)
        try groupContainer.encode(groupId, forKey: .groupId)
        
        var regionContainer = container.nestedContainer(keyedBy: RegionKeys.self, forKey: .region_netbox)
        try regionContainer.encode(regionId, forKey: .regionId)
        
        var tenantContainer = container.nestedContainer(keyedBy: TenantKeys.self, forKey: .tenant)
        try tenantContainer.encode(tenantId, forKey: .tenantId)
        
        var statusContainer = container.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        try statusContainer.encode(status, forKey: .status)
    }
}
