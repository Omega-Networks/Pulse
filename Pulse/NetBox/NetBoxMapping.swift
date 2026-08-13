//
//  NetBoxMapping.swift
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
import NetBoxAPI
import OpenAPIRuntime

/// Sendable snapshots of a NetBox object after mapping off the generated types.
/// Models stay in the store; these cross the decode → upsert boundary.
enum NetBoxRecord {
    struct TenantGroup: Sendable, Equatable {
        var id: Int64
        var name: String
        var created: Date?
        var lastUpdated: Date?
    }

    struct Tenant: Sendable, Equatable {
        var id: Int64
        var name: String
        var created: Date?
        var lastUpdated: Date?
        var groupID: Int64?
    }

    struct Region: Sendable, Equatable {
        var id: Int64
        var name: String
        var created: Date?
        var lastUpdated: Date?
        var siteCount: Int64
        var parentID: Int64?
    }

    struct DeviceRole: Sendable, Equatable {
        var id: Int64
        var name: String
        var created: Date?
        var lastUpdated: Date?
        var colour: String?
    }

    struct DeviceType: Sendable, Equatable {
        var id: Int64
        var model: String
        var created: Date?
        var lastUpdated: Date?
        var uHeight: Float?
        var manufacturerID: Int64
    }

    struct SiteGroup: Sendable, Equatable {
        var id: Int64
        var name: String
        var created: Date?
        var lastUpdated: Date?
        var parentID: Int64?
    }

    struct Site: Sendable, Equatable {
        var id: Int64
        var name: String
        var display: String?
        var url: String?
        var created: Date?
        var lastUpdated: Date?
        var latitude: Double?
        var longitude: Double?
        var physicalAddress: String?
        var shippingAddress: String?
        var status: String?
        var deviceCount: Int64
        var regionID: Int64?
        var groupID: Int64?
        var tenantID: Int64?
    }

    struct Rack: Sendable, Equatable {
        var id: Int64
        var name: String?
        var display: String?
        var url: String?
        var created: Date?
        var lastUpdated: Date?
        var uHeight: Int64?
        var startingUnit: Int64
        var deviceCount: Int64?
        var status: String?
        var formFactor: String?
        var siteID: Int64?
    }

    struct Device: Sendable, Equatable {
        var id: Int64
        var name: String?
        var display: String?
        var url: String?
        var created: Date?
        var lastUpdated: Date?
        var serial: String
        var primaryIP: String
        var status: String
        var rackPosition: Float?
        var x: Double
        var y: Double
        var zabbixID: Int64
        var zabbixInstance: Int64
        var siteID: Int64
        var roleID: Int64
        var typeID: Int64
        var rackID: Int64?
    }

    struct Service: Sendable, Equatable {
        var id: Int64
        var name: String?
        var display: String?
        var url: String?
        var serviceDescription: String?
        var protocolValue: String?
        var protocolLabel: String?
        var ports: [Int]
        var ipAddresses: [String]
        var parentObjectType: String
        var parentObjectID: Int64
        var parentName: String?
    }

    struct Interface: Sendable, Equatable {
        var id: Int64
        var name: String
        var display: String?
        var url: String?
        var created: Date?
        var lastUpdated: Date?
        var type: String?
        var label: String?
        var enabled: Bool
        var mtu: String
        var speed: String
        var interfaceDescription: String
        var poeMode: String?
        var deviceID: Int64?
        var deviceName: String?
        var connectedEndpointID: Int64?
        var connectedEndpointName: String?
        var lagID: Int64?
        var lagName: String?
        var bridgeID: Int64?
        var bridgeName: String?
        var parentID: Int64?
        var parentName: String?
    }

    struct StaticDevice: Sendable, Equatable {
        var id: Int64
        var name: String?
        var display: String?
        var created: Date?
        var lastUpdated: Date?
        var rackPosition: Float?
        var frontPortCount: Int64
        var rearPortCount: Int64
        var deviceBayCount: Int64
        var rackID: Int64?
        var rackName: String?
        var roleName: String?
        var typeModel: String?
        var siteName: String?
    }

    struct DeviceBay: Sendable, Equatable {
        var id: Int64
        var name: String?
        var display: String?
        var created: Date?
        var lastUpdated: Date?
        var shelfID: Int64?
        var shelfName: String?
        var installedDeviceID: Int64?
        var installedDeviceName: String?
    }
}

/// Keyed helpers for list ingest. Generated types demand unused counts and
/// nested Brief* shapes the lab JSON often omits; we only read what we store.
enum NetBoxIngest {
    enum IDKey: String, CodingKey { case id }
    enum ValueKey: String, CodingKey { case value }
    enum AddressKey: String, CodingKey { case address }
    enum PulseFieldKey: String, CodingKey {
        case coordinate_x, coordinate_y, zabbix_id, zabbix_instance
    }

