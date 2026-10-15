//
//  PendingWritesTests.swift
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

final class PendingWritesTests: XCTestCase {
    private var cleanup: (@Sendable () async -> Void)?

    override func tearDown() async throws {
        await cleanup?()
        cleanup = nil
        await MainActor.run {
            OperatorNoticeCenter.shared.clear(source: .netbox)
        }
    }

    func testSubmitStagesPostingBeforeTheResponse() async throws {
        let harness = try makeHarness()
        let gate = PauseGate()
        harness.fetcher.beforeSend = { _ in await gate.arriveAndWait() }
        harness.fetcher.sendResults = [.success(created(id: 30, name: "core-1"))]
        remember(harness, gate: gate)

        let tokens = await harness.engine.submit([intent(name: "core-1")])
        try await gate.waitForArrival()

        let token = try XCTUnwrap(tokens.first)
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .posting)
        XCTAssertEqual(harness.fetcher.sends.map(\.path), ["/api/dcim/devices/"])
        XCTAssertFalse(try deviceIDs(harness.container).contains(30))
        let here = await MainActor.run { harness.pending.ghosts(of: DeviceCreateIntent.self, at: 4) }
        let elsewhere = await MainActor.run { harness.pending.ghosts(of: DeviceCreateIntent.self, at: 9) }
        XCTAssertEqual(here.map(\.token), [token])
        XCTAssertTrue(elsewhere.isEmpty)
    }

    func testCommittedStaysUntilTheApplyAfterTheStore() async throws {
        let harness = try makeHarness()
        let gate = PauseGate()
        harness.fetcher.beforeGet = { path in
            guard path == "/api/dcim/interfaces/" else { return }
            await gate.arriveAndWait()
        }
        harness.fetcher.sendResults = [.success(created(id: 30, name: "core-1"))]
        harness.fetcher.getBodies["/api/dcim/interfaces/"] = emptyInterfaces
        remember(harness, gate: gate)

        let tokens = await harness.engine.submit([intent(name: "core-1")])
        try await gate.waitForArrival()

        let token = try XCTUnwrap(tokens.first)
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .committed(id: 30))
        XCTAssertTrue(try deviceIDs(harness.container).contains(30))
        let ghosts = await MainActor.run { harness.pending.ghosts(of: DeviceCreateIntent.self, at: 4) }
        XCTAssertEqual(ghosts.map(\.token), [token])

        await gate.open()
        await harness.engine.waitForSubmittedWrites()
        let after = await MainActor.run { harness.pending.ghosts(of: DeviceCreateIntent.self, at: 4) }
        XCTAssertTrue(after.isEmpty)
        XCTAssertTrue(try deviceIDs(harness.container).contains(30))
    }

    func testValidationFailureKeepsTheAsk() async throws {
        let harness = try makeHarness()
        remember(harness)
        harness.fetcher.sendResults = [
            .failure(NetBoxSyncError.httpStatus(code: 400, body: "name already exists"))
        ]
        let tokens = await harness.engine.submit([intent(name: "core-1")])
        await harness.engine.waitForSubmittedWrites()

        let token = try XCTUnwrap(tokens.first)
        let state = await MainActor.run { harness.pending.state(of: token) }
        let error = NetBoxSyncError.httpStatus(code: 400, body: "name already exists")
        XCTAssertEqual(state, .failed(error))
        let posted = await notice(token)
        XCTAssertEqual(posted?.message, error.noticeMessage)
        XCTAssertEqual(posted?.source, .netbox)
        XCTAssertEqual(posted?.id, PendingWrites.noticeID(token))
        XCTAssertEqual(harness.fetcher.sends.count, 1)
        XCTAssertFalse(try deviceIDs(harness.container).contains(30))
        let elsewhere = await MainActor.run { harness.pending.ghosts(of: DeviceCreateIntent.self, at: 9) }
        XCTAssertTrue(elsewhere.isEmpty)
    }

    func testTransportFailureUsesTheOfflineSentence() async throws {
        let harness = try makeHarness()
        remember(harness)
        let sentence = "NetBox is unreachable. The change was not saved."
        harness.fetcher.sendResults = [.failure(NetBoxSyncError.transport(sentence))]
        let tokens = await harness.engine.submit([intent(name: "core-1")])
        await harness.engine.waitForSubmittedWrites()

        let token = try XCTUnwrap(tokens.first)
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .failed(.transport(sentence)))
        let posted = await notice(token)
        XCTAssertEqual(posted?.message, sentence)
        XCTAssertTrue(harness.fetcher.sends.isEmpty == false)
        XCTAssertFalse(try deviceIDs(harness.container).contains(30))
    }

    func testDiscardClearsTheAskAndTheNotice() async throws {
        let harness = try makeHarness()
        remember(harness)
        harness.fetcher.sendResults = [
            .failure(NetBoxSyncError.httpStatus(code: 400, body: "name already exists"))
        ]
        let tokens = await harness.engine.submit([intent(name: "core-1")])
        await harness.engine.waitForSubmittedWrites()
        let token = try XCTUnwrap(tokens.first)
        await harness.engine.discard(token)

        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertNil(state)
        let posted = await notice(token)
        XCTAssertNil(posted)
    }

    func testCapRefusalDoesNotPost() async throws {
        let harness = try makeHarness(grantedDevices: 50)
        remember(harness)
        let tokens = await harness.engine.submit([intent(name: "over-cap")])
        await harness.engine.waitForSubmittedWrites()

        let token = try XCTUnwrap(tokens.first)
        let cap = BillingError.tierCapReached(.free).localizedDescription
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .failed(.httpStatus(code: 0, body: cap)))
        let posted = await notice(token)
        XCTAssertEqual(posted?.message, cap)
        XCTAssertTrue(harness.fetcher.sends.isEmpty)
    }

    func testBatchContinuesAfterAFailure() async throws {
        let harness = try makeHarness()
        remember(harness)
        harness.fetcher.sendResults = [
            .failure(NetBoxSyncError.httpStatus(code: 400, body: "name already exists")),
            .success(created(id: 31, name: "core-2")),
        ]
        harness.fetcher.getBodies["/api/dcim/interfaces/"] = emptyInterfaces
        let tokens = await harness.engine.submit([
            intent(name: "core-1"),
            intent(name: "core-2"),
        ])
        await harness.engine.waitForSubmittedWrites()

        let failed = try XCTUnwrap(tokens.first)
        let committed = try XCTUnwrap(tokens.last)
        let failedState = await MainActor.run { harness.pending.state(of: failed) }
        XCTAssertEqual(failedState, .failed(.httpStatus(code: 400, body: "name already exists")))
        let ghosts = await MainActor.run { harness.pending.ghosts(of: DeviceCreateIntent.self, at: 4) }
        XCTAssertEqual(ghosts.map(\.token), [failed])
        let committedState = await MainActor.run { harness.pending.state(of: committed) }
        XCTAssertNil(committedState)
        XCTAssertTrue(try deviceIDs(harness.container).contains(31))
        XCTAssertFalse(try deviceIDs(harness.container).contains(30))
    }

    private func remember(_ harness: Harness, gate: PauseGate? = nil) {
        let engine = harness.engine
        cleanup = {
            await gate?.open()
            await engine.waitForSubmittedWrites()
        }
    }

    private func notice(_ token: WriteToken) async -> OperatorNotice? {
        await MainActor.run {
            OperatorNoticeCenter.shared.notices.first { $0.id == PendingWrites.noticeID(token) }
        }
    }

    func testCableAskStaysUntilBothEndsAreStored() async throws {
        let harness = try makeHarness()
        try seedCableEnds(in: harness.container, billable: false)
        let gate = PauseGate()
        harness.fetcher.beforeGet = { path in
            guard path == "/api/dcim/interfaces/88/" else { return }
            await gate.arriveAndWait()
        }
        harness.fetcher.sendResults = [.success(cableCreated(id: 9))]
        harness.fetcher.getBodies["/api/dcim/interfaces/88/"] = cableEndJSON(id: 88, peer: 89)
        harness.fetcher.getBodies["/api/dcim/interfaces/89/"] = cableEndJSON(id: 89, peer: 88)
        remember(harness, gate: gate)

        let tokens = await harness.engine.submit([cableIntent()])
        try await gate.waitForArrival()

        let token = try XCTUnwrap(tokens.first)
        let committed = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(committed, .committed(id: 9))
        XCTAssertEqual(harness.fetcher.sends.map(\.path), ["/api/dcim/cables/"])
        XCTAssertTrue(try cableIDs(harness.container).contains(9))
        let here = await MainActor.run { harness.pending.ghosts(of: CableCreateIntent.self, at: 4) }
        XCTAssertEqual(here.map(\.token), [token])

        await gate.open()
        await harness.engine.waitForSubmittedWrites()
        let after = await MainActor.run { harness.pending.ghosts(of: CableCreateIntent.self, at: 4) }
        XCTAssertTrue(after.isEmpty)
        XCTAssertFalse(harness.fetcher.gets.contains("/api/dcim/cables/9/"))
    }

    func testCableNetBoxStoredIsNotFailedWhenTheEndsCannotLoad() async throws {
        let harness = try makeHarness()
        try seedCableEnds(in: harness.container, billable: false)
        remember(harness)
        harness.fetcher.sendResults = [.success(cableCreated(id: 9))]
        harness.fetcher.getFailures["/api/dcim/interfaces/88/"] = NetBoxSyncError.transport(
            "NetBox is unreachable. The change was not saved."
        )
        let tokens = await harness.engine.submit([cableIntent()])
        await harness.engine.waitForSubmittedWrites()

        let token = try XCTUnwrap(tokens.first)
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertNil(state, "NetBox stored the cable, so the ask is retired, not failed")
        let posted = await notice(token)
        XCTAssertNil(posted)
        XCTAssertTrue(try cableIDs(harness.container).contains(9))
    }

    func testCableValidationKeepsTheAsk() async throws {
        let harness = try makeHarness()
        try seedCableEnds(in: harness.container, billable: false)
        remember(harness)
        harness.fetcher.sendResults = [
            .failure(NetBoxSyncError.httpStatus(code: 400, body: "termination already cabled"))
        ]
        let tokens = await harness.engine.submit([cableIntent()])
        await harness.engine.waitForSubmittedWrites()

        let token = try XCTUnwrap(tokens.first)
        let error = NetBoxSyncError.httpStatus(code: 400, body: "termination already cabled")
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .failed(error))
        let posted = await notice(token)
        XCTAssertEqual(posted?.message, error.noticeMessage)
        XCTAssertFalse(try cableIDs(harness.container).contains(9))
    }

    func testCableLinkRefusalDoesNotPost() async throws {
        let harness = try makeHarness(grantedDevices: 50)
        try seedCableEnds(in: harness.container, billable: true)
        remember(harness)
        let tokens = await harness.engine.submit([cableIntent()])
        await harness.engine.waitForSubmittedWrites()

        let token = try XCTUnwrap(tokens.first)
        let message = BillingError.linkRequiresBothSeats.localizedDescription
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .failed(.httpStatus(code: 0, body: message)))
        let posted = await notice(token)
        XCTAssertEqual(posted?.message, message)
        XCTAssertTrue(harness.fetcher.sends.isEmpty)
    }

    func testCreateCableDoesNotStageAnAsk() async throws {
        let harness = try makeHarness()
        try seedCableEnds(in: harness.container, billable: false)
        remember(harness)
        harness.fetcher.sendResults = [.success(cableCreated(id: 9))]
        harness.fetcher.getBodies["/api/dcim/interfaces/88/"] = cableEndJSON(id: 88, peer: 89)
        harness.fetcher.getBodies["/api/dcim/interfaces/89/"] = cableEndJSON(id: 89, peer: 88)
        try await harness.engine.createCable(from: 88, to: 89)

        let ghosts = await MainActor.run { harness.pending.ghosts(of: CableCreateIntent.self, at: 4) }
        XCTAssertTrue(ghosts.isEmpty)
        XCTAssertTrue(try cableIDs(harness.container).contains(9))
        XCTAssertEqual(harness.fetcher.sends.map(\.path), ["/api/dcim/cables/"])
    }

    private func intent(name: String) -> DeviceCreateIntent {
        DeviceCreateIntent(
            body: NetBoxWriteBody.DeviceCreate(
                name: name, deviceType: 8, role: 1, site: 4, status: "active"
            ),
            uHeight: 1
        )
    }

    private func created(id: Int64, name: String) -> NetBoxHTTPResponse {
        NetBoxHTTPResponse(
            status: 201,
            body: Data(
                #"{"id":\#(id),"name":"\#(name)","site":{"id":4},"role":{"id":1},"device_type":{"id":8}}"#.utf8
            ),
            etag: nil
        )
    }

    private var emptyInterfaces: Data {
        Data(#"{"count":0,"next":null,"results":[]}"#.utf8)
    }

    private func cableIntent() -> CableCreateIntent {
        CableCreateIntent(
            body: .connecting(88, to: 89),
            siteId: 4,
            ends: Edge(start: InterfaceVO(id: 88), end: InterfaceVO(id: 89))
        )
    }

    private func cableCreated(id: Int64) -> NetBoxHTTPResponse {
        NetBoxHTTPResponse(
            status: 201,
            body: Data(
                #"{"id":\#(id),"a_terminations":[{"object_type":"dcim.interface","object_id":88}],"b_terminations":[{"object_type":"dcim.interface","object_id":89}]}"#.utf8
            ),
            etag: nil
        )
    }

    private func cableEndJSON(id: Int64, peer: Int64) -> Data {
        Data("""
        {
          "id": \(id), "name": "eth\(id)",
          "device": {"id": 90, "name": "core"},
          "enabled": true,
          "description": "",
          "cable": {"id": 9},
          "connected_endpoints": [{"id":\(peer),"name":"eth\(peer)","device":{"id":90}}]
        }
        """.utf8)
    }

    private func deviceIDs(_ container: ModelContainer) throws -> Set<Int64> {
        Set(try ModelContext(container).fetch(FetchDescriptor<Device>()).map(\.id))
    }

    private func cableIDs(_ container: ModelContainer) throws -> Set<Int64> {
        Set(try ModelContext(container).fetch(FetchDescriptor<Cable>()).map(\.id))
    }

    private func seedCableEnds(in container: ModelContainer, billable: Bool) throws {
        let context = ModelContext(container)
        let site = try context.fetch(FetchDescriptor<Site>()).first { $0.id == 4 }
        let role = try context.fetch(FetchDescriptor<DeviceRole>()).first { $0.id == 1 }
        let device = Device(id: 90)
        device.site = site
        if billable {
            device.deviceRole = role
        }
        context.insert(device)
        for id in [Int64(88), 89] {
            let row = Interface(id: id)
            row.name = "eth\(id)"
            row.enabled = true
            row.deviceId = 90
            row.siteId = 4
            row.device = device
            context.insert(row)
        }
        try context.save()
    }

    private func makeHarness(grantedDevices: Int = 0) throws -> Harness {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            SiteLocation.self, RackRole.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Interface.self, Cable.self, DeviceBay.self, FrontPort.self, Service.self,
            WebHostTrust.self, Event.self, SyncProvider.self, PowerSenseDevice.self,
            PowerSenseEvent.self, SSHCredential.self, KnownHost.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let seed = ModelContext(container)
        seed.insert(Site(id: 4))
        let role = DeviceRole(id: 1)
        seed.insert(role)
        seed.insert(DeviceType(id: 8))
        if grantedDevices > 0 {
            let granted = Date(timeIntervalSince1970: 1_600_000_000)
            for id in 1...grantedDevices {
                let device = Device(id: Int64(id))
                device.created = granted
                device.seatGrantedAt = granted
                device.deviceRole = role
                seed.insert(device)
            }
        }
        try seed.save()
        let pending = PendingWrites()
        let fetcher = IntentFetcher()
        let engine = NetBoxSyncEngine(
            modelContainer: container,
            fetcher: fetcher,
            pendingWrites: pending
        )
        return Harness(container: container, fetcher: fetcher, pending: pending, engine: engine)
    }
}

