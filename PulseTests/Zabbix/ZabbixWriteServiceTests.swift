//
//  ZabbixWriteServiceTests.swift
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

final class ZabbixWriteServiceTests: XCTestCase {
    private var cleanup: (@Sendable () async -> Void)?

    override func tearDown() async throws {
        await cleanup?()
        cleanup = nil
        await MainActor.run {
            OperatorNoticeCenter.shared.clear(source: .zabbix)
            RequestStatusManager.shared.clear(.zabbix)
        }
    }

    func testSubmitStagesPostingBeforeTheRPCReturns() async throws {
        let harness = try makeHarness()
        let gate = PauseGate()
        harness.transport.pause(on: gate)
        remember(harness, gate: gate)

        let tokens = await harness.service.submit([intent("739183001")])
        try await gate.waitForArrival()

        let token = try XCTUnwrap(tokens.first)
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .posting)
        let shared = await MainActor.run {
            harness.pending.ghosts(of: ProblemUpdateIntent.self, in: .events(["739183001", "other"]))
        }
        let disjoint = await MainActor.run {
            harness.pending.ghosts(of: ProblemUpdateIntent.self, in: .events(["other"]))
        }
        XCTAssertEqual(shared.map(\.token), [token])
        XCTAssertTrue(disjoint.isEmpty)
        XCTAssertEqual(harness.transport.sends, 1)
    }

    func testCommittedStaysUntilRefreshFinishesThenRetires() async throws {
        let harness = try makeHarness()
        let gate = PauseGate()
        await harness.refresh.pause(on: gate)
        harness.transport.results = [.success(accepted("739183001"))]
        remember(harness, gate: gate)

        let tokens = await harness.service.submit([intent("739183001")])
        try await gate.waitForArrival()

        let token = try XCTUnwrap(tokens.first)
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .committed(id: 739183001))
        await MainActor.run { harness.pending.retireCommitted(provider: .netbox) }
        let afterNetBox = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(afterNetBox, .committed(id: 739183001))

        await gate.open()
        await harness.service.waitForSubmittedWrites()
        let retired = await MainActor.run {
            harness.pending.ghosts(of: ProblemUpdateIntent.self, in: .events(["739183001"]))
        }
        XCTAssertTrue(retired.isEmpty)
    }

    func testRPCErrorKeepsTheAskWithZabbixsSentence() async throws {
        let harness = try makeHarness()
        remember(harness)
        let sentence = "Invalid params. Incorrect value for field \"suppress_until\": unexpected value \"1\"."
        harness.transport.results = [.success(rpcError(sentence))]

        let tokens = await harness.service.submit([intent("739183001")])
        await harness.service.waitForSubmittedWrites()

        let token = try XCTUnwrap(tokens.first)
        let expected = ZabbixError.invalidResponse(sentence).localizedDescription
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .failed(WriteFailure(provider: .zabbix, message: expected)))
        let posted = await notice(token)
        XCTAssertEqual(posted?.message, expected)
        XCTAssertEqual(posted?.source, .zabbix)
        XCTAssertEqual(posted?.id, PendingWrites.noticeID(.zabbix, token))
        let zabbixNotices = await MainActor.run {
            OperatorNoticeCenter.shared.notices.filter { $0.id == PendingWrites.noticeID(.zabbix, token) }
        }
        XCTAssertEqual(zabbixNotices.count, 1)
    }

    func testTransportErrorUsesTheUnreachableSentence() async throws {
        let harness = try makeHarness()
        remember(harness)
        harness.transport.results = [.failure(URLError(.notConnectedToInternet))]

        let tokens = await harness.service.submit([intent("739183001")])
        await harness.service.waitForSubmittedWrites()

        let token = try XCTUnwrap(tokens.first)
        let expected = ZabbixError.unreachable.localizedDescription
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .failed(WriteFailure(provider: .zabbix, message: expected)))
    }

    func testDiscardClearsTheAskAndTheNotice() async throws {
        let harness = try makeHarness()
        remember(harness)
        harness.transport.results = [.success(rpcError("no"))]

        let tokens = await harness.service.submit([intent("739183001")])
        await harness.service.waitForSubmittedWrites()
        let token = try XCTUnwrap(tokens.first)
        let postedBeforeDiscard = await notice(token)
        XCTAssertNotNil(postedBeforeDiscard)

        await harness.service.discard(token)
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertNil(state)
        let postedAfterDiscard = await notice(token)
        XCTAssertNil(postedAfterDiscard)
    }

    func testUnseatedEventDoesNotCallTheTransport() async throws {
        let harness = try makeHarness()
        remember(harness)
        try seed(eventId: "739183099", deviceID: 8, seated: false, in: harness)

        let tokens = await harness.service.submit([intent("739183099")])
        await harness.service.waitForSubmittedWrites()

        let token = try XCTUnwrap(tokens.first)
        let cap = SubscriptionTier.free.capReachedMessage()
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .failed(WriteFailure(provider: .zabbix, message: cap)))
        XCTAssertEqual(harness.transport.sends, 0)
        let status = await MainActor.run { RequestStatusManager.shared.currentStatus[.zabbix] }
        XCTAssertNil(status)
    }

    func testBatchFirstFailsSecondCommits() async throws {
        let harness = try makeHarness()
        remember(harness)
        try seed(eventId: "739183002", deviceID: 7, seated: true, in: harness)
        harness.transport.results = [
            .success(rpcError("first refused")),
            .success(accepted("739183002"))
        ]

        let tokens = await harness.service.submit([
            intent("739183001"),
            intent("739183002")
        ])
        await harness.service.waitForSubmittedWrites()

        let first = try XCTUnwrap(tokens.first)
        let second = try XCTUnwrap(tokens.dropFirst().first)
        let failed = await MainActor.run { harness.pending.state(of: first) }
        let committed = await MainActor.run { harness.pending.state(of: second) }
        if case .failed = failed {} else {
            XCTFail("first ask should stay failed, got \(String(describing: failed))")
        }
        XCTAssertNil(committed)
        XCTAssertEqual(harness.transport.sends, 2)
    }

    func testNewAskReplacesAFailureItCovers() async throws {
        let harness = try makeHarness()
        let gate = PauseGate()
        remember(harness, gate: gate)
        harness.transport.results = [
            .success(rpcError("Cannot close problem: trigger does not allow manual closing.")),
            .success(accepted("739183001"))
        ]

        let firstTokens = await harness.service.submit([update("739183001") { $0.closes = true }])
        let first = try XCTUnwrap(firstTokens.first)
        await harness.service.waitForSubmittedWrites()
        let failed = await MainActor.run { harness.pending.state(of: first) }
        if case .failed = failed {} else {
            XCTFail("close should stay failed, got \(String(describing: failed))")
        }
        let posted = await notice(first)
        XCTAssertNotNil(posted)

        harness.transport.pause(on: gate)
        let secondTokens = await harness.service.submit([update("739183001") { $0.severity = 4 }])
        let second = try XCTUnwrap(secondTokens.first)
        try await gate.waitForArrival()

        let replaced = await MainActor.run { harness.pending.state(of: first) }
        XCTAssertNil(replaced)
        let live = await MainActor.run { harness.pending.state(of: second) }
        XCTAssertEqual(live, .posting)
        let ghosts = await MainActor.run {
            harness.pending.ghosts(of: ProblemUpdateIntent.self, in: .events(["739183001"]))
        }
        XCTAssertEqual(ghosts.map(\.token), [second])
        XCTAssertEqual(ghosts.first?.ghost.severity, 4)
        let cleared = await notice(first)
        XCTAssertNil(cleared)

        await gate.open()
        await harness.service.waitForSubmittedWrites()
        let retired = await MainActor.run {
            harness.pending.ghosts(of: ProblemUpdateIntent.self, in: .events(["739183001"]))
        }
        XCTAssertTrue(retired.isEmpty)
    }

    func testALargerAskStaysWhenTheNewOneDoesNotCoverIt() async throws {
        let harness = try makeHarness()
        let gate = PauseGate()
        remember(harness, gate: gate)
        try seed(eventId: "739183002", deviceID: 8, seated: false, in: harness)
        try seed(eventId: "739183003", deviceID: 9, seated: false, in: harness)
        harness.seats.apply(SyncSeatUpdate(granted: [8, 9]))
        harness.transport.results = [
            .success(rpcError("Cannot close problem: trigger does not allow manual closing.")),
            .success(accepted("739183002"))
        ]

        let widerTokens = await harness.service.submit([
            update(["739183002", "739183003"]) { $0.closes = true }
        ])
        let wider = try XCTUnwrap(widerTokens.first)
        await harness.service.waitForSubmittedWrites()

        harness.transport.pause(on: gate)
        let narrowerTokens = await harness.service.submit([update("739183002") { $0.severity = 3 }])
        let narrower = try XCTUnwrap(narrowerTokens.first)
        try await gate.waitForArrival()

        let kept = await MainActor.run { harness.pending.state(of: wider) }
        if case .failed = kept {} else {
            XCTFail("the wider refusal should stay, got \(String(describing: kept))")
        }
        let posted = await notice(wider)
        XCTAssertNotNil(posted)
        let onB = await MainActor.run {
            harness.pending.ghosts(of: ProblemUpdateIntent.self, in: .events(["739183002"]))
        }
        XCTAssertEqual(onB.map(\.token), [wider, narrower])
        let onC = await MainActor.run {
            harness.pending.ghosts(of: ProblemUpdateIntent.self, in: .events(["739183003"]))
        }
        XCTAssertEqual(onC.map(\.token), [wider])

        await gate.open()
    }

    func testGhostsComeBackInStageOrder() async throws {
        let harness = try makeHarness()
        let gate = PauseGate()
        remember(harness, gate: gate)
        try seed(eventId: "739183002", deviceID: 8, seated: false, in: harness)
        harness.seats.apply(SyncSeatUpdate(granted: [8]))
        harness.transport.pause(on: gate)
        harness.transport.results = [
            .success(accepted("739183001")),
            .success(accepted("739183002"))
        ]

        let firstTokens = await harness.service.submit([intent("739183001")])
        let first = try XCTUnwrap(firstTokens.first)
        try await gate.waitForArrival()
        let secondTokens = await harness.service.submit([intent("739183002")])
        let second = try XCTUnwrap(secondTokens.first)

        let ghosts = await MainActor.run {
            harness.pending.ghosts(
                of: ProblemUpdateIntent.self,
                in: .events(["739183001", "739183002"])
            )
        }
        XCTAssertEqual(ghosts.map(\.token), [first, second])

        await gate.open()
    }

    func testLateErrorAfterCommitIsIgnored() async throws {
        let harness = try makeHarness()
        let gate = PauseGate()
        await harness.refresh.pause(on: gate)
        harness.transport.results = [.success(accepted("739183001"))]
        remember(harness, gate: gate)

        let tokens = await harness.service.submit([intent("739183001")])
        try await gate.waitForArrival()
        let token = try XCTUnwrap(tokens.first)

        let stored = await MainActor.run {
            harness.pending.fail(
                token: token,
                failure: WriteFailure(provider: .zabbix, message: "late")
            )
        }
        XCTAssertFalse(stored)
        let state = await MainActor.run { harness.pending.state(of: token) }
        XCTAssertEqual(state, .committed(id: 739183001))
    }

    private func remember(_ harness: Harness, gate: PauseGate? = nil) {
        let service = harness.service
        cleanup = {
            await gate?.open()
            await service.waitForSubmittedWrites()
        }
    }

    private func notice(_ token: WriteToken) async -> OperatorNotice? {
        await MainActor.run {
            OperatorNoticeCenter.shared.notices.first {
                $0.id == PendingWrites.noticeID(.zabbix, token)
            }
        }
    }

    private func intent(_ eventId: String) -> ProblemUpdateIntent {
        update(eventId) { $0.acknowledges = true }
    }

    private func update(
        _ eventId: String,
        edit: (inout ProblemUpdateDraft) -> Void
    ) -> ProblemUpdateIntent {
        update([eventId], edit: edit)
    }

    private func update(
        _ eventIds: [String],
        edit: (inout ProblemUpdateDraft) -> Void
    ) -> ProblemUpdateIntent {
        var draft = ProblemUpdateDraft(eventIds: eventIds)
        edit(&draft)
        return ProblemUpdateIntent(draft: draft)
    }

    private func accepted(_ eventId: String) -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "result": ["eventids": [Int(eventId) ?? 0]],
            "id": 1
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func rpcError(_ data: String) -> Data {
        // `errorDescription` joins a non-empty message and data. An empty
        // message leaves the sentence as the operator will read it.
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": -32602, "message": "", "data": data],
            "id": 1
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func makeHarness() throws -> Harness {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            SiteLocation.self, RackRole.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Interface.self, Cable.self,
            DeviceBay.self, FrontPort.self, Service.self, WebHostTrust.self,
            Event.self, SyncProvider.self, PowerSenseDevice.self, PowerSenseEvent.self,
            SSHCredential.self, KnownHost.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let pending = PendingWrites()
        let transport = FakeZabbixTransport()
        let refresh = PauseRefresh()
        let seats = LicenseSeatStore()
        let service = ZabbixWriteService(
            pendingWrites: pending,
            problems: refresh,
            container: container,
            seats: seats,
            tier: { .free },
            transport: transport,
            requests: StubAcknowledgeRequests()
        )
        let harness = Harness(
            container: container,
            pending: pending,
            transport: transport,
            refresh: refresh,
            seats: seats,
            service: service
        )
        try seed(eventId: "739183001", deviceID: 7, seated: true, in: harness)
        return harness
    }

    private func seed(eventId: String, deviceID: Int64, seated: Bool, in harness: Harness) throws {
        let context = ModelContext(harness.container)
        let device = Device(id: deviceID)
        let event = Event(eventId: eventId)
        event.device = device
        context.insert(device)
        context.insert(event)
        try context.save()
        if seated {
            harness.seats.apply(SyncSeatUpdate(replaceSeated: [deviceID], replaceUnbilled: []))
        }
    }
}