    enum NameKey: String, CodingKey { case id, name }

    static func nestedID<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) throws -> Int64? {
        guard container.contains(key), try container.decodeNil(forKey: key) == false else {
            return nil
        }
        let nested = try container.nestedContainer(keyedBy: IDKey.self, forKey: key)
        return try nested.decode(Int64.self, forKey: .id)
    }

    static func nestedNamed<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) throws -> (id: Int64?, name: String?) {
        guard container.contains(key), try container.decodeNil(forKey: key) == false else {
            return (nil, nil)
        }
        let nested = try container.nestedContainer(keyedBy: NameKey.self, forKey: key)
        return (
            try nested.decodeIfPresent(Int64.self, forKey: .id),
            try nested.decodeIfPresent(String.self, forKey: .name)
        )
    }

    static func firstNamed<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) throws -> (id: Int64?, name: String?) {
        guard container.contains(key), try container.decodeNil(forKey: key) == false else {
            return (nil, nil)
        }
        var array = try container.nestedUnkeyedContainer(forKey: key)
        guard !array.isAtEnd else { return (nil, nil) }
        let nested = try array.nestedContainer(keyedBy: NameKey.self)
        return (
            try nested.decodeIfPresent(Int64.self, forKey: .id),
            try nested.decodeIfPresent(String.self, forKey: .name)
        )
    }

    static func flexibleString<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) -> String {
        if let value = try? container.decodeNil(forKey: key), value { return "" }
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Double.self, forKey: key) { return String(Int64(value)) }
        return ""
    }

    static func choiceValue<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) throws -> String? {
        guard container.contains(key), try container.decodeNil(forKey: key) == false else {
            return nil
        }
        let nested = try container.nestedContainer(keyedBy: ValueKey.self, forKey: key)
        return try nested.decodeIfPresent(String.self, forKey: .value)
    }

    static func address<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) throws -> String? {
        guard container.contains(key), try container.decodeNil(forKey: key) == false else {
            return nil
        }
        let nested = try container.nestedContainer(keyedBy: AddressKey.self, forKey: key)
        return try nested.decodeIfPresent(String.self, forKey: .address)
    }

    static func pulseFields<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) throws -> (x: Double, y: Double, zabbixID: Int64, zabbixInstance: Int64) {
        guard container.contains(key), try container.decodeNil(forKey: key) == false else {
            return (0, 0, 0, 0)
        }
        let fields = try container.nestedContainer(keyedBy: PulseFieldKey.self, forKey: key)
        return (
            x: flexibleDouble(fields, .coordinate_x) ?? 0,
            y: flexibleDouble(fields, .coordinate_y) ?? 0,
            zabbixID: flexibleInt64(fields, .zabbix_id) ?? 0,
            zabbixInstance: flexibleInt64(fields, .zabbix_instance) ?? 0
        )
    }

    static func flexibleDouble<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) -> Double? {
        if let value = try? container.decodeNil(forKey: key), value { return nil }
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(Int64.self, forKey: key) { return Double(value) }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    static func flexibleInt64<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) -> Int64? {
        if let value = try? container.decodeNil(forKey: key), value { return nil }
        if let value = try? container.decode(Int64.self, forKey: key) { return value }
        if let value = try? container.decode(Double.self, forKey: key) { return Int64(value) }
        if let value = try? container.decode(String.self, forKey: key) { return Int64(value) }
        return nil
    }
}

extension NetBoxRecord.Tenant: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, created, group
        case lastUpdated = "last_updated"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        groupID = try NetBoxIngest.nestedID(container, .group)
    }
}

extension NetBoxRecord.Site: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, display, url, created, latitude, longitude, status, region, group, tenant
        case lastUpdated = "last_updated"
        case physicalAddress = "physical_address"
        case shippingAddress = "shipping_address"
        case deviceCount = "device_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        physicalAddress = try container.decodeIfPresent(String.self, forKey: .physicalAddress)
        shippingAddress = try container.decodeIfPresent(String.self, forKey: .shippingAddress)
        status = try NetBoxIngest.choiceValue(container, .status)
        deviceCount = try container.decodeIfPresent(Int64.self, forKey: .deviceCount) ?? 0
        regionID = try NetBoxIngest.nestedID(container, .region)
        groupID = try NetBoxIngest.nestedID(container, .group)
        tenantID = try NetBoxIngest.nestedID(container, .tenant)
    }
}

