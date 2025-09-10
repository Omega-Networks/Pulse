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


//MARK: - Bridge JSON body

///{
///            "id": 1,
///            "url": "https://netbox.example.com/api/dcim/interfaces/1/",
///            "display": "Example",
///            "device": {
///                "id": 1,
///                "url": "https://netbox.example.com/api/dcim/devices/1/",
///                "display": "Example",
///                "name": "Example"
///            },
///            "vdcs": [],
///            "module": null,
///            "name": "Example",
///            "label": "",
///            "type": {
///                "value": "1000base-t",
///                "label": "1000BASE-T (1GE)"
///            },
///            "enabled": true,
///            "parent": null,
///            "bridge": {
///                "id": 1,
///                "url": "https://netbox.example.com/api/dcim/interfaces/1/",
///                "display": "Example",
///                "device": {
///                    "id": 1,
///                    "url": "https://netbox.example.com/api/dcim/devices/1/",
///                    "display": "Example",
///                    "name": "Example"
///                },
///                "name": "Example",
///                "cable": null,
///                "_occupied": false
///            },
///            "lag": null,
///            "mtu": null,
///            "mac_address": null,
///            "speed": null,
///            "duplex": null,
///            "wwn": null,
///            "mgmt_only": false,
///            "description": "",
///            "mode": null,
///            "rf_role": null,
///            "rf_channel": null,
///            "poe_mode": null,
///            "poe_type": null,
///            "rf_channel_frequency": null,
///            "rf_channel_width": null,
///            "tx_power": null,
///            "untagged_vlan": null,
///            "tagged_vlans": [],
///            "mark_connected": false,
///            "cable": null,
///            "cable_end": "",
///            "wireless_link": null,
///            "link_peers": [],
///            "link_peers_type": null,
///            "wireless_lans": [],
///            "vrf": null,
///            "l2vpn_termination": null,
///            "connected_endpoints": null,
///            "connected_endpoints_type": null,
///            "connected_endpoints_reachable": null,
///            "tags": [],
///            "custom_fields": {},
///            "created": "2023-08-25T00:10:45.461029Z",
///            "last_updated": "2023-08-25T02:18:32.395192Z",
///            "count_ipaddresses": 0,
///            "count_fhrp_groups": 0,
///            "_occupied": false
///        }
///
///       {
///"id": 1,
///"url": "https://netbox.example.com/api/dcim/interfaces/1/",
///"display": "Example",
///"device": {
///    "id": 1,
///    "url": "https://netbox.example.com/api/dcim/devices/1/",
///    "display": "Example",
///    "name": "Example"
///},
///"vdcs": [],
///"module": null,
///"name": "Example",
///"label": "",
///"type": {
///    "value": "virtual",
///    "label": "Virtual"
///},
///"enabled": true,
///"parent": {
///    "id": 1,
///    "url": "https://netbox.example.com/api/dcim/interfaces/1/",
///    "display": Example",
///    "device": {
///        "id": 1,
///        "url": "https://netbox.example.com/api/dcim/devices/1/",
///        "display": "Example",
///        "name": "Example"
///    },
///    "name": "lan",
///    "cable": null,
///    "_occupied": false
///},
///"bridge": null,
///"lag": null,
///"mtu": null,
///"mac_address": null,
///"speed": null,
///"duplex": null,
///"wwn": null,
///"mgmt_only": false,
///"description": "",
///"mode": null,
///"rf_role": null,
///"rf_channel": null,
///"poe_mode": null,
///"poe_type": null,
///"rf_channel_frequency": null,
///"rf_channel_width": null,
///"tx_power": null,
///"untagged_vlan": null,
///"tagged_vlans": [],
///"mark_connected": false,
///"cable": null,
///"cable_end": "",
///"wireless_link": null,
///"link_peers": [],
///"link_peers_type": null,
///"wireless_lans": [],
///"vrf": null,
///"l2vpn_termination": null,
///"connected_endpoints": null,
///"connected_endpoints_type": null,
///"connected_endpoints_reachable": null,
///"tags": [],
///"custom_fields": {},
///"created": "2022-12-07T04:13:10.008514Z",
///"last_updated": "2022-12-23T00:27:33.585696Z",
///"count_ipaddresses": 0,
///"count_fhrp_groups": 0,
///"_occupied": false
///}

/// A struct encapsulating the properties of a Interface.
struct InterfaceProperties: Codable {

    // MARK: Codable
    
    //TODO: Determine if POE type is neccessary
    
    private enum CodingKeys: String, CodingKey {
        case id, name, display, url, created, device, type, label, enabled, mtu, speed, description
        case lastUpdated = "last_updated"
        case connectedEndpoint = "connected_endpoints"
        case lag = "lag"
        case bridge = "bridge"
        case parent = "parent"
        case poeMode = "poe_mode"
    }
    
