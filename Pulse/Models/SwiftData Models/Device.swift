//
//  Device.swift
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
import SwiftUI

// MARK: - Core Data

/// Managed object subclass for the Device entity.

@Model
final class Device {
    @Attribute(.unique) var id: Int64
    var created: Date?
    var display: String?
    var lastUpdated: Date?
    var name: String?
    var primaryIP: String?
    var serial: String?
    var url: String?
    var x: Double?
    var y: Double?
    var zabbixId: Int64 = 0
    var zabbixInstance: Int64?
    var status: String?
    
    // --- NEW PROPERTY ---
    //Property for storing camera stream URL (only applies to cameras)
    @Attribute(.allowsCloudEncryption)
    var cameraStreamURL: String?
    
    //Property to determine rack position
    var rackPosition: Float?
    
    // MARK: Device Model Relationships
    
    //One-To-Many
    @Relationship(deleteRule: .cascade, inverse: \Event.device)
    var events: [Event]?
    
    
    //Many-To-One
    var site: Site?
    var rack: Rack?
    var deviceRole: DeviceRole?
    var deviceType: DeviceType?
    
    
    init(id: Int64) {
         self.id = id
         self.localX = x ?? 150
         self.localY = y ?? 150
     }
    
    var localX: Double = 0
    var localY: Double = 0
}


extension Device {
   // MARK: - Computed Properties
    
    // --- NEW HELPER PROPERTY ---
    var supportsCameraStream: Bool {
        return deviceRole?.id == 11 || deviceRole?.id == 35 // Camera or Edge Node
    }
   
   /// Device symbol based on its role
   var symbolName: String {
       switch deviceRole?.name {
       case "Access Switch", "Distribution Switch", "Management Switch":
           return "custom.switch"
       case "Core Switch":
           return "custom.coreswitch"
       case "Security Router", "Core Firewall", "Management Firewall":
           return "custom.securityrouter"
       case "Access Point", "Wireless Bridge":
           return "custom.wirelessap"
       case "Camera":
           return "custom.camera"
       case "Router", "Terminal Server", "Provider Edge":
           return "custom.router"
       case "Certificate":
           return "custom.scroll.fill"
       case "Digital Display":
           return "custom.inset.filled.tv"
       case "Edge Node":
           return "custom.externaldrive.fill"
       default:
           return "custom.questionmark"
       }
   }
   
   // MARK: - Event States
   
   /// Active events that are not suppressed or resolved
   private var activeEvents: [Event] {
       events?.filter {
           $0.rClock == "0" && $0.suppressed == "0"
       } ?? []
   }
   
   /// Active events that have not been acknowledged
   private var unacknowledgedEvents: [Event] {
       activeEvents.filter {
           $0.acknowledged == "0"
       }
   }
   
   /// Current highest severity level among active events
   var highestSeverity: Int {
       guard zabbixId != 0 else { return -2 }
       guard !activeEvents.isEmpty else {
           return zabbixId != 0 ? -1 : -2
       }
       return activeEvents.compactMap { Int($0.severity) }.max() ?? -1
   }
   
   /// Current highest severity level among unacknowledged events
   var highestUnacknowledgedSeverity: Int {
       guard zabbixId != 0 else { return -1 }
       guard !unacknowledgedEvents.isEmpty else {
           return -1
       }
       return unacknowledgedEvents.compactMap { Int($0.severity) }.max() ?? -1
   }
   
    /// Count of active events grouped by severity level
    var eventCountBySeverity: [String: Int] {
        guard let events = events else { return [:] }
        return events
            .filter { $0.rClock == "0" }  // Only count events in active state
            .reduce(into: [:]) { counts, event in
                counts[event.severity, default: 0] += 1
            }
    }
   
   // MARK: - Visual Properties
   
