//
//  Interface.swift
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
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Core Data


//TODO: Make Interface a struct
/// Managed object subclass for the Interface entity.
struct Interface: Identifiable, Equatable {
    var id: Int64
    var name: String = ""
    var display: String?
    var label: String?
    var type: String?
    var enabled: Bool = false
    var mtu: String?
    var speed: String?
    var interfaceDescription: String?
    var created: Date?
    var lastUpdated: Date?
    var url: String?
    
    // Relationship IDs
    var deviceId: Int64?
    var deviceName: String?
    
    var connectedEndpointId: Int64?
    var connectedEndpointName: String?
    
    var lagId: Int64?
    var lagName: String?
    
    var bridgeId: Int64?
    var bridgeName: String?
    
    var parentId: Int64?
    var parentName: String?
    
    // Additional properties
    var poeMode: String?
    var duplex: String?
    var occupied: Bool = false
    
    init(id: Int64) {
        self.id = id
    }
}

//MARK: New actor for caching interfaces
actor InterfaceCache {
    static let shared = InterfaceCache()
    private var cache: [Int64: [Interface]] = [:]
    private var allInterfaces: Set<Int64> = []  // Track all interface IDs
    
    private init() {}
    
    func getInterfaces(forDeviceId deviceId: Int64) -> [Interface] {
        return cache[deviceId] ?? []
    }
    
    func getInterface(withId id: Int64) -> Interface? {
        for interfaces in cache.values {
            if let interface = interfaces.first(where: { $0.id == id }) {
                return interface
            }
        }
        return nil
    }
    
    func setInterfaces(_ interfaces: [Interface], forDeviceId deviceId: Int64) {
        cache[deviceId] = interfaces
        // Track all interface IDs
        interfaces.forEach { allInterfaces.insert($0.id) }
        
        Task { @MainActor in
            NotificationCenter.default.post(name: .interfacesDidUpdate, object: nil)
        }
    }
}

extension Notification.Name {
    static let interfacesDidUpdate = Notification.Name("interfacesDidUpdate")
}