extension NetBoxRecord.Rack: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, display, url, created, status, site
        case lastUpdated = "last_updated"
        case uHeight = "u_height"
        case startingUnit = "starting_unit"
        case deviceCount = "device_count"
        case formFactor = "form_factor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        uHeight = try container.decodeIfPresent(Int64.self, forKey: .uHeight)
        startingUnit = try container.decodeIfPresent(Int64.self, forKey: .startingUnit) ?? 1
        deviceCount = try container.decodeIfPresent(Int64.self, forKey: .deviceCount)
        status = try NetBoxIngest.choiceValue(container, .status)
        formFactor = try NetBoxIngest.choiceValue(container, .formFactor)
        siteID = try NetBoxIngest.nestedID(container, .site)
    }
}

extension NetBoxRecord.Device: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, display, url, created, serial, status, position, site, role, rack
        case lastUpdated = "last_updated"
        case primaryIP = "primary_ip"
        case deviceType = "device_type"
        case customFields = "custom_fields"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        serial = try container.decodeIfPresent(String.self, forKey: .serial) ?? "Unknown"
        primaryIP = try NetBoxIngest.address(container, .primaryIP) ?? "Unknown"
        status = try NetBoxIngest.choiceValue(container, .status) ?? ""
        rackPosition = try container.decodeIfPresent(Double.self, forKey: .position).map(Float.init)
        let fields = try NetBoxIngest.pulseFields(container, .customFields)
        x = fields.x
        y = fields.y
        zabbixID = fields.zabbixID
        zabbixInstance = fields.zabbixInstance
        guard let site = try NetBoxIngest.nestedID(container, .site) else {
            throw DecodingError.valueNotFound(
                Int64.self,
                .init(codingPath: container.codingPath + [CodingKeys.site], debugDescription: "site.id")
            )
        }
        guard let role = try NetBoxIngest.nestedID(container, .role) else {
            throw DecodingError.valueNotFound(
                Int64.self,
                .init(codingPath: container.codingPath + [CodingKeys.role], debugDescription: "role.id")
            )
        }
        guard let type = try NetBoxIngest.nestedID(container, .deviceType) else {
            throw DecodingError.valueNotFound(
                Int64.self,
                .init(codingPath: container.codingPath + [CodingKeys.deviceType], debugDescription: "device_type.id")
            )
        }
        siteID = site
        roleID = role
        typeID = type
        rackID = try NetBoxIngest.nestedID(container, .rack)
    }
}

extension NetBoxRecord.Service: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, display, url, ports, ipaddresses, parent, description
        case parentObjectType = "parent_object_type"
        case parentObjectID = "parent_object_id"
        case proto = "protocol"
    }

    enum ProtocolKeys: String, CodingKey { case value, label }
    enum ParentKeys: String, CodingKey { case name }

    struct IPEntry: Decodable {
        var address: String?
    }

    struct Failable<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        serviceDescription = try container.decodeIfPresent(String.self, forKey: .description)
        if container.contains(.proto), try container.decodeNil(forKey: .proto) == false {
            let proto = try container.nestedContainer(keyedBy: ProtocolKeys.self, forKey: .proto)
            protocolValue = try proto.decodeIfPresent(String.self, forKey: .value)
            protocolLabel = try proto.decodeIfPresent(String.self, forKey: .label)
        } else {
            protocolValue = nil
            protocolLabel = nil
        }
        ports = try container.decodeIfPresent([Int].self, forKey: .ports) ?? []
        let ips = (try? container.decode([Failable<IPEntry>].self, forKey: .ipaddresses)) ?? []
        ipAddresses = ips.compactMap(\.value?.address)
        parentObjectType = try container.decode(String.self, forKey: .parentObjectType)
        parentObjectID = try container.decode(Int64.self, forKey: .parentObjectID)
        if container.contains(.parent), try container.decodeNil(forKey: .parent) == false {
            let parent = try container.nestedContainer(keyedBy: ParentKeys.self, forKey: .parent)
            parentName = try parent.decodeIfPresent(String.self, forKey: .name)
        } else {
            parentName = nil
        }
    }
}