private struct Harness {
    var container: ModelContainer
    var fetcher: IntentFetcher
    var pending: PendingWrites
    var engine: NetBoxSyncEngine
}

private final class IntentFetcher: NetBoxFetching, @unchecked Sendable {
    var sends: [NetBoxHTTPRequest] = []
    var sendResults: [Result<NetBoxHTTPResponse, Error>] = []
    var gets: [String] = []
    var getBodies: [String: Data] = [:]
    var getFailures: [String: Error] = [:]
    var beforeSend: (@Sendable (String) async -> Void)?
    var beforeGet: (@Sendable (String) async -> Void)?

    func get(path: String, query: [URLQueryItem]) async throws -> Data {
        gets.append(path)
        await beforeGet?(path)
        if let failure = getFailures[path] {
            throw failure
        }
        if let body = getBodies[path] {
            return body
        }
        throw NetBoxSyncError.httpStatus(code: 404, body: path)
    }

    func send(_ request: NetBoxHTTPRequest) async throws -> NetBoxHTTPResponse {
        sends.append(request)
        await beforeSend?(request.path)
        guard !sendResults.isEmpty else {
            throw NetBoxSyncError.httpStatus(code: 500, body: "no queued write response")
        }
        return try sendResults.removeFirst().get()
    }
}

private actor PauseGate {
    private var arrived = false
    private var opened = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        if opened { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    /// Fails after five seconds rather than hanging the run.
    func waitForArrival() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !arrived {
            guard ContinuousClock.now < deadline else { throw PauseTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func open() {
        opened = true
        let waiting = pauseWaiters
        pauseWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private struct PauseTimeout: Error {}
