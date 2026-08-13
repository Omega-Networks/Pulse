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

