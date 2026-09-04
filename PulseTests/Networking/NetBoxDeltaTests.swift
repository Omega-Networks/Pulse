//
//  NetBoxDeltaTests.swift
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

final class NetBoxDeltaTests: XCTestCase {
    func testCoalesceKeepsLatestActionAndOrdersByFK() {
        let changes = [
            change(id: 1, type: "dcim.device", object: 10, action: "create"),
            change(id: 3, type: "dcim.device", object: 10, action: "delete"),
            change(id: 2, type: "dcim.site", object: 4, action: "update"),
            change(id: 4, type: "extras.tag", object: 1, action: "update"),
        ]
        let planned = NetBoxDelta.coalesce(changes)
        XCTAssertEqual(planned.skippedUnknown, 1)
        XCTAssertEqual(planned.items.map(\.kind), [.site, .device])
        XCTAssertEqual(planned.items.last?.action, "delete")
        XCTAssertEqual(planned.highWater?.id, 4)
    }

    func testCableJSONCollectsBothInterfaceTerminations() throws {
        let json = Data("""
        {
          "id": 1424,
          "display": "sw1:eth1 ↔ sw2:eth2",
          "type": {"value": "cat6", "label": "CAT6"},
          "status": {"value": "connected", "label": "Connected"},
          "tenant": {"id": 3, "name": "Omega"},
          "label": "uplink",
          "color": "f44336",
          "length": 15,
          "length_unit": {"value": "m", "label": "Meters"},
          "description": "core uplink",
          "bundle": null,
          "a_terminations": [{"object_type": "dcim.interface", "object_id": 1}],
          "b_terminations": [{"object_type": "dcim.interface", "object_id": 2}]
        }
        """.utf8)
        let cable = try NetBoxListDecoder.decodeObject(NetBoxRecord.Cable.self, from: json)
        XCTAssertEqual(cable.id, 1424)
        XCTAssertEqual(cable.interfaceIDs, [1, 2])
        XCTAssertEqual(cable.aInterfaceID, 1)
        XCTAssertEqual(cable.bInterfaceID, 2)
        XCTAssertEqual(cable.tenantID, 3)
        XCTAssertEqual(cable.tenantName, "Omega")
        XCTAssertEqual(cable.length, 15)
        XCTAssertEqual(cable.lengthUnit, "m")
        XCTAssertEqual(cable.colour, "f44336")
        XCTAssertEqual(cable.cableDescription, "core uplink")
        XCTAssertEqual(cable.type, "cat6")
        XCTAssertEqual(cable.status, "connected")
        XCTAssertNil(cable.bundleID)
    }

    func testCableTypeAsBareStringDoesNotSkip() throws {
        let json = Data("""
        {
          "id": 10,
          "type": "cat6",
          "status": "connected",
          "length_unit": "m",
          "a_terminations": [{"object_type": "dcim.interface", "object_id": 1}],
          "b_terminations": [{"object_type": "dcim.interface", "object_id": 2}]
        }
        """.utf8)
        let cable = try NetBoxListDecoder.decodeObject(NetBoxRecord.Cable.self, from: json)
        XCTAssertEqual(cable.type, "cat6")
        XCTAssertEqual(cable.status, "connected")
        XCTAssertEqual(cable.lengthUnit, "m")
        XCTAssertEqual(cable.interfaceIDs, [1, 2])
    }

    func testSyncWithoutWatermarkPerformsFullMirror() async throws {
        let container = try makeContainer()
        let fetcher = DeltaFetcher()
        fetcher.emptySuccess = true
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.sync()
        XCTAssertTrue(fetcher.paths.contains("/api/dcim/devices/"))
        let context = ModelContext(container)
        let provider = try XCTUnwrap(try context.fetch(FetchDescriptor<SyncProvider>()).first)
        XCTAssertNotNil(provider.lastFullMirrorAt)
        XCTAssertEqual(provider.lastObjectChangeId, 0)
    }

