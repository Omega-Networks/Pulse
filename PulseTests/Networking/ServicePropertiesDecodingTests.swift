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
import XCTest
@testable import Pulse

/// Locks down the NetBox Application Service decoder (Slice W1). These cases are
/// hermetic on purpose: they decode the real `/api/ipam/services/` payload shape
/// through `JSONDecoder` and assert the result, with no `ModelContainer`. The
/// live upsert + persistence round trip (`getServices()` against a populated
/// NetBox) is an integration concern, not a headless unit one.
final class ServicePropertiesDecodingTests: XCTestCase {

    // MARK: - Device-parented service (the canonical payload)

    func testDecodeDeviceParentedService() throws {
        let json = Data("""
        {
          "id": 7,
          "url": "https://netbox.omega.net.nz/api/ipam/services/7/",
          "display": "SSH (TCP/22)",
          "parent_object_type": "dcim.device",
          "parent_object_id": 6023,
          "parent": { "id": 6023, "name": "OMG-08-010-LP-PB01", "description": "Proxmox Backup Server" },
          "name": "SSH",
          "protocol": { "value": "tcp", "label": "TCP" },
          "ports": [22],
          "ipaddresses": [ { "id": 2275, "address": "172.27.10.201/24", "family": { "value": 4, "label": "IPv4" } } ],
          "description": "Secure shell access"
        }
        """.utf8)

        let service = try JSONDecoder().decode(ServiceProperties.self, from: json)

        XCTAssertEqual(service.id, 7)
        XCTAssertEqual(service.name, "SSH")
        XCTAssertEqual(service.display, "SSH (TCP/22)")
        XCTAssertEqual(service.url, "https://netbox.omega.net.nz/api/ipam/services/7/")
        XCTAssertEqual(service.serviceDescription, "Secure shell access")

        // Nested protocol object.
        XCTAssertEqual(service.protocolValue, "tcp")
        XCTAssertEqual(service.protocolLabel, "TCP")

        // Top-level ports array.
        XCTAssertEqual(service.ports, [22])

        // ipaddresses[].address pulled out in CIDR form.
        XCTAssertEqual(service.ipAddresses, ["172.27.10.201/24"])

        // Flat parent fields plus the nested parent.name.
        XCTAssertEqual(service.parentObjectType, "dcim.device")
        XCTAssertEqual(service.parentObjectId, 6023)
        XCTAssertEqual(service.parentName, "OMG-08-010-LP-PB01")

        // Model layer: the bare-IP helper strips CIDR like Device does.
        let model = Service(id: service.id)
        model.ipAddresses = service.ipAddresses
        XCTAssertEqual(model.primaryIPAddress, "172.27.10.201")
    }

    // MARK: - VM-parented service is retained, not dropped

    func testDecodeVirtualMachineParentedServiceIsRetained() throws {
        let json = Data("""
        {
          "id": 91,
          "url": "https://netbox.omega.net.nz/api/ipam/services/91/",
          "display": "HTTPS (TCP/443)",
          "parent_object_type": "virtualization.virtualmachine",
          "parent_object_id": 4410,
          "parent": { "id": 4410, "name": "omg-vm-web01", "description": "Web frontend VM" },
          "name": "HTTPS",
          "protocol": { "value": "tcp", "label": "TCP" },
          "ports": [443, 8443],
          "ipaddresses": [ { "id": 9001, "address": "10.8.0.50/24", "family": { "value": 4, "label": "IPv4" } } ],
          "description": "Web frontend"
        }
        """.utf8)

        // Decoding must SUCCEED for a VM parent: retained, not dropped, no throw.
        let service = try JSONDecoder().decode(ServiceProperties.self, from: json)
        XCTAssertEqual(service.id, 91)
        XCTAssertEqual(service.parentObjectType, "virtualization.virtualmachine")
        XCTAssertEqual(service.parentObjectId, 4410)
        XCTAssertEqual(service.parentName, "omg-vm-web01")
        XCTAssertEqual(service.ports, [443, 8443])

        // Model layer: a VM-parented service maps onto the model with all its
        // data and a nil device relationship. processServiceBatch wires `device`
        // only for "dcim.device" parents, so a VM-parented row is retained with
        // device == nil rather than dropped.
        let model = Service(id: service.id)
        model.name = service.name
        model.ports = service.ports
        model.ipAddresses = service.ipAddresses
        model.parentObjectType = service.parentObjectType
        model.parentObjectId = service.parentObjectId
        model.parentName = service.parentName
        // No device wired because parentObjectType != "dcim.device".
        XCTAssertNil(model.device)
        XCTAssertEqual(model.parentName, "omg-vm-web01")
        XCTAssertEqual(model.primaryIPAddress, "10.8.0.50")
    }

    // MARK: - Array decode via the production Wrapper

    func testDecodeServicesThroughWrapper() throws {
        let json = Data("""
        { "count": 1, "next": null, "previous": null, "results": [
          { "id": 7, "url": "u", "display": "SSH (TCP/22)",
            "parent_object_type": "dcim.device", "parent_object_id": 6023,
            "parent": { "id": 6023, "name": "OMG-08-010-LP-PB01" },
            "name": "SSH", "protocol": { "value": "tcp", "label": "TCP" },
            "ports": [22],
            "ipaddresses": [ { "id": 2275, "address": "172.27.10.201/24" } ],
            "description": "Secure shell access" }
        ] }
        """.utf8)

        let wrapper = try JSONDecoder().decode(Wrapper<ServiceProperties>.self, from: json)
        XCTAssertEqual(wrapper.results.count, 1)
        XCTAssertEqual(wrapper.results.first?.ports, [22])
        XCTAssertEqual(wrapper.results.first?.ipAddresses, ["172.27.10.201/24"])
        XCTAssertNil(wrapper.next)
    }

    // MARK: - Missing required fields are skipped (guard/throw)

    func testServiceWithoutParentIsRejected() {
        // No parent_object_type / parent_object_id: a service that cannot be
        // wired or surfaced. The decoder throws SwiftDataError.missingData,
        // mirroring DeviceRoleProperties.
        let json = Data("""
        { "id": 5, "name": "orphan", "protocol": { "value": "tcp", "label": "TCP" }, "ports": [1] }
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ServiceProperties.self, from: json)) { error in
            guard let swiftDataError = error as? SwiftDataError,
                  case .missingData = swiftDataError else {
                return XCTFail("Expected SwiftDataError.missingData, got \(error)")
            }
        }
    }
}