private struct Harness {
    var container: ModelContainer
    var pending: PendingWrites
    var transport: FakeZabbixTransport
    var refresh: PauseRefresh
    var seats: LicenseSeatStore
    var service: ZabbixWriteService
}

private final class FakeZabbixTransport: ZabbixTransport, @unchecked Sendable {
    var results: [Result<Data, Error>] = []
    private(set) var sends = 0
    private var beforeSend: (@Sendable () async -> Void)?

    func pause(on gate: PauseGate) {
        beforeSend = { await gate.arriveAndWait() }
    }

    func send(_ request: URLRequest) async throws -> Data {
        sends += 1
        await beforeSend?()
        guard !results.isEmpty else {
            throw ZabbixError.unreachable
        }
        return try results.removeFirst().get()
    }
}

private struct StubAcknowledgeRequests: ZabbixAcknowledgeRequesting {
    func request(for draft: ProblemUpdateDraft) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://zabbix.example/api_jsonrpc.php")!)
    }
}

private actor PauseRefresh: ZabbixProblemRefreshing {
    private var before: (@Sendable () async -> Void)?

    func pause(on gate: PauseGate) {
        before = { await gate.arriveAndWait() }
    }

    func refreshProblems(eventIds: [String]) async {
        await before?()
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

final class ActiveProblemCountTests: XCTestCase {
    func testActiveCountsIgnoreResolvedSuppressedAndKeepAcknowledged() throws {
        let context = try makeContext()
        let device = Device(id: 1)
        device.zabbixId = 9
        context.insert(device)
        context.insert(event("open-acked", severity: "4", rClock: "0", suppressed: "0", acknowledged: "1", device: device))
        context.insert(event("open-unacked", severity: "4", rClock: "0", suppressed: "0", acknowledged: "0", device: device))
        context.insert(event("resolved", severity: "4", rClock: "100", suppressed: "0", acknowledged: "0", device: device))
        context.insert(event("suppressed", severity: "3", rClock: "0", suppressed: "1", acknowledged: "0", device: device))
        try context.save()

        device.refreshSeverityFromEvents()
        device.refreshSeverityFromEvents()

        XCTAssertEqual(device.activeCountsBySeverity, [0, 0, 0, 0, 2, 0])
        XCTAssertEqual(device.highestSeverityStored, 4)
        XCTAssertEqual(device.highestUnacknowledgedSeverityStored, 4)
    }

    func testAcknowledgedProblemsCountAndDoNotColour() throws {
        let context = try makeContext()
        let device = Device(id: 2)
        device.zabbixId = 9
        context.insert(device)
        context.insert(event("acked", severity: "3", rClock: "0", suppressed: "0", acknowledged: "1", device: device))
        try context.save()

        device.refreshSeverityFromEvents()

        XCTAssertEqual(device.activeCountsBySeverity, [0, 0, 0, 1, 0, 0])
        XCTAssertEqual(device.highestSeverityStored, 3)
        XCTAssertEqual(device.highestUnacknowledgedSeverityStored, -1)
    }

    func testNoZabbixHostZerosTheCounts() {
        let device = Device(id: 3)
        device.zabbixId = 0
        device.highestSeverityStored = 4
        device.highestUnacknowledgedSeverityStored = 4
        device.activeCountsBySeverity = [1, 1, 1, 1, 1, 1]

        device.refreshSeverityFromEvents()

        XCTAssertEqual(device.activeCountsBySeverity, [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(device.highestSeverityStored, -2)
        XCTAssertEqual(device.highestUnacknowledgedSeverityStored, -1)
    }

    func testSiteReadsStoredDeviceInts() throws {
        let context = try makeContext()
        let site = Site(id: 7)
        let monitored = Device(id: 4)
        monitored.zabbixId = 9
        monitored.highestSeverityStored = 4
        monitored.highestUnacknowledgedSeverityStored = -1
        let unmonitored = Device(id: 5)
        unmonitored.zabbixId = 0
        unmonitored.highestSeverityStored = 5
        unmonitored.highestUnacknowledgedSeverityStored = 5
        site.devices = [monitored, unmonitored]
        context.insert(site)
        context.insert(monitored)
        context.insert(unmonitored)

        site.refreshSeverityFromDevices()

        XCTAssertEqual(site.highestSeverityStored, 4)
        XCTAssertEqual(site.highestUnacknowledgedSeverityStored, -1)
    }

    func testEmptySiteAndQuietSite() {
        let empty = Site(id: 1)
        empty.refreshSeverityFromDevices()
        XCTAssertEqual(empty.highestSeverityStored, -2)
        XCTAssertEqual(empty.highestUnacknowledgedSeverityStored, -1)

        let quiet = Site(id: 2)
        let device = Device(id: 6)
        device.zabbixId = 9
        device.highestSeverityStored = -1
        device.highestUnacknowledgedSeverityStored = -1
        quiet.devices = [device]
        quiet.refreshSeverityFromDevices()
        XCTAssertEqual(quiet.highestSeverityStored, -1)
        XCTAssertEqual(quiet.highestUnacknowledgedSeverityStored, -1)

        let unknown = Site(id: 3)
        let pending = Device(id: 7)
        pending.zabbixId = 9
        pending.highestSeverityStored = -2
        pending.highestUnacknowledgedSeverityStored = -2
        unknown.devices = [pending]
        unknown.refreshSeverityFromDevices()
        XCTAssertEqual(unknown.highestSeverityStored, -1)
        XCTAssertEqual(unknown.highestUnacknowledgedSeverityStored, -1)
    }

    func testUpdateSkipsAnEqualPayloadAndKeepsHostId() throws {
        let event = Event(eventId: "1")
        let withHost = try problem(hostId: "42")
        XCTAssertTrue(event.update(with: withHost))
        XCTAssertEqual(event.hostId, 42)
        XCTAssertFalse(event.update(with: withHost))
        XCTAssertEqual(event.hostId, 42)

        XCTAssertFalse(event.update(with: try problem(hostId: nil)))
        XCTAssertEqual(event.hostId, 42)
    }

    func testUpdateReportsAChangedField() throws {
        let event = Event(eventId: "1")
        XCTAssertTrue(event.update(with: try problem(name: "n")))
        XCTAssertTrue(event.update(with: try problem(name: "other")))
        XCTAssertEqual(event.name, "other")
        XCTAssertFalse(event.update(with: try problem(name: "other")))
    }

    func testDeviceStampsSiteIdAndAMissingDeviceLeavesIt() throws {
        let context = try makeContext()
        let device = Device(id: 8)
        device.siteId = 77
        context.insert(device)
        let event = Event(eventId: "1")
        context.insert(event)

        XCTAssertTrue(event.update(with: try problem(), device: device))
        XCTAssertEqual(event.siteId, 77)
        XCTAssertEqual(event.device?.id, 8)
        XCTAssertFalse(event.update(with: try problem(), device: device))
        XCTAssertEqual(event.siteId, 77)

        let untouched = Event(eventId: "2")
        untouched.siteId = 3
        context.insert(untouched)
        XCTAssertTrue(untouched.update(with: try problem()))
        XCTAssertEqual(untouched.siteId, 3)
        XCTAssertNil(untouched.device)
    }

    func testRefreshStampsSiteIdOnResolvedRowsToo() throws {
        let context = try makeContext()
        let device = Device(id: 9)
        device.zabbixId = 9
        device.siteId = 15
        context.insert(device)
        let open = event("open", severity: "2", rClock: "0", suppressed: "0", acknowledged: "0", device: device)
        let resolved = event("resolved", severity: "4", rClock: "5", suppressed: "0", acknowledged: "0", device: device)
        let kept = event("kept", severity: "1", rClock: "0", suppressed: "0", acknowledged: "0", device: device)
        kept.hostId = 4
        context.insert(open)
        context.insert(resolved)
        context.insert(kept)
        try context.save()

        device.refreshSeverityFromEvents()

        XCTAssertEqual(open.siteId, 15)
        XCTAssertEqual(resolved.siteId, 15)
        XCTAssertEqual(open.hostId, 9)
        XCTAssertEqual(resolved.hostId, 9)
        XCTAssertEqual(kept.hostId, 4)
    }

    func testStampUsesTheSiteRelationshipWhenTheColumnIsZero() throws {
        let context = try makeContext()
        let site = Site(id: 44)
        let device = Device(id: 11)
        device.zabbixId = 9
        device.siteId = 0
        device.site = site
        context.insert(site)
        context.insert(device)
        let stored = Event(eventId: "stored")
        context.insert(stored)
        let open = event("open", severity: "2", rClock: "0", suppressed: "0", acknowledged: "0", device: device)
        open.siteId = 0
        context.insert(open)
        try context.save()

        XCTAssertTrue(stored.update(with: try problem(), device: device))
        XCTAssertEqual(stored.siteId, 44)
        XCTAssertFalse(stored.update(with: try problem(), device: device))

        device.refreshSeverityFromEvents()
        XCTAssertEqual(open.siteId, 44)
    }

    func testHostIdsPageByDeviceIdAndSkipUnmonitored() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for id in 1...201 {
            let device = Device(id: Int64(id))
            device.zabbixId = id == 201 ? 1001 : Int64(1000 + id)
            context.insert(device)
        }
        let idle = Device(id: 202)
        idle.zabbixId = 0
        context.insert(idle)
        try context.save()

        let ids = try await SiteDataService(modelContainer: container).pagedZabbixHostIds()
        XCTAssertEqual(ids, (1...200).map { String(1000 + $0) })
    }

    func testAssignActiveSeverityDoesNotStampSiteId() throws {
        let context = try makeContext()
        let device = Device(id: 10)
        device.zabbixId = 9
        device.siteId = 15
        context.insert(device)
        let resolved = event("resolved", severity: "4", rClock: "5", suppressed: "0", acknowledged: "0", device: device)
        resolved.siteId = 0
        context.insert(resolved)
        try context.save()

        device.assignActiveSeverity(ActiveSeverity())

        XCTAssertEqual(resolved.siteId, 0)
        XCTAssertEqual(resolved.hostId, 0)
        XCTAssertEqual(device.highestSeverityStored, -1)
        XCTAssertEqual(device.activeCountsBySeverity, [0, 0, 0, 0, 0, 0])
    }

    func testUnsavedOpenRowIsInTheHostFetch() throws {
        let context = try makeContext()
        let open = Event(eventId: "open")
        open.hostId = 9
        open.severity = "4"
        open.acknowledged = "1"
        open.rClock = "0"
        open.suppressed = "0"
        let resolved = Event(eventId: "resolved")
        resolved.hostId = 9
        resolved.severity = "2"
        resolved.rClock = "8"
        resolved.suppressed = "0"
        context.insert(open)
        context.insert(resolved)

        let ids = [Int64(9)]
        let descriptor = FetchDescriptor<Event>(
            predicate: #Predicate<Event> { event in
                event.rClock == "0" && event.suppressed == "0" && ids.contains(event.hostId)
            }
        )
        let rows = try context.fetch(descriptor)
        XCTAssertEqual(rows.map(\.eventId).sorted(), ["open"])

        var tally = ActiveSeverity()
        for event in rows {
            tally.observe(severity: event.severity, acknowledged: event.acknowledged)
        }
        XCTAssertEqual(tally.counts, [0, 0, 0, 0, 1, 0])
        XCTAssertEqual(tally.highest, 4)
        XCTAssertEqual(tally.unacknowledged, -1)
    }

    func testStampHostIdFillsZeroAndLeavesASetValue() {
        let device = Device(id: 12)
        device.zabbixId = 9
        let missing = Event(eventId: "missing")
        XCTAssertTrue(missing.stampHostIdIfMissing(from: device))
        XCTAssertEqual(missing.hostId, 9)
        XCTAssertFalse(missing.stampHostIdIfMissing(from: device))

        let kept = Event(eventId: "kept")
        kept.hostId = 4
        XCTAssertFalse(kept.stampHostIdIfMissing(from: device))
        XCTAssertEqual(kept.hostId, 4)
    }

    func testUpdateWritesTheFirstHostId() throws {
        let withHost = try JSONDecoder().decode(EventProperties.self, from: Data("""
        {"eventid":"1","name":"n","source":"0","object":"0","objectid":"1","clock":"1","acknowledged":"1","severity":"4","opdata":"","suppressed":"0","r_clock":"0","hosts":[{"hostid":"42"},{"hostid":"7"}]}
        """.utf8))
        let event = Event(eventId: "1")
        event.update(with: withHost)
        XCTAssertEqual(event.hostId, 42)

        let withoutHost = try JSONDecoder().decode(EventProperties.self, from: Data("""
        {"eventid":"2","name":"n","source":"0","object":"0","objectid":"1","clock":"1","acknowledged":"0","severity":"4","opdata":"","suppressed":"0","r_clock":"0"}
        """.utf8))
        let untouched = Event(eventId: "2")
        untouched.hostId = 11
        untouched.update(with: withoutHost)
        XCTAssertEqual(untouched.hostId, 11)
    }

    private func problem(
        name: String = "n",
        severity: String = "4",
        rClock: String = "0",
        suppressed: String = "0",
        hostId: String? = "42"
    ) throws -> EventProperties {
        var json = """
        {"eventid":"1","name":"\(name)","source":"0","object":"0","objectid":"1","clock":"1700000000","acknowledged":"0","severity":"\(severity)","opdata":"","suppressed":"\(suppressed)","r_clock":"\(rClock)"
        """
        if let hostId {
            json += ",\"hosts\":[{\"hostid\":\"\(hostId)\"}]"
        }
        json += "}"
        return try JSONDecoder().decode(EventProperties.self, from: Data(json.utf8))
    }

    private func event(
        _ id: String,
        severity: String,
        rClock: String,
        suppressed: String,
        acknowledged: String,
        device: Device
    ) -> Event {
        let event = Event(eventId: id)
        event.severity = severity
        event.rClock = rClock
        event.suppressed = suppressed
        event.acknowledged = acknowledged
        event.device = device
        return event
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try makeContainer())
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            SiteLocation.self, RackRole.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Interface.self, Cable.self,
            DeviceBay.self, FrontPort.self, Service.self, WebHostTrust.self,
            Event.self, SyncProvider.self, PowerSenseDevice.self, PowerSenseEvent.self,
            SSHCredential.self, KnownHost.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