extension NetBoxRecord.Interface: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, display, url, created, device, type, label, enabled, mtu, speed, description
        case lastUpdated = "last_updated"
        case connectedEndpoints = "connected_endpoints"
        case lag, bridge, parent
        case poeMode = "poe_mode"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        type = try NetBoxIngest.choiceValue(container, .type)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mtu = NetBoxIngest.flexibleString(container, .mtu)
        speed = NetBoxIngest.flexibleString(container, .speed)
        interfaceDescription = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        poeMode = try NetBoxIngest.choiceValue(container, .poeMode)
        let device = try NetBoxIngest.nestedNamed(container, .device)
        deviceID = device.id
        deviceName = device.name
        let endpoint = try NetBoxIngest.firstNamed(container, .connectedEndpoints)
        connectedEndpointID = endpoint.id
        connectedEndpointName = endpoint.name
        let lag = try NetBoxIngest.nestedNamed(container, .lag)
        lagID = lag.id
        lagName = lag.name
        let bridge = try NetBoxIngest.nestedNamed(container, .bridge)
        bridgeID = bridge.id
        bridgeName = bridge.name
        let parent = try NetBoxIngest.nestedNamed(container, .parent)
        parentID = parent.id
        parentName = parent.name
    }

    func asCacheValue() -> Interface {
        var value = Interface(id: id)
        value.name = name
        value.display = display
        value.url = url
        value.created = created
        value.lastUpdated = lastUpdated
        value.type = type
        value.label = label
        value.enabled = enabled
        value.mtu = mtu
        value.speed = speed
        value.interfaceDescription = interfaceDescription
        value.poeMode = poeMode
        value.deviceId = deviceID
        value.deviceName = deviceName
        value.connectedEndpointId = connectedEndpointID
        value.connectedEndpointName = connectedEndpointName
        value.lagId = lagID
        value.lagName = lagName
        value.bridgeId = bridgeID
        value.bridgeName = bridgeName
        value.parentId = parentID
        value.parentName = parentName
        return value
    }
}

extension NetBoxRecord.StaticDevice: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, display, created, site, rack, role
        case lastUpdated = "last_updated"
        case deviceType = "device_type"
        case rackPosition = "position"
        case frontPortCount = "front_port_count"
        case rearPortCount = "rear_port_count"
        case deviceBayCount = "device_bay_count"
    }

    enum ModelKey: String, CodingKey { case model }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        rackPosition = try container.decodeIfPresent(Double.self, forKey: .rackPosition).map(Float.init)
        frontPortCount = try container.decodeIfPresent(Int64.self, forKey: .frontPortCount) ?? 0
        rearPortCount = try container.decodeIfPresent(Int64.self, forKey: .rearPortCount) ?? 0
        deviceBayCount = try container.decodeIfPresent(Int64.self, forKey: .deviceBayCount) ?? 0
        let rack = try NetBoxIngest.nestedNamed(container, .rack)
        rackID = rack.id
        rackName = rack.name
        roleName = try NetBoxIngest.nestedNamed(container, .role).name
        siteName = try NetBoxIngest.nestedNamed(container, .site).name
        if container.contains(.deviceType), try container.decodeNil(forKey: .deviceType) == false {
            let type = try container.nestedContainer(keyedBy: ModelKey.self, forKey: .deviceType)
            typeModel = try type.decodeIfPresent(String.self, forKey: .model)
        } else {
            typeModel = nil
        }
    }

    func asCacheValue() -> StaticDevice {
        var value = StaticDevice(id: id)
        value.name = name
        value.display = display
        value.created = created
        value.lastUpdated = lastUpdated
        value.rackPosition = rackPosition
        value.frontPortCount = frontPortCount
        value.rearPortCount = rearPortCount
        value.deviceBayCount = deviceBayCount
        value.rackId = rackID
        value.rackName = rackName
        value.deviceRole = roleName
        value.deviceType = typeModel
        value.site = siteName
        return value
    }
}

extension NetBoxRecord.DeviceBay: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, display, created, device
        case lastUpdated = "last_updated"
        case installedDevice = "installed_device"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        created = try container.decodeIfPresent(Date.self, forKey: .created)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        let shelf = try NetBoxIngest.nestedNamed(container, .device)
        shelfID = shelf.id
        shelfName = shelf.name
        let installed = try NetBoxIngest.nestedNamed(container, .installedDevice)
        installedDeviceID = installed.id
        installedDeviceName = installed.name
    }

    func asCacheValue() -> DeviceBay {
        var value = DeviceBay(id: id)
        value.name = name
        value.display = display
        value.created = created
        value.lastUpdated = lastUpdated
        value.staticDeviceId = shelfID
        value.staticDeviceName = shelfName
        value.deviceId = installedDeviceID
        value.deviceName = installedDeviceName
        return value
    }
}

enum NetBoxMapping {
    static func tenantGroup(_ value: Components.Schemas.TenantGroup) -> NetBoxRecord.TenantGroup {
        NetBoxRecord.TenantGroup(
            id: Int64(value.id),
            name: value.name,
            created: value.created,
            lastUpdated: value.last_updated
        )
    }

