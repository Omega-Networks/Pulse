//
//  NetBoxMappingTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
//

import Foundation
import NetBoxAPI
import SwiftData
import XCTest
@testable import Pulse

final class NetBoxMappingTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Service.self, WebHostTrust.self,
            Event.self, SyncProvider.self, PowerSenseDevice.self, PowerSenseEvent.self,
            SSHCredential.self, KnownHost.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - List decoder

    func testPoisonedElementIsSkippedAndBlocksDelete() throws {
        let json = Data("""
        { "count": 2, "next": null, "results": [
          { "id": 1, "url": "u", "display_url": "d", "display": "Good",
            "name": "Good", "slug": "good",
            "created": "2024-01-02T03:04:05.000000Z",
            "last_updated": "2024-01-02T03:04:05.000000Z",
            "tenant_count": 0, "_depth": 0 },
          { "this": "is-not-a-tenant-group" }
        ] }
        """.utf8)

        let page = try NetBoxListDecoder.decodePage(Components.Schemas.TenantGroup.self, from: json)
        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(page.results.first?.id, 1)
        XCTAssertEqual(page.skipped, 1)
        XCTAssertFalse(page.allowsDelete)
    }

    func testCleanPageAllowsDelete() throws {
        let json = Data("""
        { "count": 1, "next": null, "results": [
          { "id": 1, "url": "u", "display_url": "d", "display": "Good",
            "name": "Good", "slug": "good",
            "created": "2024-01-02T03:04:05Z",
            "last_updated": "2024-01-02T03:04:05Z",
            "tenant_count": 0, "_depth": 0 }
        ] }
        """.utf8)
        let page = try NetBoxListDecoder.decodePage(Components.Schemas.TenantGroup.self, from: json)
        XCTAssertEqual(page.skipped, 0)
        XCTAssertTrue(page.allowsDelete)
    }

    // MARK: - Tenant / site insert (the lastUpdated-equal bug)

    func testNewTenantWithoutGroupIsInserted() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let result = try NetBoxStore.applyTenants(
            [NetBoxRecord.Tenant(id: 9, name: "Solo", created: nil, lastUpdated: Date(), groupID: nil)],
            fetchComplete: true,
            skipped: 0,
            in: context
        )
        XCTAssertEqual(result.upserted, 1)
        let tenants = try context.fetch(FetchDescriptor<Tenant>())
        XCTAssertEqual(tenants.count, 1)
        XCTAssertEqual(tenants.first?.name, "Solo")
        XCTAssertNil(tenants.first?.group)
    }

    func testNewSiteWithoutParentsIsInsertedAndRegionWires() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        _ = try NetBoxStore.applyRegions(
            [NetBoxRecord.Region(id: 3, name: "NZ", created: nil, lastUpdated: nil, siteCount: 1, parentID: nil)],
            fetchComplete: true,
            skipped: 0,
            in: context
        )
        let result = try NetBoxStore.applySites(
            [NetBoxRecord.Site(
                id: 4,
                name: "Lab",
                display: "Lab",
                url: "u",
                created: nil,
                lastUpdated: Date(),
                latitude: 1,
                longitude: 2,
                physicalAddress: nil,
                shippingAddress: nil,
                status: "active",
                deviceCount: 0,
                regionID: 3,
                groupID: nil,
                tenantID: nil
            )],
            fetchComplete: true,
            skipped: 0,
            in: context
        )
        XCTAssertEqual(result.upserted, 1)
        let sites = try context.fetch(FetchDescriptor<Site>())
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites.first?.region?.id, 3)
        XCTAssertEqual(sites.first?.status, "active")
    }

    // MARK: - Delete gate

    func testPoisonedFetchDoesNotDeleteStaleRows() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        _ = try NetBoxStore.applyTenantGroups(
            [
                NetBoxRecord.TenantGroup(id: 1, name: "Keep", created: nil, lastUpdated: nil),
                NetBoxRecord.TenantGroup(id: 2, name: "Stale", created: nil, lastUpdated: nil)
            ],
            fetchComplete: true,
            skipped: 0,
            in: context
        )
        let gated = try NetBoxStore.applyTenantGroups(
            [NetBoxRecord.TenantGroup(id: 1, name: "Keep", created: nil, lastUpdated: nil)],
            fetchComplete: true,
            skipped: 1,
            in: context
        )
        XCTAssertFalse(gated.didDelete)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TenantGroup>()).count, 2)

        let clean = try NetBoxStore.applyTenantGroups(
            [NetBoxRecord.TenantGroup(id: 1, name: "Keep", created: nil, lastUpdated: nil)],
            fetchComplete: true,
            skipped: 0,
            in: context
        )
        XCTAssertTrue(clean.didDelete)
        XCTAssertEqual(clean.deleted, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TenantGroup>()).map(\.id), [1])
    }

    func testIncompleteFetchDoesNotDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        _ = try NetBoxStore.applyTenantGroups(
            [NetBoxRecord.TenantGroup(id: 1, name: "A", created: nil, lastUpdated: nil)],
            fetchComplete: true,
            skipped: 0,
            in: context
        )
        let result = try NetBoxStore.applyTenantGroups(
            [],
            fetchComplete: false,
            skipped: 0,
            in: context
        )
        XCTAssertFalse(result.didDelete)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TenantGroup>()).count, 1)
    }

    // MARK: - Device mapping

    func testUnnamedDeviceAndCustomFieldsMap() throws {
        let json = Data("""
        {
          "id": 10, "url": "u", "display_url": "d", "display": "",
          "name": null,
          "device_type": {
            "id": 8, "url": "u", "display": "t", "manufacturer": {
              "id": 1, "url": "u", "display": "m", "name": "m", "slug": "m", "description": "", "devicetype_count": 1
            },
            "model": "t", "slug": "t", "description": "", "device_count": 1
          },
          "role": {
            "id": 2, "url": "u", "display": "r", "name": "r", "slug": "r",
            "description": "", "device_count": 1, "virtualmachine_count": 0, "_depth": 0
          },
          "site": { "id": 4, "url": "u", "display": "s", "name": "s", "slug": "s", "description": "" },
          "serial": null,
          "primary_ip": null,
          "status": { "value": "active", "label": "Active" },
          "custom_fields": {
            "coordinate_x": 1.5, "coordinate_y": 2.5,
            "zabbix_id": 99, "zabbix_instance": 1
          },
          "created": "2022-09-21T03:30:07.062900Z",
          "last_updated": "2022-09-21T03:30:07.062900Z",
          "console_port_count": 0, "console_server_port_count": 0,
          "power_port_count": 0, "power_outlet_count": 0,
          "interface_count": 0, "front_port_count": 0, "rear_port_count": 0,
          "device_bay_count": 0, "module_bay_count": 0, "inventory_item_count": 0
        }
        """.utf8)

        let generated = try NetBoxListDecoder.makeDecoder()
            .decode(Components.Schemas.DeviceWithConfigContext.self, from: json)
        let record = NetBoxMapping.device(generated)
        XCTAssertNil(record.name)
        XCTAssertEqual(record.serial, "Unknown")
        XCTAssertEqual(record.primaryIP, "Unknown")
        XCTAssertEqual(record.status, "active")
        XCTAssertEqual(record.x, 1.5)
        XCTAssertEqual(record.y, 2.5)
        XCTAssertEqual(record.zabbixID, 99)
        XCTAssertEqual(record.zabbixInstance, 1)
        XCTAssertEqual(record.siteID, 4)
        XCTAssertEqual(record.roleID, 2)
        XCTAssertEqual(record.typeID, 8)
    }

    func testUnnamedDeviceUpserts() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        _ = try NetBoxStore.applyDeviceRoles(
            [NetBoxRecord.DeviceRole(id: 2, name: "r", created: nil, lastUpdated: nil, colour: nil)],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applyDeviceTypes(
            [NetBoxRecord.DeviceType(id: 8, model: "t", created: nil, lastUpdated: nil, uHeight: 1, manufacturerID: 1)],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applySites(
            [NetBoxRecord.Site(
                id: 4, name: "s", display: "s", url: "u", created: nil, lastUpdated: nil,
                latitude: 0, longitude: 0, physicalAddress: nil, shippingAddress: nil,
                status: "active", deviceCount: 0, regionID: nil, groupID: nil, tenantID: nil
            )],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applyDevices(
            [NetBoxRecord.Device(
                id: 10, name: nil, display: "", url: "u", created: nil, lastUpdated: Date(),
                serial: "Unknown", primaryIP: "Unknown", status: "active", rackPosition: nil,
                x: 0, y: 0, zabbixID: 0, zabbixInstance: 0,
                siteID: 4, roleID: 2, typeID: 8, rackID: nil
            )],
            fetchComplete: true, skipped: 0, in: context
        )
        let devices = try context.fetch(FetchDescriptor<Device>())
        XCTAssertEqual(devices.count, 1)
        XCTAssertNil(devices.first?.name)
        XCTAssertEqual(devices.first?.site?.id, 4)
    }

    // MARK: - Services

    func testServiceWiresDeviceParentAndRetainsVMParent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Device(id: 6023))
        try context.save()
        _ = try NetBoxStore.applyServices(
            [
                NetBoxRecord.Service(
                    id: 7, name: "SSH", display: "SSH", url: "u", serviceDescription: "",
                    protocolValue: "tcp", protocolLabel: "TCP", ports: [22],
                    ipAddresses: ["10.0.0.1/24"], parentObjectType: "dcim.device",
                    parentObjectID: 6023, parentName: nil
                ),
                NetBoxRecord.Service(
                    id: 91, name: "HTTPS", display: "HTTPS", url: "u", serviceDescription: "",
                    protocolValue: "tcp", protocolLabel: "TCP", ports: [443],
                    ipAddresses: ["10.0.0.2/24"], parentObjectType: "virtualization.virtualmachine",
                    parentObjectID: 4410, parentName: nil
                )
            ],
            fetchComplete: true,
            skipped: 0,
            in: context
        )
        let services = try context.fetch(FetchDescriptor<Service>())
        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services.first { $0.id == 7 }?.device?.id, 6023)
        XCTAssertNil(services.first { $0.id == 91 }?.device)
    }
}