    private enum DeviceKeys: String, CodingKey {
        case deviceId = "id"
        case deviceName = "name"
    }
    
    private enum TypeKeys: String, CodingKey {
        case type = "value"
    }
    
    private enum ConnectedEndpointKeys: String, CodingKey {
        case connectedEndpoints
        case id
        case name
    }
    
    private enum LagKeys: String, CodingKey {
        case id
        case name
    }
    
    private enum BridgeKeys: String, CodingKey {
        case id
        case name
    }
    
    private enum ParentKeys: String, CodingKey {
        case id
        case name
    }
    
    private enum PoeModeKeys: String, CodingKey {
        case value = "value"
    }
    
    let id: Int64
    let name: String
    let display: String
    let created: Date
    let lastUpdated: Date
    let url: String
    let type: String
    let label: String
    let enabled: Bool
    let mtu: String
    let speed: String
    let interfaceDescription: String

    let deviceId: Int64
    let deviceName: String
    
    let connectedEndpointId: Int64?
    let connectedEndpointName: String?
    
    let lagId: Int64?
    let lagName: String?
    
    let bridgeId: Int64?
    let bridgeName: String?
    
    let parentId: Int64?
    let parentName: String?
    
    let poeMode: String?
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawDisplay = try? values.decode(String.self, forKey: .display)
        let rawCreated = try? values.decode(Date.self, forKey: .created)
        let rawLastUpdated = try? values.decode(Date.self, forKey: .lastUpdated)
        let rawUrl = try? values.decode(String.self, forKey: .url)
        let rawLabel = try? values.decode(String?.self, forKey: .label)
        let rawEnabled = try values.decode(Bool.self, forKey: .enabled)
        let rawMtu = try? values.decode(String?.self, forKey: .mtu)
        let rawSpeed = try? values.decode(String?.self, forKey: .speed)
        let rawDescription = try? values.decode(String?.self, forKey: .description)
        
        // Nested Device Attributes
        var rawDeviceId: Int64?
        var rawDeviceName: String?
        
        // Nested Type Attributes
        var rawType: String?
        
        // Nested Interface Attributes
        var rawConnectedEndpointId: Int64?
        var rawConnectedEndpointName: String?
        
        var rawLagId: Int64?
        var rawLagName: String?
        
        //Bridge, parent Interface attributes
        var rawBridgeId: Int64?
        var rawBridgeName: String?
        
        var rawParentId: Int64?
        var rawParentName: String?
        
