//
//  NetBoxMappingTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  Under the terms of the GNU Affero General Public License version 3 as published by the
//  Free Software Foundation, this program is free software: communities can deploy it for
//  sovereignty, academia can extend it for research, and industry can integrate it for resilience.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
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
            SiteLocation.self, RackRole.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Interface.self, Cable.self, DeviceBay.self, FrontPort.self, Service.self, WebHostTrust.self,
            Event.self, SyncProvider.self, PowerSenseDevice.self, PowerSenseEvent.self,
            SSHCredential.self, KnownHost.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func bayRecord(id: Int64, shelfID: Int64?) -> NetBoxRecord.DeviceBay {
        NetBoxRecord.DeviceBay(
            id: id,
            name: "Bay \(id)",
            display: "Bay \(id)",
            label: nil,
            created: nil,
            lastUpdated: nil,
            shelfID: shelfID,
            shelfName: nil,
            installedDeviceID: nil,
            installedDeviceName: nil
        )
    }

    private func frontPortRecord(id: Int64, deviceID: Int64?) -> NetBoxRecord.FrontPort {
        NetBoxRecord.FrontPort(
            id: id,
            name: "\(id)",
            display: "\(id)",
            label: nil,
            type: "8p8c",
            colour: nil,
            created: nil,
            lastUpdated: nil,
            occupied: false,
            cableID: nil,
            connectedEndpointID: nil,
            connectedEndpointName: nil,
            connectedEndpointType: nil,
            deviceID: deviceID,
            deviceName: nil
        )
    }

    private func interfaceRecord(id: Int64, deviceID: Int64?) -> NetBoxRecord.Interface {
        NetBoxRecord.Interface(
            id: id,
            name: "eth\(id)",
            display: "eth\(id)",
            url: nil,
            created: nil,
            lastUpdated: nil,
            type: "1000base-t",
            label: nil,
            enabled: true,
            mtu: 1500,
            speed: 1_000_000,
            interfaceDescription: "",
            poeMode: nil,
            duplex: nil,
            occupied: false,
            deviceID: deviceID,
            deviceName: nil,
            connectedEndpointID: nil,
            connectedEndpointName: nil,
            connectedEndpointDeviceID: nil,
            cableID: nil,
            lagID: nil,
            lagName: nil,
            bridgeID: nil,
            bridgeName: nil,
            parentID: nil,
            parentName: nil
        )
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
            "location": { "id": 9, "url": "u", "display": "MDF", "name": "MDF", "slug": "mdf" },
            "role": { "id": 3, "url": "u", "display": "Network", "name": "Network", "slug": "network" },
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
        XCTAssertEqual(rackPage.results.first?.locationID, 9)
        XCTAssertEqual(rackPage.results.first?.roleID, 3)
        XCTAssertEqual(rackPage.results.first?.uHeight, 42)
        XCTAssertEqual(rackPage.results.first?.formFactor, "4-post-cabinet")

        let locations = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 9, "name": "MDF",
            "site": { "id": 323, "name": "Lab" },
            "parent": { "id": 2, "name": "Floor 1" },
            "status": { "value": "active", "label": "Active" },
            "created": "2024-01-02T03:04:05Z",
            "last_updated": "2024-01-02T03:04:05Z"
          }
        ] }
        """.utf8)
        let locationPage = try NetBoxListDecoder.decodePage(NetBoxRecord.Location.self, from: locations)
        XCTAssertEqual(locationPage.results.first?.siteID, 323)
        XCTAssertEqual(locationPage.results.first?.parentID, 2)
        XCTAssertEqual(locationPage.results.first?.name, "MDF")

        let roles = Data("""
        { "count": 1, "next": null, "results": [
          { "id": 3, "name": "Network", "color": "2196f3" }
        ] }
        """.utf8)
        let rolePage = try NetBoxListDecoder.decodePage(NetBoxRecord.RackRole.self, from: roles)
        XCTAssertEqual(rolePage.results.first?.name, "Network")
        XCTAssertEqual(rolePage.results.first?.colour, "2196f3")

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
        XCTAssertEqual(devicePage.results.first?.frontPortCount, 0)
        XCTAssertEqual(devicePage.results.first?.deviceBayCount, 0)
    }

    func testApplyLocationsRackRolesAndRackForeignKeys() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        _ = try NetBoxStore.applySites(
            [NetBoxRecord.Site(
                id: 323, name: "Lab", display: "Lab", url: "u", created: nil, lastUpdated: nil,
                latitude: 0, longitude: 0, physicalAddress: nil, shippingAddress: nil,
                status: "active", deviceCount: 0, regionID: nil, groupID: nil, tenantID: nil
            )],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applyLocations(
            [NetBoxRecord.Location(
                id: 9, name: "MDF", created: nil, lastUpdated: nil,
                status: "active", siteID: 323, parentID: 2
            )],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applyRackRoles(
            [NetBoxRecord.RackRole(
                id: 3, name: "Network", created: nil, lastUpdated: nil, colour: "2196f3"
            )],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applyRacks(
            [NetBoxRecord.Rack(
                id: 44, name: "R1", display: "R1", url: "u", created: nil, lastUpdated: nil,
                uHeight: 42, startingUnit: 1, deviceCount: 0, status: "active",
                formFactor: "4-post-cabinet", siteID: 323, locationID: 9, roleID: 3
            )],
            fetchComplete: true, skipped: 0, in: context
        )
        let locations = try context.fetch(FetchDescriptor<SiteLocation>())
        XCTAssertEqual(locations.first?.name, "MDF")
        XCTAssertEqual(locations.first?.siteId, 323)
        let roles = try context.fetch(FetchDescriptor<RackRole>())
        XCTAssertEqual(roles.first?.name, "Network")
        let racks = try context.fetch(FetchDescriptor<Rack>())
        XCTAssertEqual(racks.first?.locationId, 9)
        XCTAssertEqual(racks.first?.rackRoleId, 3)
    }

    func testDeviceFaceDecodesChoiceObjectAndBareString() throws {
        let asObject = Data("""
        { "id": 1, "name": "sw1",
          "device_type": { "id": 8, "model": "t" },
          "role": { "id": 2, "name": "r" },
          "site": { "id": 4, "name": "Lab" },
          "face": { "value": "rear", "label": "Rear" },
          "position": 14
        }
        """.utf8)
        let object = try NetBoxListDecoder.makeDecoder().decode(NetBoxRecord.Device.self, from: asObject)
        XCTAssertEqual(object.face, "rear")
        XCTAssertEqual(object.rackPosition, 14)

        let asString = Data("""
        { "id": 2, "name": "sw2",
          "device_type": { "id": 8, "model": "t" },
          "role": { "id": 2, "name": "r" },
          "site": { "id": 4, "name": "Lab" },
          "face": "front"
        }
        """.utf8)
        let string = try NetBoxListDecoder.makeDecoder().decode(NetBoxRecord.Device.self, from: asString)
        XCTAssertEqual(string.face, "front")
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

    // MARK: - On-demand ingest

    func testInterfaceUpsertSkipsUnresolvedDeviceWithoutGatingDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let site = Site(id: 1)
        site.name = "Lab"
        context.insert(site)
        let device = Device(id: 10)
        device.site = site
        context.insert(device)
        try context.save()

        let accepted = interfaceRecord(id: 1, deviceID: 10)
        let orphan = interfaceRecord(id: 2, deviceID: 99)
        let first = try NetBoxStore.applyInterfaces(
            [accepted, orphan],
            fetchComplete: false,
            skipped: 0,
            keeping: [],
            in: context
        )
        XCTAssertEqual(first.upserted, 1)
        XCTAssertEqual(first.outOfScope, 1)
        XCTAssertFalse(first.didDelete)
        XCTAssertEqual(first.acceptedIDs, [1])

        let stale = interfaceRecord(id: 3, deviceID: 10)
        _ = try NetBoxStore.applyInterfaces(
            [stale],
            fetchComplete: false,
            skipped: 0,
            keeping: [],
            in: context
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<Interface>()).count, 2)

        let finished = try NetBoxStore.applyInterfaces(
            [],
            fetchComplete: true,
            skipped: 0,
            keeping: [1],
            in: context
        )
        XCTAssertTrue(finished.didDelete)
        XCTAssertEqual(finished.deleted, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Interface>()).map(\.id), [1])
    }

    func testInterfaceDeleteUsesAccumulatedKeepingNotLastPage() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let site = Site(id: 1)
        context.insert(site)
        let device = Device(id: 10)
        device.site = site
        context.insert(device)
        try context.save()

        _ = try NetBoxStore.applyInterfaces(
            [interfaceRecord(id: 1, deviceID: 10)],
            fetchComplete: false,
            skipped: 0,
            keeping: [],
            in: context
        )
        _ = try NetBoxStore.applyInterfaces(
            [interfaceRecord(id: 2, deviceID: 10)],
            fetchComplete: false,
            skipped: 0,
            keeping: [],
            in: context
        )
        let lastPageOnly = try NetBoxStore.applyInterfaces(
            [],
            fetchComplete: true,
            skipped: 0,
            keeping: [2],
            in: context
        )
        XCTAssertTrue(lastPageOnly.didDelete)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Interface>()).map(\.id)), [2])
    }

    func testInterfacePoisonedSkipGatesDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let site = Site(id: 1)
        context.insert(site)
        let device = Device(id: 10)
        device.site = site
        context.insert(device)
        try context.save()

        _ = try NetBoxStore.applyInterfaces(
            [interfaceRecord(id: 1, deviceID: 10), interfaceRecord(id: 2, deviceID: 10)],
            fetchComplete: true,
            skipped: 0,
            keeping: [1, 2],
            in: context
        )
        let gated = try NetBoxStore.applyInterfaces(
            [interfaceRecord(id: 1, deviceID: 10)],
            fetchComplete: true,
            skipped: 1,
            keeping: [1],
            in: context
        )
        XCTAssertFalse(gated.didDelete)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Interface>()).count, 2)
    }

    func testInterfaceWithDeviceButNoSiteIsStored() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Device(id: 10))
        try context.save()

        let result = try NetBoxStore.applyInterfaces(
            [interfaceRecord(id: 1, deviceID: 10)],
            fetchComplete: true,
            skipped: 0,
            keeping: [1],
            in: context
        )
        XCTAssertEqual(result.upserted, 1)
        XCTAssertEqual(result.outOfScope, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Interface>()).first?.siteId, 0)
    }

    func testInterfaceWithoutDeviceIsOutOfScope() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let result = try NetBoxStore.applyInterfaces(
            [interfaceRecord(id: 1, deviceID: 99)],
            fetchComplete: true,
            skipped: 0,
            keeping: [],
            in: context
        )
        XCTAssertEqual(result.upserted, 0)
        XCTAssertEqual(result.outOfScope, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Interface>()).isEmpty)
    }

    func testInterfacePageDecodesMTUAsIntegerAndFirstEndpoint() throws {
        let json = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 88, "url": "u", "display": "eth0", "name": "eth0",
            "device": { "id": 10, "name": "core-switch-01" },
            "type": { "value": "1000base-t", "label": "1000BASE-T" },
            "enabled": true, "mtu": 1500, "speed": 1000000,
            "description": "uplink",
            "duplex": { "value": "full", "label": "Full" },
            "occupied": true,
            "cable": { "id": 44, "url": "c", "display": "c-44" },
            "connected_endpoints": [
              { "id": 99, "name": "eth1", "device": { "id": 11 } }
            ],
            "lag": null, "bridge": null, "parent": null,
            "created": "2024-01-02T03:04:05Z",
            "last_updated": "2024-01-02T03:04:05Z"
          }
        ] }
        """.utf8)
        let page = try NetBoxListDecoder.decodePage(NetBoxRecord.Interface.self, from: json)
        XCTAssertEqual(page.skipped, 0)
        XCTAssertEqual(page.results.first?.mtu, 1500)
        XCTAssertEqual(page.results.first?.speed, 1_000_000)
        XCTAssertEqual(page.results.first?.connectedEndpointID, 99)
        XCTAssertEqual(page.results.first?.connectedEndpointDeviceID, 11)
        XCTAssertEqual(page.results.first?.deviceID, 10)
        XCTAssertEqual(page.results.first?.duplex, "full")
        XCTAssertEqual(page.results.first?.occupied, true)
        XCTAssertEqual(page.results.first?.connectedEndpointName, "eth1")
        XCTAssertEqual(page.results.first?.cableID, 44)
        XCTAssertNil(page.results.first?.lagID)
        XCTAssertNil(page.results.first?.bridgeID)
        XCTAssertNil(page.results.first?.parentID)
    }

    func testInterfacePageAcceptsStringMTUAndEmptyEndpoint() throws {
        let json = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 89, "name": "eth2",
            "device": { "id": 10, "name": "core-switch-01" },
            "enabled": false, "mtu": "9000", "speed": "0",
            "connected_endpoints": [],
            "lag": null, "bridge": null, "parent": null
          }
        ] }
        """.utf8)
        let page = try NetBoxListDecoder.decodePage(NetBoxRecord.Interface.self, from: json)
        XCTAssertEqual(page.skipped, 0)
        XCTAssertEqual(page.results.first?.mtu, 9000)
        XCTAssertEqual(page.results.first?.speed, 0)
        XCTAssertNil(page.results.first?.connectedEndpointID)
        XCTAssertNil(page.results.first?.connectedEndpointDeviceID)
        XCTAssertNil(page.results.first?.cableID)
        XCTAssertEqual(page.results.first?.occupied, false)
    }

    func testDevicePortCountsAndBayPagesDecode() throws {
        let devices = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 50, "name": "shelf-1", "display": "shelf-1",
            "role": { "id": 6, "name": "Shelf" },
            "device_type": { "id": 3, "model": "1U-shelf" },
            "site": { "id": 4, "name": "Lab" },
            "rack": { "id": 44, "name": "R1" },
            "position": 10,
            "front_port_count": 0, "rear_port_count": 0, "device_bay_count": 8
          }
        ] }
        """.utf8)
        let devicePage = try NetBoxListDecoder.decodePage(NetBoxRecord.Device.self, from: devices)
        XCTAssertEqual(devicePage.skipped, 0)
        XCTAssertEqual(devicePage.results.first?.roleID, 6)
        XCTAssertEqual(devicePage.results.first?.deviceBayCount, 8)
        XCTAssertEqual(devicePage.results.first?.frontPortCount, 0)

        let bays = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 70, "name": "Bay 1", "display": "Bay 1",
            "device": { "id": 50, "name": "shelf-1" },
            "installed_device": { "id": 51, "name": "router-1" }
          }
        ] }
        """.utf8)
        let bayPage = try NetBoxListDecoder.decodePage(NetBoxRecord.DeviceBay.self, from: bays)
        XCTAssertEqual(bayPage.skipped, 0)
        let bay = try XCTUnwrap(bayPage.results.first)
        XCTAssertEqual(bay.shelfID, 50)
        XCTAssertEqual(bay.installedDeviceID, 51)
        XCTAssertEqual(bay.installedDeviceName, "router-1")

        let fronts = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 80, "name": "1", "display": "1", "label": "1",
            "device": { "id": 50, "name": "pp-1" },
            "type": { "value": "8p8c", "label": "8P8C" },
            "cable": { "id": 9 },
            "occupied": true,
            "connected_endpoints": [
              { "id": 12, "name": "Gi0/1", "object_type": "dcim.interface",
                "device": { "id": 10 } }
            ]
          }
        ] }
        """.utf8)
        let frontPage = try NetBoxListDecoder.decodePage(NetBoxRecord.FrontPort.self, from: fronts)
        XCTAssertEqual(frontPage.skipped, 0)
        let port = try XCTUnwrap(frontPage.results.first)
        XCTAssertEqual(port.deviceID, 50)
        XCTAssertEqual(port.cableID, 9)
        XCTAssertEqual(port.connectedEndpointID, 12)
        XCTAssertEqual(port.connectedEndpointType, "dcim.interface")
    }

    func testApplyCablesUsesInterfaceSiteAndDeviceBaysNeedAShelf() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let site = Site(id: 4)
        context.insert(site)
        let device = Device(id: 10)
        device.site = site
        context.insert(device)
        let iface = Interface(id: 1)
        iface.deviceId = 10
        iface.siteId = 4
        iface.device = device
        context.insert(iface)
        try context.save()

        let applied = try NetBoxStore.applyCables(
            [NetBoxRecord.Cable(
                id: 9,
                display: "c",
                url: nil,
                created: nil,
                lastUpdated: nil,
                status: "connected",
                type: "cat6",
                label: nil,
                cableDescription: "",
                colour: "f44336",
                length: 2,
                lengthUnit: "m",
                tenantID: 3,
                tenantName: "Omega",
                bundleID: nil,
                aInterfaceID: 1,
                bInterfaceID: 2
            )],
            fetchComplete: false,
            skipped: 0,
            keeping: [],
            in: context
        )
        XCTAssertEqual(applied.upserted, 1)
        let cable = try XCTUnwrap(try context.fetch(FetchDescriptor<Cable>()).first)
        XCTAssertEqual(cable.siteId, 4)
        XCTAssertEqual(cable.tenantId, 3)
        XCTAssertEqual(cable.colour, "f44336")

        let orphan = try NetBoxStore.applyDeviceBays(
            [NetBoxRecord.DeviceBay(
                id: 70,
                name: "Bay 1",
                display: "Bay 1",
                label: nil,
                created: nil,
                lastUpdated: nil,
                shelfID: 99,
                shelfName: "missing",
                installedDeviceID: 51,
                installedDeviceName: "router-1"
            )],
            fetchComplete: false,
            skipped: 0,
            keeping: [],
            in: context
        )
        XCTAssertEqual(orphan.upserted, 0)
        XCTAssertEqual(orphan.outOfScope, 1)
    }

    func testDeviceBayPoisonedSkipGatesDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Device(id: 50))
        try context.save()

        _ = try NetBoxStore.applyDeviceBays(
            [bayRecord(id: 1, shelfID: 50), bayRecord(id: 2, shelfID: 50)],
            fetchComplete: true,
            skipped: 0,
            keeping: [1, 2],
            in: context
        )
        let gated = try NetBoxStore.applyDeviceBays(
            [bayRecord(id: 1, shelfID: 50)],
            fetchComplete: true,
            skipped: 1,
            keeping: [1],
            in: context
        )
        XCTAssertFalse(gated.didDelete)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeviceBay>()).count, 2)

        let cleaned = try NetBoxStore.applyDeviceBays(
            [],
            fetchComplete: true,
            skipped: 0,
            keeping: [1],
            in: context
        )
        XCTAssertTrue(cleaned.didDelete)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeviceBay>()).map(\.id), [1])
    }

    func testFrontPortPoisonedSkipGatesDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Device(id: 50))
        try context.save()

        _ = try NetBoxStore.applyFrontPorts(
            [frontPortRecord(id: 1, deviceID: 50), frontPortRecord(id: 2, deviceID: 50)],
            fetchComplete: true,
            skipped: 0,
            keeping: [1, 2],
            in: context
        )
        let gated = try NetBoxStore.applyFrontPorts(
            [frontPortRecord(id: 1, deviceID: 50)],
            fetchComplete: true,
            skipped: 1,
            keeping: [1],
            in: context
        )
        XCTAssertFalse(gated.didDelete)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FrontPort>()).count, 2)
    }

    func testDeletingRackNullifiesDevices() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        _ = try NetBoxStore.applySites(
            [NetBoxRecord.Site(
                id: 4, name: "s", display: "s", url: "u", created: nil, lastUpdated: nil,
                latitude: 0, longitude: 0, physicalAddress: nil, shippingAddress: nil,
                status: "active", deviceCount: 0, regionID: nil, groupID: nil, tenantID: nil
            )],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applyDeviceRoles(
            [NetBoxRecord.DeviceRole(id: 2, name: "r", created: nil, lastUpdated: nil, colour: nil)],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applyDeviceTypes(
            [NetBoxRecord.DeviceType(id: 8, model: "t", created: nil, lastUpdated: nil, uHeight: 1, manufacturerID: 1)],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applyRacks(
            [
                NetBoxRecord.Rack(
                    id: 44, name: "R1", display: "R1", url: "u", created: nil, lastUpdated: nil,
                    uHeight: 42, startingUnit: 1, deviceCount: 1, status: "active",
                    formFactor: nil, siteID: 4, locationID: nil, roleID: nil
                ),
                NetBoxRecord.Rack(
                    id: 45, name: "R2", display: "R2", url: "u", created: nil, lastUpdated: nil,
                    uHeight: 42, startingUnit: 1, deviceCount: 0, status: "active",
                    formFactor: nil, siteID: 4, locationID: nil, roleID: nil
                ),
            ],
            fetchComplete: true, skipped: 0, in: context
        )
        _ = try NetBoxStore.applyDevices(
            [NetBoxRecord.Device(
                id: 10, name: "core", display: "core", url: "u", created: nil, lastUpdated: nil,
                serial: "Unknown", primaryIP: "Unknown", status: "active", rackPosition: 12,
                x: 0, y: 0, zabbixID: 0, zabbixInstance: 0,
                siteID: 4, roleID: 2, typeID: 8, rackID: 44
            )],
            fetchComplete: true, skipped: 0, in: context
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<Device>()).first?.rack?.id, 44)

        _ = try NetBoxStore.applyRacks(
            [NetBoxRecord.Rack(
                id: 45, name: "R2", display: "R2", url: "u", created: nil, lastUpdated: nil,
                uHeight: 42, startingUnit: 1, deviceCount: 0, status: "active",
                formFactor: nil, siteID: 4, locationID: nil, roleID: nil
            )],
            fetchComplete: true, skipped: 0, in: context
        )
        let devices = try context.fetch(FetchDescriptor<Device>())
        XCTAssertEqual(devices.map(\.id), [10])
        XCTAssertNil(devices.first?.rack)
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
