//
//  ServicePropertiesDecodingTests.swift
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
import SwiftData
import XCTest
@testable import Pulse

/// Locks down NetBox service ingest and the device-parent vs VM-parent wiring gate.
final class ServicePropertiesDecodingTests: XCTestCase {

    private func decode(_ json: Data) throws -> NetBoxRecord.Service {
        try NetBoxListDecoder.makeDecoder().decode(NetBoxRecord.Service.self, from: json)
    }

    func testDecodeDeviceParentedService() throws {
        let json = Data("""
        {
          "id": 7,
          "url": "https://netbox.example.com/api/ipam/services/7/",
          "display": "SSH (TCP/22)",
          "parent_object_type": "dcim.device",
          "parent_object_id": 6023,
          "parent": { "id": 6023, "name": "core-switch-01", "description": "Example switch" },
          "name": "SSH",
          "protocol": { "value": "tcp", "label": "TCP" },
          "ports": [22],
          "ipaddresses": [ { "id": 2275, "address": "192.0.2.10/24", "family": { "value": 4, "label": "IPv4" } } ],
          "description": "Secure shell access"
        }
        """.utf8)

        let service = try decode(json)
        XCTAssertEqual(service.id, 7)
        XCTAssertEqual(service.name, "SSH")
        XCTAssertEqual(service.display, "SSH (TCP/22)")
        XCTAssertEqual(service.url, "https://netbox.example.com/api/ipam/services/7/")
        XCTAssertEqual(service.serviceDescription, "Secure shell access")
        XCTAssertEqual(service.protocolValue, "tcp")
        XCTAssertEqual(service.protocolLabel, "TCP")
        XCTAssertEqual(service.ports, [22])
        XCTAssertEqual(service.ipAddresses, ["192.0.2.10/24"])
        XCTAssertEqual(service.parentObjectType, "dcim.device")
        XCTAssertEqual(service.parentObjectID, 6023)
        XCTAssertEqual(service.parentName, "core-switch-01")

        let model = Service(id: service.id)
        model.ipAddresses = service.ipAddresses
        XCTAssertEqual(model.primaryIPAddress, "192.0.2.10")
    }

    func testDecodeVirtualMachineParentedServiceIsRetained() throws {
        let json = Data("""
        {
          "id": 91,
          "url": "https://netbox.example.com/api/ipam/services/91/",
          "display": "HTTPS (TCP/443)",
          "parent_object_type": "virtualization.virtualmachine",
          "parent_object_id": 4410,
          "parent": { "id": 4410, "name": "web-frontend-01", "description": "Web frontend VM" },
          "name": "HTTPS",
          "protocol": { "value": "tcp", "label": "TCP" },
          "ports": [443, 8443],
          "ipaddresses": [ { "id": 9001, "address": "198.51.100.20/24", "family": { "value": 4, "label": "IPv4" } } ],
          "description": "Web frontend"
        }
        """.utf8)

        let service = try decode(json)
        XCTAssertEqual(service.id, 91)
        XCTAssertEqual(service.parentObjectType, "virtualization.virtualmachine")
        XCTAssertEqual(service.parentObjectID, 4410)
        XCTAssertEqual(service.parentName, "web-frontend-01")
        XCTAssertEqual(service.ports, [443, 8443])

        let model = Service(id: service.id)
        model.name = service.name
        model.ports = service.ports
        model.ipAddresses = service.ipAddresses
        model.parentObjectType = service.parentObjectType
        model.parentObjectId = service.parentObjectID
        model.parentName = service.parentName
        XCTAssertNil(model.device)
        XCTAssertEqual(model.parentName, "web-frontend-01")
        XCTAssertEqual(model.primaryIPAddress, "198.51.100.20")
    }

    func testDecodeServicesThroughListDecoder() throws {
        let json = Data("""
        { "count": 1, "next": null, "previous": null, "results": [
          { "id": 7, "url": "u", "display": "SSH (TCP/22)",
            "parent_object_type": "dcim.device", "parent_object_id": 6023,
            "parent": { "id": 6023, "name": "core-switch-01" },
            "name": "SSH", "protocol": { "value": "tcp", "label": "TCP" },
            "ports": [22],
            "ipaddresses": [ { "id": 2275, "address": "192.0.2.10/24" } ],
            "description": "Secure shell access" }
        ] }
        """.utf8)

        let page = try NetBoxListDecoder.decodePage(NetBoxRecord.Service.self, from: json)
        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(page.results.first?.ports, [22])
        XCTAssertEqual(page.results.first?.ipAddresses, ["192.0.2.10/24"])
        XCTAssertNil(page.next)
    }

    func testServiceWithoutParentIsRejected() {
        let json = Data("""
        { "id": 5, "name": "orphan", "protocol": { "value": "tcp", "label": "TCP" }, "ports": [1] }
        """.utf8)
        XCTAssertThrowsError(try decode(json))
    }

    func testMalformedIPAddressElementIsSkippedAndGoodRetained() throws {
        let json = Data("""
        {
          "id": 12, "url": "u", "display": "HTTPS (TCP/443)",
          "parent_object_type": "dcim.device", "parent_object_id": 6023,
          "parent": { "id": 6023, "name": "core-switch-01" },
          "name": "HTTPS", "protocol": { "value": "tcp", "label": "TCP" },
          "ports": [443],
          "ipaddresses": [
            { "id": 1, "address": "192.0.2.10/24" },
            "this-element-is-malformed",
            { "id": 2, "address": "198.51.100.20/24" }
          ],
          "description": ""
        }
        """.utf8)
        let service = try decode(json)
        XCTAssertEqual(service.ipAddresses, ["192.0.2.10/24", "198.51.100.20/24"])
    }

    func testGetServicesWiresDeviceParentAndRetainsVMParent() async throws {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            SiteLocation.self, RackRole.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Interface.self, Cable.self, DeviceBay.self, FrontPort.self, Service.self, WebHostTrust.self,
            Event.self, SyncProvider.self, PowerSenseDevice.self, PowerSenseEvent.self,
            SSHCredential.self, KnownHost.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])

        let seed = ModelContext(container)
        seed.insert(Device(id: 6023))
        try seed.save()

        _ = try NetBoxStore.applyServices(
            [
                NetBoxRecord.Service(
                    id: 7, name: "HTTPS", display: "HTTPS (TCP/8006)", url: "u",
                    serviceDescription: "", protocolValue: "tcp", protocolLabel: "TCP",
                    ports: [8006], ipAddresses: ["10.0.0.1/24"],
                    parentObjectType: "dcim.device", parentObjectID: 6023, parentName: "PVE"
                ),
                NetBoxRecord.Service(
                    id: 91, name: "HTTPS", display: "HTTPS (TCP/443)", url: "u",
                    serviceDescription: "", protocolValue: "tcp", protocolLabel: "TCP",
                    ports: [443], ipAddresses: ["10.0.0.2/24"],
                    parentObjectType: "virtualization.virtualmachine",
                    parentObjectID: 4410, parentName: "vm"
                )
            ],
            fetchComplete: true,
            skipped: 0,
            in: ModelContext(container)
        )

        let services = try ModelContext(container).fetch(FetchDescriptor<Service>())
        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services.first { $0.id == 7 }?.device?.id, 6023)
        XCTAssertNil(services.first { $0.id == 91 }?.device)
    }
}