    func testWarmWatermarkDoesNotFullPull() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 1))
        seed.insert(Device(id: 10))
        let provider = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
        provider.lastObjectChangeId = 50
        provider.lastFullMirrorAt = Date()
        seed.insert(provider)
        try seed.save()

        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/50/"] = Data(#"{"id":50,"action":{"value":"update"},"changed_object_type":"dcim.device","changed_object_id":10}"#.utf8)
        fetcher.bodies["/api/core/object-changes/"] = Data(#"{"count":0,"next":null,"results":[]}"#.utf8)
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.sync()
        XCTAssertFalse(fetcher.paths.contains("/api/dcim/devices/"))
        XCTAssertTrue(fetcher.paths.contains("/api/core/object-changes/"))
        let after = ModelContext(container)
        XCTAssertEqual(try after.fetch(FetchDescriptor<SyncProvider>()).first?.lastDeltaSummary, "no changes")
    }

    func testWatermarkZeroDeltasFromTheBeginningWithoutProbingIdZero() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 1))
        seed.insert(Device(id: 10))
        let provider = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
        provider.lastObjectChangeId = 0
        provider.lastFullMirrorAt = Date()
        seed.insert(provider)
        try seed.save()

        let fetcher = DeltaFetcher()
        fetcher.fail404.insert("/api/core/object-changes/0/")
        fetcher.bodies["/api/core/object-changes/"] = Data(#"{"count":0,"next":null,"results":[]}"#.utf8)
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.sync()
        XCTAssertFalse(fetcher.paths.contains("/api/core/object-changes/0/"))
        XCTAssertFalse(fetcher.paths.contains("/api/dcim/devices/"))
        XCTAssertTrue(fetcher.paths.contains("/api/core/object-changes/"))
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first?.lastDeltaSummary,
            "no changes"
        )
    }

    func testDeleteActionRemovesRowAndMissingWatermarkForcesMirror() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 1))
        seed.insert(Device(id: 10))
        try seed.save()

        try NetBoxStore.deleteIDs(Device.self, ids: [10], in: ModelContext(container))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Device>()).isEmpty)

        let provider = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
        provider.lastObjectChangeId = 99
        provider.lastFullMirrorAt = Date()
        let seed2 = ModelContext(container)
        seed2.insert(Site(id: 1))
        seed2.insert(provider)
        try seed2.save()

        let fetcher = DeltaFetcher()
        fetcher.emptySuccess = true
        fetcher.fail404.insert("/api/core/object-changes/99/")
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.sync()
        XCTAssertTrue(fetcher.paths.contains("/api/dcim/devices/"))
    }

    func testFullMirrorStampsPreWalkCursorNotALaterHead() async throws {
        let container = try makeContainer()
        let fetcher = DeltaFetcher()
        fetcher.emptySuccess = true
        fetcher.latestCursorQueue = [
            Data(#"{"count":1,"next":null,"results":[{"id":7,"action":{"value":"update"},"changed_object_type":"dcim.device","changed_object_id":1}]}"#.utf8),
            Data(#"{"count":1,"next":null,"results":[{"id":99,"action":{"value":"update"},"changed_object_type":"dcim.device","changed_object_id":1}]}"#.utf8),
        ]
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.fullSync()
        let provider = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first
        )
        XCTAssertEqual(provider.lastObjectChangeId, 7)
        XCTAssertEqual(fetcher.latestCursorCalls, 1)
    }

    func testDeltaCreateAppliesRetrievedDevice() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let site = Site(id: 1)
        seed.insert(site)
        seed.insert(Device(id: 1))
        let provider = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
        provider.lastObjectChangeId = 10
        provider.lastFullMirrorAt = Date()
        seed.insert(provider)
        try seed.save()

        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/10/"] = Data(#"{"id":10}"#.utf8)
        fetcher.bodies["/api/core/object-changes/"] = Data("""
        {"count":1,"next":null,"results":[
          {"id":11,"time":"2026-08-13T00:00:00Z",
           "action":{"value":"create","label":"Created"},
           "changed_object_type":"dcim.device","changed_object_id":20,
           "request_id":"r1"}
        ]}
        """.utf8)
        fetcher.bodies["/api/dcim/devices/20/"] = Data("""
        {"id":20,"name":"edge","site":{"id":1},"role":{"id":2},"device_type":{"id":8}}
        """.utf8)
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.sync()
        let devices = try ModelContext(container).fetch(FetchDescriptor<Device>())
        XCTAssertTrue(devices.contains { $0.id == 20 })
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first?.lastObjectChangeId,
            11
        )
    }

    func testMidDeltaFailureDoesNotAdvanceWatermark() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 1))
        seed.insert(Device(id: 1))
        let provider = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
        provider.lastObjectChangeId = 10
        provider.lastFullMirrorAt = Date()
        seed.insert(provider)
        try seed.save()

        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/10/"] = Data(#"{"id":10}"#.utf8)
        fetcher.bodies["/api/core/object-changes/"] = Data("""
        {"count":1,"next":null,"results":[
          {"id":12,"action":{"value":"update"},
           "changed_object_type":"dcim.device","changed_object_id":1}
        ]}
        """.utf8)
        fetcher.fail404.insert("/api/dcim/devices/1/")
        fetcher.transportOn.insert("/api/dcim/devices/1/")
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        do {
            try await engine.sync()
            XCTFail("expected transport failure")
        } catch {
            // expected
        }
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first?.lastObjectChangeId,
            10
        )
    }

    func testRoleChangeKeepsTheDevice() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 1))
        seed.insert(Device(id: 30))
        let provider = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
        provider.lastObjectChangeId = 1
        provider.lastFullMirrorAt = Date()
        seed.insert(provider)
        try seed.save()

        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/1/"] = Data(#"{"id":1}"#.utf8)
        fetcher.bodies["/api/core/object-changes/"] = Data("""
        {"count":1,"next":null,"results":[
          {"id":2,"action":{"value":"update"},
           "changed_object_type":"dcim.device","changed_object_id":30}
        ]}
        """.utf8)
        fetcher.bodies["/api/dcim/devices/30/"] = Data("""
        {"id":30,"name":"hidden","site":{"id":1},"role":{"id":29},"device_type":{"id":8}}
        """.utf8)
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.sync()
        let devices = try ModelContext(container).fetch(FetchDescriptor<Device>())
        XCTAssertTrue(devices.contains { $0.id == 30 })
        XCTAssertEqual(devices.first { $0.id == 30 }?.name, "hidden")
    }

    private func change(
        id: Int64, type: String, object: Int64, action: String
    ) -> NetBoxRecord.ObjectChange {
        NetBoxRecord.ObjectChange(
            id: id,
            time: nil,
            action: action,
            changedObjectType: type,
            changedObjectID: object,
            requestID: "r"
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            SiteLocation.self, RackRole.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Interface.self, Cable.self, DeviceBay.self, FrontPort.self, Service.self,
            WebHostTrust.self, Event.self, SyncProvider.self, PowerSenseDevice.self,
            PowerSenseEvent.self, SSHCredential.self, KnownHost.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }
}

private final class DeltaFetcher: NetBoxFetching, @unchecked Sendable {
    var paths: [String] = []
    var bodies: [String: Data] = [:]
    var fail404: Set<String> = []
    var transportOn: Set<String> = []
    var emptySuccess = false
    var latestCursorQueue: [Data] = []
    var latestCursorCalls = 0
    private let emptyPage = Data(#"{"count":0,"next":null,"results":[]}"#.utf8)

    func get(path: String, query: [URLQueryItem]) async throws -> Data {
        paths.append(path)
        if transportOn.contains(path) {
            throw NetBoxSyncError.transport("killed")
        }
        if fail404.contains(path) {
            throw NetBoxSyncError.httpStatus(code: 404, body: "missing")
        }
        if path == "/api/core/object-changes/",
           query.contains(where: { $0.name == "ordering" && $0.value == "-id" }) {
            latestCursorCalls += 1
            if !latestCursorQueue.isEmpty {
                return latestCursorQueue.removeFirst()
            }
        }
        if let body = bodies[path] {
            return body
        }
        if emptySuccess {
            return emptyPage
        }
        throw NetBoxSyncError.httpStatus(code: 404, body: path)
    }
}
