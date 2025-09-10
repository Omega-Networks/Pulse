//
//  StaticDevice.swift
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
import SwiftUI
import Foundation
import SwiftData

/**
 An actor that manages a cache of StaticDevice objects for different site IDs.
 It provides thread-safe access to the cache.
 */
actor StaticDeviceCache {
    static let shared = StaticDeviceCache()
    private var cache: [Int64: [StaticDevice]] = [:]
    
    private init() {}
    
    /**
     Retrieves the static devices for a given site ID.
     
     - Parameter siteId: The ID of the site to fetch devices for.
     - Returns: An array of StaticDevice objects for the specified site ID.
     */
    func getStaticDevices(forSiteId siteId: Int64) -> [StaticDevice] {
        
        print("")
        
        return cache[siteId] ?? []
    }
    
    /**
     Sets the static devices for a given site ID.
     
     - Parameters:
     - devices: An array of StaticDevice objects to cache.
     - siteId: The ID of the site these devices belong to.
     */
    func setStaticDevices(_ devices: [StaticDevice], forSiteId siteId: Int64) {
        cache[siteId] = devices
    }
    
    /**
     Clears all cached data.
     */
    func clearCache() {
        cache.removeAll()
    }
}

/**
 Represents a static device with various properties.
 This struct is Identifiable to be used in SwiftUI lists.
 */
struct StaticDevice: Identifiable, Equatable {
    var id: Int64 = 0
    var created: Date?
    var display: String?
    var lastUpdated: Date?
    var name: String?
    var rackPosition: Float?
    var face: String?
    var status: String?
    var frontPortCount: Int64?
    var rearPortCount: Int64?
    var deviceBayCount: Int64?
    
    var rackId: Int64?
    var rackName: String?
    
    //Relationship properties (not a SwiftData model so it is pulled directly from NetBox)
    var deviceRole: String?
    var deviceType: String?
    var site: String?
    
    init(id: Int64) {
        self.id = id
    }
    
    static func == (lhs: StaticDevice, rhs: StaticDevice) -> Bool {
        return lhs.id == rhs.id
    }
}

extension StaticDevice {
    func getDeviceBays() async -> [DeviceBay] {
        if deviceRole == "Shelf" {
            return await DeviceBayCache.shared.getDeviceBays(forDeviceId: id)
        }
        return []
    }
}

/**
 Represents the properties of a static device that can be encoded to and decoded from JSON.
 This struct conforms to Codable for easy serialization and deserialization.
 */
struct StaticDeviceProperties: Codable {
    let id: Int64?
    let name: String
    let display: String
    let url: String
    let created: Date?
    let lastUpdated: Date?
    let deviceTypeId: Int64
    let deviceTypeModel: String
    let deviceRoleId: Int64
    let deviceRoleName: String
    let rackId: Int64?
    let rackName: String?
    let rackPosition: Float?
    let siteId: Int64
    let siteName: String
    let frontPortCount: Int64
    let rearPortCount: Int64
    let deviceBayCount: Int64
    
    // MARK: - Coding Keys
    
    private enum CodingKeys: String, CodingKey {
        case id, name, display, url, created, site, rack, role, device_type
        case lastUpdated = "last_updated"
        case rackPosition = "position"
        case frontPortCount = "front_port_count"
        case rearPortCount = "rear_port_count"
        case deviceBayCount = "device_bay_count"
    }
    
    private enum RackKeys: String, CodingKey {
        case rackId = "id"
        case rackName = "name"
    }
    
    private enum SiteKeys: String, CodingKey {
        case siteId = "id"
        case siteName = "name"
    }
    
    private enum DeviceTypeKeys: String, CodingKey{
        case deviceTypeId = "id"
        case deviceTypeModel = "model"
    }
    
    private enum RoleKeys: String, CodingKey{
        case roleId = "id"
        case roleName = "name"
    }
    
    
    /**
     Initializes a StaticDeviceProperties instance from a decoder.
     
     - Parameter decoder: The decoder to read data from.
     - Throws: SwiftDataError.missingData if required fields are missing.
     */
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawDisplay = try? values.decode(String.self, forKey: .display)
        let rawURL = try? values.decode(String.self, forKey: .url)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date.self, forKey: .lastUpdated)
        let rawRackPosition = try? values.decode(Float.self, forKey: .rackPosition)
        let rawFrontPortCount = try? values.decode(Int64.self, forKey: .frontPortCount)
        let rawRearPortCount = try? values.decode(Int64.self, forKey: .rearPortCount)
        let rawDeviceBayCount = try? values.decode(Int64.self, forKey: .deviceBayCount)
        
        // Nested Site Attributes
        var rawSiteId: Int64 = 0
        var rawSiteName: String = ""
        
        // Nested Device Type Attributes
        var rawDeviceTypeId: Int64 = 0
        var rawDeviceTypeModel: String = ""
        // Nested Device Role Attributes
        var rawDeviceRoleId: Int64 = 0
        var rawDeviceRoleName: String = ""
        
        var rawRackId: Int64?
        var rawRackName: String?
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let siteContainer = try? codingContainer.nestedContainer(keyedBy: SiteKeys.self, forKey: .site) {
                rawSiteId = try! siteContainer.decode(Int64.self, forKey: .siteId)
            }
            if let siteContainer = try? codingContainer.nestedContainer(keyedBy: SiteKeys.self, forKey: .site) {
                rawSiteName = try! siteContainer.decode(String.self, forKey: .siteName)
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
              let display = rawDisplay
        else {
            let values = "id = \(rawId?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "display = \(rawDisplay?.description ?? "nil"), "
            + "url = \(rawURL?.description ?? "nil"), "
            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        /// Assign defaults for value with potential 'nil' return
        self.frontPortCount = rawFrontPortCount ?? 0
        self.rearPortCount = rawRearPortCount ?? 0
        self.deviceBayCount = rawDeviceBayCount ?? 0
        
        self.id = id
        self.name = name
        self.display = display
        self.url = url
        self.created = rawCreated
        self.lastUpdated = rawLastUpdated
        self.siteId = rawSiteId
        self.siteName = rawSiteName
        self.rackId = rawRackId
        self.rackName = rawRackName
        self.rackPosition = rawRackPosition
        
        self.deviceTypeId = rawDeviceTypeId
        self.deviceTypeModel = rawDeviceTypeModel
        self.deviceRoleId = rawDeviceRoleId
        self.deviceRoleName = rawDeviceRoleName
    }
    
    /**
     Encodes the StaticDeviceProperties instance to an encoder.
     
     - Parameter encoder: The encoder to write data to.
     - Throws: An error if encoding fails.
     */
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(name, forKey: .name)
        
        var roleContainer = container.nestedContainer(keyedBy: RoleKeys.self, forKey: .role)
        try roleContainer.encode(deviceRoleId, forKey: .roleId) // Use ID instead of name
        
        var deviceTypeContainer = container.nestedContainer(keyedBy: DeviceTypeKeys.self, forKey: .device_type)
        try deviceTypeContainer.encode(deviceTypeModel, forKey: .deviceTypeModel)
        
        var rackContainer = container.nestedContainer(keyedBy: RackKeys.self, forKey: .rack)
        try rackContainer.encodeIfPresent(rackId, forKey: .rackId)
        try rackContainer.encodeIfPresent(rackName, forKey: .rackName)
        try container.encodeIfPresent(rackPosition, forKey: .rackPosition)
        
        var siteContainer = container.nestedContainer(keyedBy: SiteKeys.self, forKey: .site)
        try siteContainer.encode(siteId, forKey: .siteId)
        try siteContainer.encode(siteName, forKey: .siteName)
    }
}
