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

    func testIdleCatchUpAppliesFrontPortAndAnnounces() async throws {
        let container = try makeContainer()
        try seedWatermark(container, id: 10)
        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/10/"] = Data(#"{"id":10}"#.utf8)
        fetcher.bodies["/api/core/object-changes/"] = Data("""
        {"count":1,"next":null,"results":[
          {"id":11,"action":{"value":"create"},
           "changed_object_type":"dcim.frontport","changed_object_id":7}
        ]}
        """.utf8)
        fetcher.bodies["/api/dcim/front-ports/7/"] = Data(
            #"{"id":7,"name":"1","device":{"id":5,"name":"panel"}}"#.utf8
        )
        let notes = NoteCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .netBoxStoreDidApply,
            object: nil,
            queue: nil
        ) { _ in
            notes.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        await engine.runIdleCatchUp()

        let ports = try ModelContext(container).fetch(FetchDescriptor<FrontPort>())
        XCTAssertTrue(ports.contains { $0.id == 7 })
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first?.lastObjectChangeId,
            11
        )
        XCTAssertEqual(notes.count, 1)
        XCTAssertFalse(fetcher.paths.contains("/api/dcim/devices/"))
        XCTAssertNil(
            try ModelContext(container).fetch(FetchDescriptor<Device>()).first { $0.id == 5 }?.seatGrantedAt
        )
    }

    func testIdleDeviceApplySeatsThatDeviceAndAnOlderOpenSlot() async throws {
        let container = try makeContainer()
        try seedWatermark(container, id: 10)
        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/10/"] = Data(#"{"id":10}"#.utf8)
        fetcher.bodies["/api/core/object-changes/"] = Data("""
        {"count":1,"next":null,"results":[
          {"id":11,"action":{"value":"create"},
           "changed_object_type":"dcim.device","changed_object_id":20}
        ]}
        """.utf8)
        fetcher.bodies["/api/dcim/devices/20/"] = Data(
            #"{"id":20,"name":"edge","site":{"id":1},"role":{"id":2},"device_type":{"id":8}}"#.utf8
        )
        let notices = NoticeBox()
        let token = NotificationCenter.default.addObserver(
            forName: .netBoxStoreDidApply,
            object: nil,
            queue: nil
        ) { note in
            notices.info = note.userInfo?[NetBoxApplyInfo.userInfoKey] as? NetBoxApplyInfo
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        await engine.runIdleCatchUp()

        let devices = try ModelContext(container).fetch(FetchDescriptor<Device>())
        XCTAssertNotNil(devices.first { $0.id == 20 }?.seatGrantedAt)
        XCTAssertNotNil(devices.first { $0.id == 5 }?.seatGrantedAt)
        XCTAssertEqual(notices.info?.origin, .sync)
        XCTAssertTrue(notices.info?.seatUpdate.granted.contains(20) == true)
        XCTAssertNil(notices.info?.seatUpdate.replaceSeated)
    }

    func testIdleYieldsBeforeTheNextChangelogPage() async throws {
        let container = try makeContainer()
        try seedWatermark(container, id: 10)
        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/10/"] = Data(#"{"id":10}"#.utf8)
        fetcher.armHold = true
        fetcher.idGtQueue = [
            Data("""
            {"count":2,"next":"https://netbox.example/api/core/object-changes/?offset=1","results":[
              {"id":11,"action":{"value":"create"},
               "changed_object_type":"dcim.device","changed_object_id":21}
            ]}
            """.utf8),
            Data("""
            {"count":2,"next":null,"results":[
              {"id":12,"action":{"value":"create"},
               "changed_object_type":"dcim.device","changed_object_id":22}
            ]}
            """.utf8),
        ]
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        async let idle: Void = engine.runIdleCatchUp()
        await fetcher.waitUntilListBlocked()
        let write = Task {
            try? await engine.patchInterface(id: 1, description: "held")
        }
        while await !engine.operatorWriteIsActive() {
            await Task.yield()
        }
        fetcher.releaseList()
        await idle
        _ = await write.value

        XCTAssertEqual(fetcher.idGtListCalls, 1)
        let devices = try ModelContext(container).fetch(FetchDescriptor<Device>())
        XCTAssertFalse(devices.contains { $0.id == 21 || $0.id == 22 })
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first?.lastObjectChangeId,
            10
        )
    }

    func testChainedWriteHoldsOffUserSync() async throws {
        let container = try makeContainer()
        let fetcher = GateFetcher()
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        async let first: Void = engine.createSite(
            NetBoxWriteBody.SiteCreate(name: "One", slug: "one", status: "active")
        )
        await fetcher.waitUntilSendCount(1)
        async let second: Void = engine.createSite(
            NetBoxWriteBody.SiteCreate(name: "Two", slug: "two", status: "active")
        )
        async let synced: Void = engine.fullSync()
        fetcher.allowOne()
        await fetcher.waitUntilSendCount(2)
        for _ in 0..<40 {
            await Task.yield()
        }
        let overlapped = fetcher.getsDuringSend
        XCTAssertTrue(overlapped.isEmpty, "user sync fetched during a chained write: \(overlapped)")
        fetcher.allowOne()
        try await first
        try await second
        try await synced
        XCTAssertGreaterThan(fetcher.deviceLists, 0)
    }

    func testIdleCatchUpSkipsSafetyMirror() async throws {
        let container = try makeContainer()
        let lastFull = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try seedWatermark(container, id: 10, lastFull: lastFull)
        let fetcher = DeltaFetcher()
        let notes = NoteCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .netBoxStoreDidApply,
            object: nil,
            queue: nil
        ) { _ in
            notes.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        await engine.runIdleCatchUp()

        XCTAssertTrue(fetcher.paths.isEmpty)
        XCTAssertEqual(notes.count, 0)
        let provider = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first
        )
        XCTAssertEqual(
            provider.lastFullMirrorAt?.timeIntervalSince1970 ?? 0,
            lastFull.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(provider.lastObjectChangeId, 10)
    }

    func testIdleCatchUpLeavesWatermarkWhenPageCapHits() async throws {
        let container = try makeContainer()
        try seedWatermark(container, id: 10)
        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/10/"] = Data(#"{"id":10}"#.utf8)
        fetcher.unlimitedNext = true
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        await engine.runIdleCatchUp()

        XCTAssertEqual(fetcher.idGtListCalls, NetBoxPageIterator.maxPages)
        XCTAssertFalse(fetcher.paths.contains("/api/dcim/devices/"))
        XCTAssertEqual(fetcher.latestCursorCalls, 0)
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first?.lastObjectChangeId,
            10
        )
        let status = await MainActor.run {
            RequestStatusManager.shared.currentStatus[.netbox]
        }
        XCTAssertEqual(
            status,
            .dataError(code: 0, message: "NetBox pagination exceeded the page safety limit")
        )

        await engine.runIdleCatchUp()
        XCTAssertEqual(fetcher.idGtListCalls, NetBoxPageIterator.maxPages)

        fetcher.unlimitedNext = false
        fetcher.bodies["/api/core/object-changes/"] = Data(
            #"{"count":0,"next":null,"results":[]}"#.utf8
        )
        try await engine.sync()
        XCTAssertEqual(fetcher.idGtListCalls, NetBoxPageIterator.maxPages + 1)
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first?.lastObjectChangeId,
            10
        )
    }

    func testSecondIdleCatchUpDoesNotListTwice() async throws {
        let container = try makeContainer()
        try seedWatermark(container, id: 10)
        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/10/"] = Data(#"{"id":10}"#.utf8)
        fetcher.bodies["/api/core/object-changes/"] = Data(#"{"count":0,"next":null,"results":[]}"#.utf8)
        fetcher.armHold = true
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)

        async let first: Void = engine.runIdleCatchUp()
        await fetcher.waitUntilListBlocked()
        await engine.runIdleCatchUp()
        XCTAssertEqual(fetcher.idGtListCalls, 1)
        fetcher.releaseList()
        await first
        XCTAssertEqual(fetcher.idGtListCalls, 1)
    }

    func testSyncAfterIdlePassAppliesAChangeTheIdlePassDidNotSee() async throws {
        let container = try makeContainer()
        try seedWatermark(container, id: 10)
        let fetcher = DeltaFetcher()
        fetcher.bodies["/api/core/object-changes/10/"] = Data(#"{"id":10}"#.utf8)
        fetcher.armHold = true
        fetcher.idGtQueue = [
            Data(#"{"count":0,"next":null,"results":[]}"#.utf8),
            Data("""
            {"count":1,"next":null,"results":[
              {"id":11,"action":{"value":"create"},
               "changed_object_type":"dcim.device","changed_object_id":20}
            ]}
            """.utf8),
        ]
        fetcher.bodies["/api/dcim/devices/20/"] = Data(
            #"{"id":20,"name":"edge","site":{"id":1},"role":{"id":2},"device_type":{"id":8}}"#.utf8
        )
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)

        async let idle: Void = engine.runIdleCatchUp()
        await fetcher.waitUntilListBlocked()
        async let synced: Void = engine.sync()
        fetcher.releaseList()
        await idle
        try await synced

        let devices = try ModelContext(container).fetch(FetchDescriptor<Device>())
        XCTAssertTrue(devices.contains { $0.id == 20 })
        XCTAssertEqual(fetcher.idGtListCalls, 2)
        XCTAssertFalse(fetcher.paths.contains("/api/dcim/devices/"))
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncProvider>()).first?.lastObjectChangeId,
            11
        )
    }

    func testFullSyncStillMirrorsWhileIdleListIsInFlight() async throws {
        let container = try makeContainer()
        try seedWatermark(container, id: 10)
        let fetcher = DeltaFetcher()
        fetcher.emptySuccess = true
        fetcher.bodies["/api/core/object-changes/10/"] = Data(#"{"id":10}"#.utf8)
        fetcher.armHold = true
        fetcher.idGtQueue = [Data(#"{"count":0,"next":null,"results":[]}"#.utf8)]
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)

        async let idle: Void = engine.runIdleCatchUp()
        await fetcher.waitUntilListBlocked()
        async let mirrored: Void = engine.fullSync()
        fetcher.releaseList()
        await idle
        try await mirrored

        XCTAssertGreaterThanOrEqual(fetcher.idGtListCalls, 1)
        XCTAssertTrue(fetcher.paths.contains("/api/dcim/devices/"))
    }

    private func seedWatermark(
        _ container: ModelContainer,
        id: Int64,
        lastFull: Date = Date()
    ) throws {
        let seed = ModelContext(container)
        seed.insert(Site(id: 1))
        seed.insert(Device(id: 5))
        let provider = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
        provider.lastObjectChangeId = id
        provider.lastFullMirrorAt = lastFull
        seed.insert(provider)
        try seed.save()
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

private final class NoticeBox: @unchecked Sendable {
    var info: NetBoxApplyInfo?
}

/// Lets one POST through at a time and records GETs that happen while a
/// POST is still blocked, which is the chained-write overlap.
private final class GateFetcher: NetBoxFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var sendStarts = 0
    private var permits = 0
    private var sendsInFlight = 0
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var permitWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var getsDuringSend: [String] = []
    private(set) var deviceLists = 0
    private let empty = Data(#"{"count":0,"next":null,"results":[]}"#.utf8)

    func waitUntilSendCount(_ count: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if sendStarts >= count {
                lock.unlock()
                cont.resume()
                return
            }
            enteredWaiters.append(cont)
            lock.unlock()
        }
    }

    func allowOne() {
        lock.lock()
        if permitWaiters.isEmpty {
            permits += 1
            lock.unlock()
            return
        }
        let next = permitWaiters.removeFirst()
        lock.unlock()
        next.resume()
    }

    func get(path: String, query: [URLQueryItem]) async throws -> Data {
        lock.lock()
        let duringSend = sendsInFlight > 0
        if duringSend && !path.hasPrefix("/api/dcim/sites/") {
            getsDuringSend.append(path)
        }
        if path == "/api/dcim/devices/" {
            deviceLists += 1
        }
        lock.unlock()
        if path.hasPrefix("/api/dcim/sites/"), path != "/api/dcim/sites/" {
            let id = path.split(separator: "/").last.map(String.init) ?? "0"
            let json = #"{"id":\#(id),"name":"Lab","slug":"lab","status":{"value":"active"}}"#
            return Data(json.utf8)
        }
        return empty
    }

    func send(_ request: NetBoxHTTPRequest) async throws -> NetBoxHTTPResponse {
        lock.lock()
        sendStarts += 1
        sendsInFlight += 1
        let id = sendStarts
        let pending = enteredWaiters
        enteredWaiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
        await waitForPermit()
        lock.lock()
        sendsInFlight -= 1
        lock.unlock()
        let json = #"{"id":\#(id),"name":"Lab","slug":"lab","status":{"value":"active"}}"#
        return NetBoxHTTPResponse(status: 201, body: Data(json.utf8), etag: nil)
    }

    private func waitForPermit() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if permits > 0 {
                permits -= 1
                lock.unlock()
                cont.resume()
                return
            }
            permitWaiters.append(cont)
            lock.unlock()
        }
    }
}

