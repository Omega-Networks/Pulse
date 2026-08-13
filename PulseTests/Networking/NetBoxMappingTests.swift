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

    // MARK: - Tenant ingest

    func testTenantPageDecodesWhenGeneratedTypeWouldSkip() throws {
        let json = Data("""
        { "count": 2, "next": null, "results": [
          {
            "id": 1, "url": "u", "display_url": "d", "display": "Acme",
            "name": "Acme", "slug": "acme",
            "group": {
              "id": 4, "url": "u", "display": "Customers",
              "name": "Customers", "slug": "customers", "_depth": 0
            },
            "owner": { "id": 2, "url": "u", "display": "Ops", "name": "Ops" },
            "tags": [{ "id": 9, "url": "u", "display": "prod", "name": "prod", "slug": "prod" }],
            "created": "2022-04-27T09:47:32.110929Z",
            "last_updated": "2022-04-27T09:50:23.049511Z"
          },
          {
            "id": 8, "url": "u", "display_url": "d", "display": "Solo",
            "name": "Solo", "slug": "solo",
            "group": null,
            "created": "2024-01-02T03:04:05Z",
            "last_updated": "2024-01-02T03:04:05Z",
            "circuit_count": 0, "device_count": 0, "ipaddress_count": 0,
            "prefix_count": 0, "rack_count": 0, "site_count": 0,
            "virtualmachine_count": 0, "vlan_count": 0, "vrf_count": 0,
            "cluster_count": 0
          }
        ] }
        """.utf8)

        let generated = try NetBoxListDecoder.decodePage(Components.Schemas.Tenant.self, from: json)
        XCTAssertEqual(generated.results.map(\.id), [8])
        XCTAssertEqual(generated.skipped, 1)

        let page = try NetBoxListDecoder.decodePage(NetBoxRecord.Tenant.self, from: json)
        XCTAssertEqual(page.skipped, 0)
        XCTAssertEqual(page.results.map(\.id), [1, 8])
        XCTAssertEqual(page.results[0].name, "Acme")
        XCTAssertEqual(page.results[0].groupID, 4)
        XCTAssertNil(page.results[1].groupID)
    }

    func testSiteRackDevicePagesDecodeWhenGeneratedTypesSkip() throws {
        let sites = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 323, "url": "u", "display_url": "d", "display": "Lab",
            "name": "Lab", "slug": "lab",
            "status": { "value": "active", "label": "Active" },
            "region": { "id": 3, "url": "u", "display": "NZ", "name": "NZ", "slug": "nz", "_depth": 0 },
            "group": { "id": 2, "url": "u", "display": "Omega", "name": "Omega", "slug": "omega", "_depth": 0 },
            "tenant": { "id": 1, "url": "u", "display": "Acme", "name": "Acme", "slug": "acme" },
            "tags": [{ "id": 9, "url": "u", "display": "prod", "name": "prod", "slug": "prod" }],
            "latitude": -41.2, "longitude": 174.7,
            "created": "2024-01-02T03:04:05.000000Z",
            "last_updated": "2024-01-02T03:04:05.000000Z"
          }
        ] }
        """.utf8)
        XCTAssertEqual(
            try NetBoxListDecoder.decodePage(Components.Schemas.Site.self, from: sites).skipped,
            1
        )
        let sitePage = try NetBoxListDecoder.decodePage(NetBoxRecord.Site.self, from: sites)
        XCTAssertEqual(sitePage.skipped, 0)
        XCTAssertEqual(sitePage.results.first?.id, 323)
        XCTAssertEqual(sitePage.results.first?.regionID, 3)
        XCTAssertEqual(sitePage.results.first?.groupID, 2)
        XCTAssertEqual(sitePage.results.first?.tenantID, 1)
        XCTAssertEqual(sitePage.results.first?.status, "active")

        let racks = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 44, "url": "u", "display_url": "d", "display": "R1",
            "name": "R1",
            "site": { "id": 323, "url": "u", "display": "Lab", "name": "Lab", "slug": "lab" },
            "status": { "value": "active", "label": "Active" },
            "form_factor": { "value": "4-post-cabinet", "label": "4-post cabinet" },
            "u_height": 42, "starting_unit": 1, "device_count": 3,
            "created": "2024-01-02T03:04:05Z",
            "last_updated": "2024-01-02T03:04:05Z"
          }
        ] }
        """.utf8)
        let rackPage = try NetBoxListDecoder.decodePage(NetBoxRecord.Rack.self, from: racks)
        XCTAssertEqual(rackPage.skipped, 0)
        XCTAssertEqual(rackPage.results.first?.siteID, 323)
        XCTAssertEqual(rackPage.results.first?.uHeight, 42)
        XCTAssertEqual(rackPage.results.first?.formFactor, "4-post-cabinet")

        let devices = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 1260, "url": "u", "display_url": "d", "display": "sw1",
            "name": "sw1",
            "device_type": { "id": 8, "url": "u", "display": "t", "model": "t", "slug": "t" },
            "role": { "id": 2, "url": "u", "display": "r", "name": "r", "slug": "r" },
            "site": { "id": 323, "url": "u", "display": "Lab", "name": "Lab", "slug": "lab" },
            "primary_ip": { "id": 9, "url": "u", "display": "10.0.0.1/24", "address": "10.0.0.1/24" },
            "status": { "value": "active", "label": "Active" },
            "custom_fields": { "coordinate_x": 1.5, "coordinate_y": "2.5", "zabbix_id": 99 },
            "created": "2022-09-21T03:30:07.062900Z",
            "last_updated": "2022-09-21T03:30:07.062900Z"
          }
        ] }
        """.utf8)
        XCTAssertEqual(
            try NetBoxListDecoder.decodePage(Components.Schemas.DeviceWithConfigContext.self, from: devices).skipped,
            1
        )
        let devicePage = try NetBoxListDecoder.decodePage(NetBoxRecord.Device.self, from: devices)
        XCTAssertEqual(devicePage.skipped, 0)
        XCTAssertEqual(devicePage.results.first?.siteID, 323)
        XCTAssertEqual(devicePage.results.first?.roleID, 2)
        XCTAssertEqual(devicePage.results.first?.typeID, 8)
        XCTAssertEqual(devicePage.results.first?.primaryIP, "10.0.0.1/24")
        XCTAssertEqual(devicePage.results.first?.x, 1.5)
        XCTAssertEqual(devicePage.results.first?.y, 2.5)
        XCTAssertEqual(devicePage.results.first?.zabbixID, 99)
    }

    func testSkipDescriptionNamesTheMissingKey() {
        enum ProbeKey: String, CodingKey { case id }
        let message = NetBoxListDecoder.describe(
            DecodingError.keyNotFound(
                ProbeKey.id,
                .init(codingPath: [ProbeKey.id], debugDescription: "")
            )
        )
        XCTAssertTrue(message.contains("id"), message)
        XCTAssertTrue(message.contains("missing key"), message)
    }

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
        let ingested = try NetBoxListDecoder.makeDecoder().decode(NetBoxRecord.Device.self, from: json)
        XCTAssertEqual(ingested, record)
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

    func testServicePageDecodesIPAddressesWithoutDisplayURL() throws {
        let json = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 7,
            "url": "https://netbox.example.com/api/ipam/services/7/",
            "display": "SSH (TCP/22)",
            "parent_object_type": "dcim.device",
            "parent_object_id": 6023,
            "parent": { "id": 6023, "name": "core-switch-01" },
            "name": "SSH",
            "protocol": { "value": "tcp", "label": "TCP" },
            "ports": [22],
            "ipaddresses": [
              { "id": 2275, "address": "192.0.2.10/24", "family": { "value": 4, "label": "IPv4" } }
            ],
            "description": "Secure shell access"
          }
        ] }
        """.utf8)
        XCTAssertEqual(
            try NetBoxListDecoder.decodePage(Components.Schemas.Service.self, from: json).skipped,
            1
        )
        let page = try NetBoxListDecoder.decodePage(NetBoxRecord.Service.self, from: json)
        XCTAssertEqual(page.skipped, 0)
        XCTAssertEqual(page.results.first?.id, 7)
        XCTAssertEqual(page.results.first?.ipAddresses, ["192.0.2.10/24"])
        XCTAssertEqual(page.results.first?.parentObjectType, "dcim.device")
        XCTAssertEqual(page.results.first?.parentObjectID, 6023)
        XCTAssertEqual(page.results.first?.parentName, "core-switch-01")
        XCTAssertEqual(page.results.first?.protocolValue, "tcp")
    }

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
