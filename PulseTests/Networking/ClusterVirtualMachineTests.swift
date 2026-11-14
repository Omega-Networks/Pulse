//
//  ClusterVirtualMachineTests.swift
//  PulseTests
//
//  Copyright © 2025-present Omega Networks Limited.
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
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Darwin
import Foundation
import SwiftData
import XCTest
@testable import Pulse

final class ClusterVirtualMachineTests: XCTestCase {
    func testClusterJSONDecodesTypeGroupScopeAndCustomFields() throws {
        let cluster = try decodeCluster("""
        {
          "id": 4,
          "name": "pve",
          "type": { "id": 1, "name": "Proxmox" },
          "group": { "id": 2, "name": "Compute" },
          "status": { "value": "active", "label": "Active" },
          "tenant": { "id": 9 },
          "scope_type": "dcim.site",
          "scope_id": 3,
          "scope": { "name": "lab", "display": "Lab" },
          "custom_fields": { "zabbix_id": 77, "zabbix_instance": 2 }
        }
        """)
        XCTAssertEqual(cluster.name, "pve")
        XCTAssertEqual(cluster.typeName, "Proxmox")
        XCTAssertEqual(cluster.groupName, "Compute")
        XCTAssertEqual(cluster.status, "active")
        XCTAssertEqual(cluster.tenantID, 9)
        XCTAssertEqual(cluster.scopeType, "dcim.site")
        XCTAssertEqual(cluster.scopeID, 3)
        XCTAssertEqual(cluster.scopeName, "Lab")
        XCTAssertEqual(cluster.zabbixID, 77)
        XCTAssertEqual(cluster.zabbixInstance, 2)
    }

    func testClusterMissingNameStoresEmptyAndMissingTypeThrows() throws {
        let unnamed = try decodeCluster("""
        { "id": 1, "type": { "id": 1, "name": "Proxmox" } }
        """)
        XCTAssertEqual(unnamed.name, "")
        XCTAssertThrowsError(try decodeCluster("""
        { "id": 2, "name": "bare", "type": { "id": 1, "name": "" } }
        """))
    }

