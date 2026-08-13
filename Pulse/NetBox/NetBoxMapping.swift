//
//  NetBoxMapping.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
