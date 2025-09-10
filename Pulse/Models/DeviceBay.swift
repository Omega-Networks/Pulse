//
//  DeviceBay.swift
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
import Foundation
import SwiftData

actor DeviceBayCache {
    static let shared = DeviceBayCache()
    private var cache: [Int64: [DeviceBay]] = [:]
    
    private init() {}
    
    /**
     Retrieves the device bays for a given device ID (will always be a Shelf device).
     
     - Parameter deviceId: The ID of the shelf to fetch device bays for.
     - Returns: An array of DeviceBays objects for the specified device shelf..
     */
    func getDeviceBays(forDeviceId deviceId: Int64) -> [DeviceBay] {
        
        return cache[deviceId] ?? []
    }
    
    /**
     Sets the device bays for a given device ID (will always be a Shelf device).
     
     - Parameters:
     - devices: An array of DeviceBays objects to cache.
     - siteId: The ID of the shelf these device bays belong to.
     */
    func setDeviceBays(_ deviceBays: [DeviceBay], forDeviceId deviceId: Int64) {
        cache[deviceId] = deviceBays
    }
    
    /**
     Clears all cached data.
     */
    func clearCache() {
        cache.removeAll()
    }
}

struct DeviceBay: Identifiable, Equatable {
    var id: Int64 = 0
    var created: Date?
    var display: String?
    var lastUpdated: Date?
    var name: String?
    var label: String?
    
    //Properties for relationship with Device (SwiftData model)
    var deviceId: Int64?
    var deviceName: String?
    
    //Properties for relationship with Static Device (Shelf Device Role)
    var staticDeviceId: Int64?
    var staticDeviceName: String?
    
    init(id: Int64) {
        self.id = id
    }
    
//    Function to conform struct to Equatable
    static func == (lhs: DeviceBay, rhs: DeviceBay) -> Bool {
        return lhs.id == rhs.id
    }
}

struct DeviceBayProperties: Codable {
    let id: Int64?
    let name: String
    let display: String
    let url: String
    let created: Date?
    let lastUpdated: Date?
    let installedDeviceId: Int64?
    let installedDeviceName: String?
    let deviceId: Int64?
    let deviceName: String?
    
    
    // MARK: - Coding Keys
    
    private enum CodingKeys: String, CodingKey {
        case id, name, display, url, created, device
        case lastUpdated = "last_updated"
        case installedDevice = "installed_device"
    }
    
    // Parent of Device Bay (in this case, a Shelf)
    private enum DeviceKeys: String, CodingKey {
            case deviceId = "id"
            case deviceName = "name"
    }
    
    // Device installed in bay (Security Router, etc)
    private enum InstalledDeviceKeys: String, CodingKey {
            case installedDeviceId = "id"
            case installedDeviceName = "name"
    }
    
    /**
     Initializes a DeviceBayProperties instance from a decoder.
     
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
        
        // Nested Device (Shelf) Attributes
        var rawDeviceId: Int64 = 0
        var rawDeviceName: String = ""
        
        //Nested Installed Device (Security Router, etc) Attributes
        var rawInstalledDeviceId: Int64 = 0
        var rawInstalledDeviceName: String = ""
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let deviceContainer = try? codingContainer.nestedContainer(keyedBy: DeviceKeys.self, forKey: .device) {
                rawDeviceId = try deviceContainer.decode(Int64.self, forKey: .deviceId)
                rawDeviceName = try deviceContainer.decode(String.self, forKey: .deviceName)
            }
            
            if let installedDeviceContainer = try? codingContainer.nestedContainer(keyedBy: InstalledDeviceKeys.self, forKey: .installedDevice) {
                rawInstalledDeviceId = try installedDeviceContainer.decode(Int64.self, forKey: .installedDeviceId)
                rawInstalledDeviceName = try installedDeviceContainer.decode(String.self, forKey: .installedDeviceName)
            }
        }
        
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
        
        self.id = id
        self.name = name
        self.display = display
        self.url = url
        self.created = rawCreated
        self.lastUpdated = rawLastUpdated
        
        self.deviceId = rawDeviceId
        self.deviceName = rawDeviceName
        
        self.installedDeviceId = rawInstalledDeviceId
        self.installedDeviceName = rawInstalledDeviceName
    }
    
    /**
     Encodes the DeviceBayProperties instance to an encoder.
     
     - Parameter encoder: The encoder to write data to.
     - Throws: An error if encoding fails.
     */
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(name, forKey: .name)
        
        //Encoding static device (Shelf) attributes
        var deviceContainer = container.nestedContainer(keyedBy: DeviceKeys.self, forKey: .device)
        try deviceContainer.encode(deviceId, forKey: .deviceId)
        try deviceContainer.encode(deviceName, forKey: .deviceName)
        
        var installedDeviceContainer = container.nestedContainer(keyedBy: InstalledDeviceKeys.self, forKey: .installedDevice)
        try installedDeviceContainer.encode(installedDeviceId, forKey: .installedDeviceId)
        try installedDeviceContainer.encode(installedDeviceName, forKey: .installedDeviceName)
    }
}
