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