private final class NoteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// Blocks the first `id__gt` changelog list until `release()`.
private final class ListHold: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockFirstList() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                cont.resume()
                return
            }
            entered = true
            let pending = enterWaiters
            enterWaiters.removeAll()
            releaseWaiters.append(cont)
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered {
                lock.unlock()
                cont.resume()
                return
            }
            enterWaiters.append(cont)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
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
    var unlimitedNext = false
    var armHold = false
    var idGtQueue: [Data] = []
    private(set) var idGtListCalls = 0
    private let lock = NSLock()
    private let hold = ListHold()
    private let emptyPage = Data(#"{"count":0,"next":null,"results":[]}"#.utf8)
    private let nextPage = Data(
        #"{"count":1,"next":"https://netbox.example/api/core/object-changes/?offset=1","results":[{"id":1,"action":{"value":"update"},"changed_object_type":"extras.tag","changed_object_id":1}]}"#.utf8
    )

    func waitUntilListBlocked() async {
        await hold.waitUntilBlocked()
    }

    func releaseList() {
        hold.release()
    }

    func get(path: String, query: [URLQueryItem]) async throws -> Data {
        lock.lock()
        paths.append(path)
        lock.unlock()
        if transportOn.contains(path) {
            throw NetBoxSyncError.transport("killed")
        }
        if fail404.contains(path) {
            throw NetBoxSyncError.httpStatus(code: 404, body: "missing")
        }
        if path == "/api/core/object-changes/",
           query.contains(where: { $0.name == "ordering" && $0.value == "-id" }) {
            lock.lock()
            latestCursorCalls += 1
            let queued = latestCursorQueue.isEmpty ? nil : latestCursorQueue.removeFirst()
            lock.unlock()
            if let queued { return queued }
        }
        if path == "/api/core/object-changes/",
           query.contains(where: { $0.name == "id__gt" }) {
            lock.lock()
            idGtListCalls += 1
            let holdThis = armHold
            let queued = idGtQueue.isEmpty ? nil : idGtQueue.removeFirst()
            let repeatNext = unlimitedNext
            lock.unlock()
            if holdThis {
                await hold.blockFirstList()
            }
            if let queued { return queued }
            if repeatNext { return nextPage }
        }
        lock.lock()
        let body = bodies[path]
        lock.unlock()
        if let body { return body }
        if emptySuccess {
            return emptyPage
        }
        throw NetBoxSyncError.httpStatus(code: 404, body: path)
    }
}