   /// Color representation of the highest severity
   var severityColor: Color {
       switch highestSeverity {
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
   
   /// Color representation of the highest unacknowledged severity
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
   
   // MARK: - Helper Methods
   
   /// Converts hex color string to SwiftUI Color
   private func color(fromHex hex: String) -> Color {
       var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
       hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
       
       var rgb: UInt64 = 0
       Scanner(string: hexSanitized).scanHexInt64(&rgb)
       
       let r = Double((rgb & 0xFF0000) >> 16) / 255.0
       let g = Double((rgb & 0x00FF00) >> 8) / 255.0
       let b = Double(rgb & 0x0000FF) / 255.0
       
       return Color(red: r, green: g, blue: b)
   }
}

//MARK: API request for device as a reference
//{
//    "id": 1,
//    "url": "https://netbox.example.com/api/dcim/devices/1/",
//    "display": "Museum-SW01",
//    "name": "Museum-SW01",
//    "device_type": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/device-types/1/",
//        "display": "FortiSwitch 224D-FPOE",
//        "manufacturer": {
//            "id": 1,
//            "url": "https://netbox.example.com/api/dcim/manufacturers/1/",
//            "display": "Fortinet",
//            "name": "Fortinet",
//            "slug": "fortinet"
//        },
//        "model": "FortiSwitch 224D-FPOE",
//        "slug": "fortiswitch-224d-fpoe"
//    },
//    "device_role": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/device-roles/1/",
//        "display": "Access Switch",
//        "name": "Access Switch",
//        "slug": "access-switch"
//    },
//    "tenant": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/tenancy/tenants/1/",
//        "display": "Example",
//        "name": "Example",
//        "slug": "Example"
//    },
//    "platform": null,
//    "serial": "",
//    "asset_tag": null,
//    "site": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/sites/1/",
//        "display": "001 - Museum",
//        "name": "001 - Museum",
//        "slug": "001-museum"
//    },
//    "location": {
//        "id": 23,
//        "url": "https://netbox.example.com/api/dcim/locations/1/",
//        "display": "00 - Ground Floor",
//        "name": "00 - Ground Floor",
//        "slug": "00-ground-floor",
//        "_depth": 0
//    },
//    "rack": {
//        "id": 43,
//        "url": "https://netbox.example.com/api/dcim/racks/1/",
//        "display": "Rack G.1.1",
//        "name": "Rack G.1.1"
//    },
//    "position": 5.0,
//    "face": {
//        "value": "front",
//        "label": "Front"
//    },
//    "parent_device": null,
//    "status": {
//        "value": "active",
//        "label": "Active"
//    },
//    "airflow": null,
//    "primary_ip": null,
//    "primary_ip4": null,
//    "primary_ip6": null,
//    "cluster": null,
//    "virtual_chassis": null,
//    "vc_position": null,
//    "vc_priority": null,
//    "description": "",
//    "comments": "",
//    "local_context_data": null,
//    "tags": [],
//    "custom_fields": {
//        "coordinate_x": 0,
//        "coordinate_y": 0,
//        "zabbix_groups": null,
//        "zabbix_id": null,
//        "zabbix_instance": null,
//        "zabbix_templates": null
//    },
//    "config_context": {},
//    "created": "2022-11-10T00:24:29.847378Z",
//    "last_updated": "2022-11-13T21:10:13.212048Z"
//}

//MARK: For fetching Device from NetBox
/// A struct encapsulating the properties of a Device.
struct DeviceProperties: Codable {

    // MARK: Decodable
    
    private enum CodingKeys: String, CodingKey {
        case id, name, display, url, created, site, custom_fields, serial, primary_ip, role, device_type, status, rack
        case lastUpdated = "last_updated"
        case rackPosition = "position"
    }
    
    private enum DeviceTypeKeys: String, CodingKey{
        case deviceTypeId = "id"
        case deviceTypeModel = "model"
    }
    
    private enum RoleKeys: String, CodingKey{
        case roleId = "id"
        case roleName = "name"
    }
    
    private enum PrimaryIPKeys: String, CodingKey{
        case primaryIP = "address"
    }
    
    private enum SiteKeys: String, CodingKey {
        case siteId = "id"
        case siteName = "name"
    }
    
    private enum CustomFieldKeys: String, CodingKey {
        case x = "coordinate_x"
        case y = "coordinate_y"
        case zabbixId = "zabbix_id"
        case zabbixInstance = "zabbix_instance"
    }
    
    private enum StatusKeys: String, CodingKey {
           case status = "value"
    }
    
    private enum RackKeys: String, CodingKey {
           case rackId = "id"
           case rackName = "name"
    }
        
    var id: Int64?
    let name: String
    let display: String
    let url: String
    let created: Date?
    let lastUpdated: Date?
    let primaryIP: String
    let serial: String

    let siteId: Int64
    let siteName: String
    
    let rackPosition: Float?
    
    let x: Double
    let y: Double
    let zabbixId: Int64
    let zabbixInstance: Int64
    
    var deviceTypeId: Int64
    var deviceTypeModel: String
    var deviceRoleId: Int64
    var deviceRoleName: String
    let status: String // This will hold only the value, not the label
    
    let rackId: Int64?
    let rackName: String?
    
    /**
     Initialisation body for fetching a Device object from NetBox and decoding its properties from the returned JSON response.
     */
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawDisplay = try? values.decode(String.self, forKey: .display)
        let rawURL = try? values.decode(String.self, forKey: .url)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date.self, forKey: .lastUpdated)
        let rawSerial = try? values.decode(String.self, forKey: .serial)
        let rawRackPosition = try? values.decode(Float.self, forKey: .rackPosition)
        
        // Nested Site Attributes
        var rawSiteId: Int64 = 0
        var rawSiteName: String = ""
        // Nested Custom Field Attributes
        var rawX: Double?
        var rawY: Double?
        var rawZabbixId: Int64?
        var rawZabbixInstance: Int64?
        // Nested Primary IP attributes
        var rawPrimaryIP: String?
        
        // Nested Device Type Attributes
        var rawDeviceTypeId: Int64 = 0
        var rawDeviceTypeModel: String = ""
        // Nested Device Role Attributes
        var rawDeviceRoleId: Int64 = 0
        var rawDeviceRoleName: String = ""
        var rawStatus: String?
        
        var rawRackId: Int64?
        var rawRackName: String?
        
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let siteContainer = try? codingContainer.nestedContainer(keyedBy: SiteKeys.self, forKey: .site) {
                rawSiteId = try! siteContainer.decode(Int64.self, forKey: .siteId)
            }
            if let siteContainer = try? codingContainer.nestedContainer(keyedBy: SiteKeys.self, forKey: .site) {
                rawSiteName = try! siteContainer.decode(String.self, forKey: .siteName)
            }
            if let customFieldsContainer = try? codingContainer.nestedContainer(keyedBy: CustomFieldKeys.self, forKey: .custom_fields) {
                rawX = try? customFieldsContainer.decode(Double.self, forKey: .x)
            }
            if let customFieldsContainer = try? codingContainer.nestedContainer(keyedBy: CustomFieldKeys.self, forKey: .custom_fields) {
                rawY = try? customFieldsContainer.decode(Double.self, forKey: .y)
            }
            if let customFieldsContainer = try? codingContainer.nestedContainer(keyedBy: CustomFieldKeys.self, forKey: .custom_fields) {
                rawZabbixId = try? customFieldsContainer.decode(Int64.self, forKey: .zabbixId)
            }
            if let customFieldsContainer = try? codingContainer.nestedContainer(keyedBy: CustomFieldKeys.self, forKey: .custom_fields) {
                rawZabbixInstance = try? customFieldsContainer.decode(Int64.self, forKey: .zabbixInstance)
            }
            if let primaryIPContainer = try? codingContainer.nestedContainer(keyedBy: PrimaryIPKeys.self, forKey: .primary_ip) {
                rawPrimaryIP = try? primaryIPContainer.decode(String.self, forKey: .primaryIP)
            }
            if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
                if let groupContainer = try? codingContainer.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
                    rawStatus = try? groupContainer.decode(String.self, forKey: .status)
                }
            }
            
            if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
                if let deviceTypeContainer = try? codingContainer.nestedContainer(keyedBy: DeviceTypeKeys.self, forKey: .device_type) {
                    rawDeviceTypeId = try! deviceTypeContainer.decode(Int64.self, forKey: .deviceTypeId)
                    rawDeviceTypeModel = try! deviceTypeContainer.decode(String.self, forKey: .deviceTypeModel)
                }
                if let deviceRoleContainer = try? codingContainer.nestedContainer(keyedBy: RoleKeys.self, forKey: .role) {
                    rawDeviceRoleId = try! deviceRoleContainer.decode(Int64.self, forKey: .roleId)
                    rawDeviceRoleName = try! deviceRoleContainer.decode(String.self, forKey: .roleName)
                }
            }
            
            if let rackContainer = try? values.nestedContainer(keyedBy: RackKeys.self, forKey: .rack) {
                rawRackId = try? rackContainer.decode(Int64.self, forKey: .rackId)
                rawRackName = try? rackContainer.decode(String.self, forKey: .rackName)
            }
        }

        // Ignore records with missing data.
        guard let id = rawId,
              let name = rawName,
              let url = rawURL,
              let created = rawCreated,
              let lastUpdated = rawLastUpdated,
              let display = rawDisplay
        else {
            let values = "id = \(rawId?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "created = \(rawCreated?.description ?? "nil"), "
            + "lastUpdated = \(rawLastUpdated?.description ?? "nil"), "
            + "display = \(rawDisplay?.description ?? "nil"), "
            + "url = \(rawURL?.description ?? "nil"), "
            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored: \(values)")

            throw SwiftDataError.missingData
        }
        
        /// Assign defaults for value with potential 'nil' return
        let siteId = rawSiteId
        let siteName = rawSiteName
        let x = rawX ?? 0
        let y = rawY ?? 0
        let zabbixId = rawZabbixId ?? 0
        let zabbixInstance = rawZabbixInstance ?? 0
        let primaryIP = rawPrimaryIP ?? "Unknown"
        let serial = rawSerial ?? "Unknown"
        let status = rawStatus ?? ""
        
        self.deviceTypeId = rawDeviceTypeId
        self.deviceTypeModel = rawDeviceTypeModel
        self.deviceRoleId = rawDeviceRoleId
        self.deviceRoleName = rawDeviceRoleName
        
        self.id = id
        self.name = name
        self.created = created
        self.lastUpdated = lastUpdated
        self.status = status
        self.display = display
        self.url = url
        self.primaryIP = primaryIP
        self.serial = serial
        
        self.siteId = siteId
        self.siteName = siteName
        self.x = x
        self.y = y
        self.zabbixId = zabbixId
        self.zabbixInstance = zabbixInstance
        
        self.rackId = rawRackId
        self.rackName = rawRackName
        
        self.rackPosition = rawRackPosition
    }
    
    /**
     Initialisation body for either creating or updating a Device, and pushing the information to NetBox.
     */
    init(id: Int64? = nil, name: String, display: String, status: String, deviceType: String, primaryIP: String, serial: String, siteId: Int64, siteName: String, x: Double, y: Double, zabbixId: Int64, zabbixInstance: Int64, deviceRoleId: Int64, deviceRoleName: String, deviceTypeId: Int64, deviceTypeModel: String, rackId: Int64?, rackName: String?, rackPosition: Float?) {
        self.id = id
        self.created = nil
        self.lastUpdated = nil
        self.name = name
        self.display = display
        self.status = status
        self.url = ""
        self.primaryIP = primaryIP
        self.serial = serial
        self.siteId = siteId
        self.siteName = siteName
        self.x = x
        self.y = y
        self.zabbixId = zabbixId
        self.zabbixInstance = zabbixInstance
        self.deviceRoleId = deviceRoleId
        self.deviceRoleName = deviceRoleName
        self.deviceTypeId = deviceRoleId
        self.deviceTypeModel = deviceTypeModel
        self.rackId = rackId
        self.rackName = rackName
        self.rackPosition = rackPosition
    }
    
    //MARK: Encodable
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(display, forKey: .display)
        try container.encode(primaryIP, forKey: .primary_ip)
        try container.encode(serial, forKey: .serial)
        try container.encode(rackPosition, forKey: .rackPosition)
        
        var siteContainer = container.nestedContainer(keyedBy: SiteKeys.self, forKey: .site)
        try siteContainer.encode(siteId, forKey: .siteId)
        try siteContainer.encode(siteName, forKey: .siteName)
        
        var customFieldsContainer = container.nestedContainer(keyedBy: CustomFieldKeys.self, forKey: .custom_fields)
        try customFieldsContainer.encode(x, forKey: .x)
        try customFieldsContainer.encode(y, forKey: .y)
        try customFieldsContainer.encode(zabbixId, forKey: .zabbixId)
        try customFieldsContainer.encode(zabbixInstance, forKey: .zabbixInstance)
        
        //TODO: Find a way to also POST the device role's id and type
        var roleContainer = container.nestedContainer(keyedBy: RoleKeys.self, forKey: .role)
        try roleContainer.encode(deviceRoleId, forKey: .roleId) // Use ID instead of name
        
        var deviceTypeContainer = container.nestedContainer(keyedBy: DeviceTypeKeys.self, forKey: .device_type)
        try deviceTypeContainer.encode(deviceTypeModel, forKey: .deviceTypeModel)
        
        var statusContainer = container.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        try statusContainer.encode(status, forKey: .status)
        
        var rackContainer = container.nestedContainer(keyedBy: RackKeys.self, forKey: .rack)
        try rackContainer.encode(rackId, forKey: .rackId)
        try rackContainer.encode(rackName, forKey: .rackName)
        
    }
}