    func testClusterSiteScopeUsesThatSite() throws {
        let context = try makeContext()
        let record = try decodeCluster("""
        { "id": 4, "name": "pve", "type": { "name": "Proxmox" },
          "scope_type": "dcim.site", "scope_id": 3 }
        """)
        _ = try NetBoxStore.applyClusters([record], fetchComplete: true, skipped: 0, in: context)
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<Cluster>()).first)
        XCTAssertEqual(stored.siteId, 3)
    }

    func testClusterLocationScopeUsesTheLocationsSite() throws {
        let context = try makeContext()
        let location = SiteLocation(id: 7)
        location.siteId = 3
        context.insert(location)
        try context.save()
        let record = try decodeCluster("""
        { "id": 4, "name": "pve", "type": { "name": "Proxmox" },
          "scope_type": "dcim.location", "scope_id": 7 }
        """)
        _ = try NetBoxStore.applyClusters([record], fetchComplete: true, skipped: 0, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Cluster>()).first?.siteId, 3)
    }

    func testClusterRegionAndMissingLocationLeaveSiteUnset() throws {
        let context = try makeContext()
        let region = try decodeCluster("""
        { "id": 4, "name": "region", "type": { "name": "Proxmox" },
          "scope_type": "dcim.region", "scope_id": 1 }
        """)
        let missing = try decodeCluster("""
        { "id": 5, "name": "gone", "type": { "name": "Proxmox" },
          "scope_type": "dcim.location", "scope_id": 99 }
        """)
        _ = try NetBoxStore.applyClusters(
            [region, missing], fetchComplete: true, skipped: 0, in: context
        )
        let stored = try context.fetch(FetchDescriptor<Cluster>())
        XCTAssertEqual(stored.first { $0.id == 4 }?.siteId, 0)
        XCTAssertEqual(stored.first { $0.id == 5 }?.siteId, 0)
    }

    func testVirtualMachineJSONDecodesSizesAndPlacement() throws {
        let machine = try decodeVirtualMachine("""
        {
          "id": 8,
          "name": "web",
          "display": "web",
          "status": { "value": "active", "label": "Active" },
          "vcpus": "2.5",
          "memory": 4096,
          "disk": 20,
          "primary_ip": { "address": "192.0.2.10/24" },
          "site": { "id": 3 },
          "cluster": { "id": 4 },
          "device": { "id": 10 },
          "role": { "id": 2 },
          "custom_fields": { "zabbix_id": 12 }
        }
        """)
        XCTAssertEqual(machine.vcpus, 2.5)
        XCTAssertEqual(machine.memoryMB, 4096)
        XCTAssertEqual(machine.diskMB, 20)
        XCTAssertEqual(machine.primaryIP, "192.0.2.10/24")
        XCTAssertEqual(machine.siteID, 3)
        XCTAssertEqual(machine.clusterID, 4)
        XCTAssertEqual(machine.deviceID, 10)
        XCTAssertEqual(machine.roleID, 2)
        XCTAssertEqual(machine.zabbixID, 12)
    }

    func testMissingParentsStayNilAndDenormalizedIDsStay() throws {
        let context = try makeContext()
        let device = try decodeDevice("""
        { "id": 10, "name": "hv", "site": { "id": 1 }, "role": { "id": 2 },
          "device_type": { "id": 8 }, "cluster": { "id": 99 } }
        """)
        _ = try NetBoxStore.applyDevices([device], fetchComplete: false, skipped: 0, in: context)
        let storedDevice = try XCTUnwrap(try context.fetch(FetchDescriptor<Device>()).first)
        XCTAssertEqual(storedDevice.clusterId, 99)
        XCTAssertNil(storedDevice.cluster)

        let machine = try decodeVirtualMachine("""
        { "id": 8, "name": "web", "status": { "value": "active" },
          "site": { "id": 9 }, "cluster": { "id": 9 },
          "device": { "id": 9 }, "role": { "id": 9 } }
        """)
        _ = try NetBoxStore.applyVirtualMachines(
            [machine], fetchComplete: false, skipped: 0, in: context
        )
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<VirtualMachine>()).first)
        XCTAssertEqual(stored.siteId, 9)
        XCTAssertEqual(stored.clusterId, 9)
        XCTAssertEqual(stored.hostDeviceId, 9)
        XCTAssertNil(stored.site)
        XCTAssertNil(stored.cluster)
        XCTAssertNil(stored.hostDevice)
        XCTAssertNil(stored.role)
    }

    func testPortMappingsPresentIncludingEmptyDoNotFallBack() throws {
        let mapped = try decodeService("""
        { "id": 1, "name": "SSH", "parent_object_type": "dcim.device", "parent_object_id": 1,
          "port_mappings": ["tcp/22", "udp/161"],
          "protocol": { "value": "tcp", "label": "TCP" }, "ports": [22] }
        """)
        XCTAssertEqual(mapped.portMappings, ["tcp/22", "udp/161"])

        let empty = try decodeService("""
        { "id": 2, "name": "SSH", "parent_object_type": "dcim.device", "parent_object_id": 1,
          "port_mappings": [],
          "protocol": { "value": "tcp", "label": "TCP" }, "ports": [22] }
        """)
        XCTAssertEqual(empty.portMappings, [])
    }

    func testLegacyPortsUsedOnlyWhenMappingsAreAbsent() throws {
        let legacy = try decodeService("""
        { "id": 3, "name": "SSH", "parent_object_type": "dcim.device", "parent_object_id": 1,
          "protocol": { "value": "TCP", "label": "TCP" }, "ports": [22, 443] }
        """)
        XCTAssertEqual(legacy.portMappings, ["tcp/22", "tcp/443"])

        let nullProtocol = try decodeService("""
        { "id": 4, "name": "multi", "parent_object_type": "dcim.device", "parent_object_id": 1,
          "protocol": null, "ports": null }
        """)
        XCTAssertEqual(nullProtocol.portMappings, [])
    }

    func testServiceWiresVirtualMachineParent() throws {
        let context = try makeContext()
        let machine = VirtualMachine(id: 8)
        context.insert(machine)
        try context.save()
        _ = try NetBoxStore.applyServices(
            [
                NetBoxRecord.Service(
                    id: 91, name: "HTTPS", display: "HTTPS", url: "u",
                    serviceDescription: "", portMappings: ["tcp/443"],
                    ipAddresses: [], parentObjectType: "virtualization.virtualmachine",
                    parentObjectID: 8, parentName: "web"
                )
            ],
            fetchComplete: false,
            skipped: 0,
            in: context
        )
        let service = try XCTUnwrap(try context.fetch(FetchDescriptor<Service>()).first)
        XCTAssertEqual(service.virtualMachine?.id, 8)
        XCTAssertNil(service.device)
        XCTAssertEqual(service.ports(for: "TCP"), [443])
    }

    func testSkippedVirtualMachinesDoNotDelete() throws {
        let context = try makeContext()
        let first = virtualMachineRecord(1)
        _ = try NetBoxStore.applyVirtualMachines(
            [first], fetchComplete: true, skipped: 0, in: context
        )
        let second = virtualMachineRecord(2)
        _ = try NetBoxStore.applyVirtualMachines(
            [second], fetchComplete: true, skipped: 1, in: context
        )
        let kept = try context.fetch(FetchDescriptor<VirtualMachine>()).map(\.id).sorted()
        XCTAssertEqual(kept, [1, 2])
    }

    func testCoalesceSkipsClusterTypeAndVMInterface() {
        let planned = NetBoxDelta.coalesce([
            NetBoxRecord.ObjectChange(
                id: 1, time: nil, action: "update",
                changedObjectType: "virtualization.cluster", changedObjectID: 4, requestID: nil
            ),
            NetBoxRecord.ObjectChange(
                id: 2, time: nil, action: "update",
                changedObjectType: "virtualization.clustertype", changedObjectID: 1, requestID: nil
            ),
            NetBoxRecord.ObjectChange(
                id: 3, time: nil, action: "update",
                changedObjectType: "virtualization.vminterface", changedObjectID: 9, requestID: nil
            ),
            NetBoxRecord.ObjectChange(
                id: 4, time: nil, action: "create",
                changedObjectType: "virtualization.virtual_machine", changedObjectID: 8, requestID: nil
            ),
        ])
        XCTAssertEqual(planned.skippedUnknown, 2)
        XCTAssertEqual(planned.items.map(\.kind), [.cluster, .virtualMachine])
        XCTAssertEqual(planned.highWater?.id, 4)
    }

    func testEventOwnerPrefersDeviceThenVirtualMachineThenCluster() throws {
        let device = Device(id: 10)
        let machine = VirtualMachine(id: 8)
        let cluster = Cluster(id: 4)
        let event = Event(eventId: "1")
        event.device = device
        event.virtualMachine = machine
        event.cluster = cluster
        XCTAssertEqual(event.owner, .device(10))
        event.device = nil
        XCTAssertEqual(event.owner, .virtualMachine(8))
        event.virtualMachine = nil
        XCTAssertEqual(event.owner, .cluster(4))
        event.cluster = nil
        XCTAssertNil(event.owner)
    }

    func testApplyFiftyThousandVirtualMachinesByPage() throws {
        let context = try makeContext()
        context.insert(Site(id: 1))
        try context.save()

        let clusterCount = 500
        let vmCount = 50_000
        let pageSize = 1_000
        let clock = ContinuousClock()
        let started = clock.now

        let clusters = (1...clusterCount).map { id in
            NetBoxRecord.Cluster(
                id: Int64(id), name: "c\(id)", typeName: "Proxmox", groupName: nil,
                status: "active", tenantID: nil, scopeType: "dcim.site", scopeID: 1,
                scopeName: "Lab", zabbixID: 0, zabbixInstance: 0
            )
        }
        _ = try NetBoxStore.applyClusters(clusters, fetchComplete: true, skipped: 0, in: context)

        var accepted = Set<Int64>()
        accepted.reserveCapacity(vmCount)
        var start = 1
        while start <= vmCount {
            let end = min(start + pageSize - 1, vmCount)
            let page = (start...end).map { virtualMachineRecord($0, clusterCount: clusterCount) }
            _ = try NetBoxStore.applyVirtualMachines(
                page, fetchComplete: false, skipped: 0, in: context
            )
            accepted.formUnion(page.map(\.id))
            start = end + 1
        }
        _ = try NetBoxStore.applyVirtualMachines(
            [], fetchComplete: true, skipped: 0, keeping: accepted, in: context
        )

        let elapsed = clock.now - started
        let peak = peakResidentBytes()
        let line = "apply \(clusterCount) clusters and \(vmCount) VMs: \(elapsed) peak \(peak) bytes"
        fputs(line + "\n", stderr)
        XCTContext.runActivity(named: line) { _ in }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Cluster>()), clusterCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VirtualMachine>()), vmCount)
        let sampleID: Int64 = 1
        var sample = FetchDescriptor<VirtualMachine>(
            predicate: #Predicate { $0.id == sampleID }
        )
        sample.fetchLimit = 1
        let row = try XCTUnwrap(try context.fetch(sample).first)
        XCTAssertEqual(row.name, "vm-1")
        XCTAssertEqual(row.clusterId, 1)
        XCTAssertEqual(row.siteId, 1)
    }

    private func decodeCluster(_ json: String) throws -> NetBoxRecord.Cluster {
        try NetBoxListDecoder.makeDecoder().decode(NetBoxRecord.Cluster.self, from: Data(json.utf8))
    }

    private func decodeVirtualMachine(_ json: String) throws -> NetBoxRecord.VirtualMachine {
        try NetBoxListDecoder.makeDecoder().decode(
            NetBoxRecord.VirtualMachine.self, from: Data(json.utf8)
        )
    }

    private func decodeDevice(_ json: String) throws -> NetBoxRecord.Device {
        try NetBoxListDecoder.makeDecoder().decode(NetBoxRecord.Device.self, from: Data(json.utf8))
    }

    private func decodeService(_ json: String) throws -> NetBoxRecord.Service {
        try NetBoxListDecoder.makeDecoder().decode(NetBoxRecord.Service.self, from: Data(json.utf8))
    }

    private func virtualMachineRecord(_ id: Int, clusterCount: Int = 1) -> NetBoxRecord.VirtualMachine {
        let clusterID = Int64((id - 1) % clusterCount + 1)
        return NetBoxRecord.VirtualMachine(
            id: Int64(id), name: "vm-\(id)", display: nil, url: nil,
            created: nil, lastUpdated: nil, status: "active", serial: "",
            vcpus: 1, memoryMB: 512, diskMB: 8, primaryIP: nil,
            siteID: 1, clusterID: clusterID, deviceID: nil, roleID: nil,
            zabbixID: 0, zabbixInstance: 0
        )
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            SiteLocation.self, RackRole.self,
            Rack.self, SiteGroup.self, Site.self, Cluster.self, VirtualMachine.self,
            Device.self, Interface.self, Cable.self, DeviceBay.self, FrontPort.self, Service.self,
            WebHostTrust.self, Event.self, SyncProvider.self, PowerSenseDevice.self,
            PowerSenseEvent.self, SSHCredential.self, KnownHost.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }
}

private func peakResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size_max)
}