        var rawPoeMode: String?
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let deviceContainer = try? codingContainer.nestedContainer(keyedBy: DeviceKeys.self, forKey: .device) {
                rawDeviceId = try? deviceContainer.decode(Int64.self, forKey: .deviceId)
                rawDeviceName = try? deviceContainer.decode(String.self, forKey: .deviceName)
                
            }
            if let typeContainer = try? codingContainer.nestedContainer(keyedBy: TypeKeys.self, forKey: .type) {
                rawType = try? typeContainer.decode(String.self, forKey: .type)
            }
            if var connectedEndpointsContainer = try? values.nestedUnkeyedContainer(forKey: .connectedEndpoint) {
                while !connectedEndpointsContainer.isAtEnd {
                    let endpointContainer = try connectedEndpointsContainer.nestedContainer(keyedBy: ConnectedEndpointKeys.self)
                    rawConnectedEndpointId = try endpointContainer.decode(Int64.self, forKey: .id)
                    rawConnectedEndpointName = try endpointContainer.decode(String.self, forKey: .name)
                    break // If you only want the id from the first dictionary in the array
                }
            } else {
                rawConnectedEndpointId = nil
                rawConnectedEndpointName = nil
            }
            if let lagContainer = try? values.nestedContainer(keyedBy: LagKeys.self, forKey: .lag) {
                rawLagId = try? lagContainer.decode(Int64.self, forKey: .id)
                rawLagName = try? lagContainer.decode(String.self, forKey: .name)
            }
            if let bridgeContainer = try? values.nestedContainer(keyedBy: BridgeKeys.self, forKey: .bridge) {
                rawBridgeId = try? bridgeContainer.decode(Int64.self, forKey: .id)
                rawBridgeName = try? bridgeContainer.decode(String.self, forKey: .name)
            }
            if let parentContainer = try? values.nestedContainer(keyedBy: ParentKeys.self, forKey: .parent) {
                rawParentId = try? parentContainer.decode(Int64.self, forKey: .id)
                rawParentName = try? parentContainer.decode(String.self, forKey: .name)
            }
            if let poeModeContainer = try? values.nestedContainer(keyedBy: PoeModeKeys.self, forKey: .poeMode) {
                rawPoeMode = try? poeModeContainer.decode(String.self, forKey: .value)
            }
            
        }

        // Ignore records with missing data.
        guard let id = rawId,
              let name = rawName,
              let display = rawDisplay,
              let created = rawCreated,
              let lastUpdated = rawLastUpdated,
              let url = rawUrl
        else {
            let values = "id = \(rawId?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "created = \(rawCreated?.description ?? "nil"), "
            + "lastUpdated = \(rawLastUpdated?.description ?? "nil"), "
            + "display = \(rawDisplay?.description ?? "nil"), "
            + "url = \(rawUrl?.description ?? "nil"), "
            + "label = \(rawLabel?.description  ?? "nil"), "
            + "enabled = \(rawEnabled.description), "
            + "mtu = \(rawMtu?.description  ?? "nil"), "
            + "speed = \(rawSpeed?.description  ?? "nil"), "
            + "description = \(rawDescription?.description  ?? "nil") "

            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored: \(values)")

            throw SwiftDataError.missingData
        }
        
        let label = rawLabel ?? ""
        let enabled = rawEnabled
        let mtu = rawMtu ?? ""
        let speed = rawSpeed ?? ""
        let description = rawDescription ?? ""
        
        /// Assign defaults for value with potential 'nil' return
        let deviceId = rawDeviceId
        let deviceName = rawDeviceName ?? ""
        
        /// Assign defaults for value with potential 'nil' return
        let type = rawType
        
        let connectedEndpointId = rawConnectedEndpointId ?? 0
        let connectedEndpointName = rawConnectedEndpointName ?? ""
        
        let lagId = rawLagId ?? 0
        let lagName = rawLagName ?? ""
        
        let bridgeId = rawBridgeId ?? 0
        let bridgeName = rawBridgeName ?? ""
        
        let parentId = rawParentId ?? 0
        let parentName = rawParentName ?? ""
        
        let poeMode = rawPoeMode ?? ""
        
        self.id = id
        self.name = name
        self.created = created
        self.lastUpdated = lastUpdated
        self.display = display
        self.url = url
        self.type = type ?? ""
        self.label = label
        self.enabled = enabled
        self.mtu = mtu
        self.speed = speed
        self.interfaceDescription = description
        
        self.deviceId = deviceId ?? 0
        self.deviceName = deviceName
        
        self.connectedEndpointId = connectedEndpointId
        self.connectedEndpointName = connectedEndpointName
        
        self.lagId = lagId
        self.lagName = lagName
        
        self.bridgeId = bridgeId
        self.bridgeName = bridgeName
        
        self.parentId = parentId
        self.parentName = parentName
        
        self.poeMode = poeMode
        
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(display, forKey: .display)
        try container.encode(created, forKey: .created)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(url, forKey: .url)
        try container.encode(type, forKey: .type)
        try container.encode(label, forKey: .label)
        try container.encode(enabled, forKey: .enabled)
        
        // Encode speed only if it's a valid integer
        if let speed = Int(speed) {
            try container.encode(speed, forKey: .speed)
        }
        
        // Encode mtu only if it's a valid integer
        if let mtu = Int(mtu) {
            try container.encode(mtu, forKey: .mtu)
        }
        
        try container.encode(interfaceDescription, forKey: .description)
        try container.encode(deviceId, forKey: .device)
        try container.encode(deviceName, forKey: .device)
        
        if let connectedEndpointId = connectedEndpointId {
            try container.encode(connectedEndpointId, forKey: .connectedEndpoint)
            try container.encode(connectedEndpointName, forKey: .connectedEndpoint)
        }
        
        // Encode lagId only if it's not 0
        if lagId != 0 {
            try container.encode(lagId, forKey: .lag)
            try container.encode(lagName, forKey: .lag)
        }
        
        // Encode bridgeId only if it's not 0
        if bridgeId != 0 {
            try container.encode(bridgeId, forKey: .bridge)
            try container.encode(bridgeName, forKey: .bridge)
        }
        
        if let parentId = parentId {
            try container.encode(parentId, forKey: .parent)
            try container.encode(parentName, forKey: .parent)
        }
        
        if let poeMode = poeMode {
            try container.encode(poeMode, forKey: .poeMode)
        }
    }
    
    // The keys must have the same name as the attributes of the Interface entity.
    var dictionaryValue: [String: Any] {
        [
            "id": id,
            "name": name,
            "created": created,
            "lastUpdated": lastUpdated,
            "display": display,
            "url": url,
            "type": type,
            "label": label,
            "enabled": enabled,
            "mtu": mtu,
            "speed": speed,
            "description": interfaceDescription
        ]
    }
}