    static func tenant(_ value: Components.Schemas.Tenant) -> NetBoxRecord.Tenant {
        NetBoxRecord.Tenant(
            id: Int64(value.id),
            name: value.name,
            created: value.created,
            lastUpdated: value.last_updated,
            groupID: value.group.map { Int64($0.value1.id) }
        )
    }

    static func region(_ value: Components.Schemas.Region) -> NetBoxRecord.Region {
        NetBoxRecord.Region(
            id: Int64(value.id),
            name: value.name,
            created: value.created,
            lastUpdated: value.last_updated,
            siteCount: Int64(value.site_count),
            parentID: value.parent.map { Int64($0.value1.id) }
        )
    }

    static func deviceRole(_ value: Components.Schemas.DeviceRole) -> NetBoxRecord.DeviceRole {
        NetBoxRecord.DeviceRole(
            id: Int64(value.id),
            name: value.name,
            created: value.created,
            lastUpdated: value.last_updated,
            colour: value.color
        )
    }

    static func deviceType(_ value: Components.Schemas.DeviceType) -> NetBoxRecord.DeviceType {
        NetBoxRecord.DeviceType(
            id: Int64(value.id),
            model: value.model,
            created: value.created,
            lastUpdated: value.last_updated,
            uHeight: value.u_height.map { Float($0) },
            manufacturerID: Int64(value.manufacturer.id)
        )
    }

    static func siteGroup(_ value: Components.Schemas.SiteGroup) -> NetBoxRecord.SiteGroup {
        NetBoxRecord.SiteGroup(
            id: Int64(value.id),
            name: value.name,
            created: value.created,
            lastUpdated: value.last_updated,
            parentID: value.parent.map { Int64($0.value1.id) }
        )
    }

    static func site(_ value: Components.Schemas.Site) -> NetBoxRecord.Site {
        NetBoxRecord.Site(
            id: Int64(value.id),
            name: value.name,
            display: value.display,
            url: value.url,
            created: value.created,
            lastUpdated: value.last_updated,
            latitude: value.latitude,
            longitude: value.longitude,
            physicalAddress: value.physical_address,
            shippingAddress: value.shipping_address,
            status: value.status?.value?.rawValue,
            deviceCount: value.device_count,
            regionID: value.region.map { Int64($0.value1.id) },
            groupID: value.group.map { Int64($0.value1.id) },
            tenantID: value.tenant.map { Int64($0.value1.id) }
        )
    }

    static func rack(_ value: Components.Schemas.Rack) -> NetBoxRecord.Rack {
        NetBoxRecord.Rack(
            id: Int64(value.id),
            name: value.name,
            display: value.display,
            url: value.url,
            created: value.created,
            lastUpdated: value.last_updated,
            uHeight: value.u_height.map { Int64($0) },
            startingUnit: Int64(value.starting_unit ?? 1),
            deviceCount: value.device_count,
            status: value.status?.value?.rawValue,
            formFactor: value.form_factor?.value?.rawValue,
            siteID: Int64(value.site.id)
        )
    }

    static func device(_ value: Components.Schemas.DeviceWithConfigContext) -> NetBoxRecord.Device {
        let fields = NetBoxCustomFields.pulseFields(
            from: value.custom_fields?.additionalProperties
        )
        return NetBoxRecord.Device(
            id: Int64(value.id),
            name: value.name,
            display: value.display,
            url: value.url,
            created: value.created,
            lastUpdated: value.last_updated,
            serial: value.serial ?? "Unknown",
            primaryIP: value.primary_ip?.value1.address ?? "Unknown",
            status: value.status?.value?.rawValue ?? "",
            rackPosition: value.position.map { Float($0) },
            x: fields.x,
            y: fields.y,
            zabbixID: fields.zabbixID,
            zabbixInstance: fields.zabbixInstance,
            siteID: Int64(value.site.id),
            roleID: Int64(value.role.id),
            typeID: Int64(value.device_type.id),
            rackID: value.rack.map { Int64($0.value1.id) }
        )
    }

    static func service(_ value: Components.Schemas.Service) -> NetBoxRecord.Service {
        NetBoxRecord.Service(
            id: Int64(value.id),
            name: value.name,
            display: value.display,
            url: value.url,
            serviceDescription: value.description,
            protocolValue: value._protocol?.value?.rawValue,
            protocolLabel: value._protocol?.label?.rawValue,
            ports: value.ports,
            ipAddresses: (value.ipaddresses ?? []).map(\.address),
            parentObjectType: value.parent_object_type,
            parentObjectID: value.parent_object_id,
            parentName: nil
        )
    }
}
