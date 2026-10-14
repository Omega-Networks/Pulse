//
//  NetBoxSyncEngine.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import NetBoxAPI
import OSLog
import SwiftData
import SwiftUI

/// Single owner of NetBox read-sync and MACD writes. Boot and Apply
/// changes call `sync()` (a delta, or a full mirror when the watermark
/// is missing, gone, or older than the safety interval). Full Resync
/// calls `fullSync()`. Overlapping user callers join that pass. While
/// the app is open, `startIdleChangelog()` repeats the delta only.
/// A device create stores the 201 body. Interface enable, description,
/// and label apply locally. Site, rack, and cable writes re-read the
/// object. No write pages the changelog.
actor NetBoxSyncEngine {
    private let modelContainer: ModelContainer
    private let fetcher: any NetBoxFetching
    private let writePolicy: NetBoxWritePolicy
    /// Live StoreKit tier. Defaults fail closed (Free) so a missed
    /// injection cannot read a spoofable UserDefaults cache.
    /// PulseApp must pass `{ entitlementStore.tier }` — tests that
    /// omit the argument are exercising Free, not production.
    private let subscriptionTier: @Sendable () -> SubscriptionTier
    private let logger = Logger(subsystem: "netbox", category: "sync")
    private var inFlight: Task<Void, Error>?
    private var writes: Task<SyncSeatUpdate?, Error>?
    /// Frames of `performWrite` that have entered and not yet left,
    /// including a write queued behind another. Cleared only when the
    /// chain drains, so the first write's return cannot overlap the next.
    private var writeDepth = 0
    /// True while `writeDepth > 0`. Idle stops at a page boundary, and
    /// a user sync waits until the chain is idle.
    private var writeInProgress = false
    /// Set when any write in the current chain succeeds. The quiet
    /// delta is armed once, when the chain drains.
    private var writeChainNeedsCatchUp = false
    /// Seat result of the write task that is running. Read with no
    /// await after `work()` returns, so the next write cannot clear it.
    private var pendingSeatUpdate: SyncSeatUpdate?
    /// Bumped each time `writes` is replaced. Only the tail frame nils it.
    private var writeSerial: UInt64 = 0
    private var writeTailSerial: UInt64 = 0
    /// True while boot, Apply changes, or Full Resync is waiting to start
    /// or running. Idle must not treat that wait as its own pass.
    private var userSyncWaiting = false
    private var idleLoop: Task<Void, Never>?
    private var quietCatchUp: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var idleRunning = false
    /// Last `.full` reason we logged from an idle skip, so a due safety
    /// mirror does not log on every tick.
    private var lastIdleSkipLog: String?
    /// The idle changelog hit the page cap. Further idle ticks must not
    /// re-download that window. Launch and Apply changes clear it.
    /// Pages already applied stay stamped.
    private var idlePageCapLatched = false
    /// The changelog list returned 403. Idle does not retry it. Launch
    /// and Apply changes clear it and try once more. Not a full mirror.
    private var idleChangelogPermissionLatched = false
    /// List paths that returned 403 this session. Idle does not request
    /// them again. Cleared when a user sync starts.
    private var deniedListPaths: Set<String> = []
    /// Device rows the current delta created, updated, or deleted.
    private var passDeviceIDs: [Int64] = []
    /// Objects applied by the current delta. A later page can fail
    /// after earlier pages have already been stamped.
    private var passAppliedCount = 0
    /// A full mirror and a failed-boot heal seat the whole store.
    /// A delta boot, Apply changes, and idle seat only `passDeviceIDs`.
    private var passSeatsWholeStore = false

    init(
        modelContainer: ModelContainer,
        fetcher: any NetBoxFetching = NetBoxLiveFetcher(),
        writePolicy: NetBoxWritePolicy = .shipped,
        subscriptionTier: @escaping @Sendable () -> SubscriptionTier = { .free }
    ) {
        self.modelContainer = modelContainer
        self.fetcher = fetcher
        self.writePolicy = writePolicy
        self.subscriptionTier = subscriptionTier
    }

    private var writer: NetBoxWriteService {
        NetBoxWriteService(fetcher: fetcher, policy: writePolicy)
    }

    /// Weekly safety full mirror. Changelog misses out-of-request-context edits.
    static let safetyMirrorInterval: TimeInterval = 7 * 24 * 60 * 60

    /// While Pulse is open, apply the changelog this often. Same cadence
    /// as the Zabbix problem timer, so the twin is not busier than monitoring.
    static let idleChangelogInterval: Duration = .seconds(120)

    /// After the last successful write in a burst, apply the changelog
    /// once so template children (front ports, bays) land without the
    /// button waiting.
    static let idleChangelogQuietPeriod: Duration = .seconds(2)

    /// Boot entry: delta when a watermark is usable, otherwise a full mirror.
    func sync(progress: (@Sendable (Int, String) -> Void)? = nil) async throws {
        guard try await claimUserSync() else { return }
        idlePageCapLatched = false
        idleChangelogPermissionLatched = false
        deniedListPaths = []
        beginSeatPass(wholeStore: true)
        defer { userSyncWaiting = false }
        let task = Task(priority: .userInitiated) {
            try await self.performBootSync(progress: progress)
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            try await task.value
            await postApply(await makeSeatNotice())
        } catch {
            logger.error("NetBox sync failed: \(error.localizedDescription)")
            await postPartialDelta()
            throw error
        }
    }

    /// Settings → Sync Data. Always a full mirror, then a fresh watermark.
    func fullSync(progress: (@Sendable (Int, String) -> Void)? = nil) async throws {
        guard try await claimUserSync() else { return }
        idlePageCapLatched = false
        idleChangelogPermissionLatched = false
        deniedListPaths = []
        beginSeatPass(wholeStore: true)
        defer { userSyncWaiting = false }
        let task = Task(priority: .userInitiated) {
            let cursor = try? await self.latestChangelogCursor()
            try await self.performFullSync(progress: progress)
            try await self.stampFullSuccess(cursor: cursor)
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            try await task.value
            await postApply(await makeSeatNotice())
        } catch {
            logger.error("NetBox full sync failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Seat rows already in the store. Boot calls this when sync throws,
    /// so a failed launch does not leave last session's devices unseated.
    func seatLocalDevices() async {
        beginSeatPass(wholeStore: true)
        await postApply(await makeSeatNotice())
    }

    /// True while an operator write owns the engine, including one queued
    /// behind another. Idle and tests use this to avoid overlapping saves.
    func operatorWriteIsActive() -> Bool {
        writeInProgress
    }

    /// One changelog loop for the process. The first tick waits out the
    /// interval so it does not repeat the boot delta. Idempotent.
    func startIdleChangelog() {
        guard idleLoop == nil else { return }
        idleLoop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.idleChangelogInterval)
                if Task.isCancelled { break }
                await self.runIdleCatchUp()
            }
        }
    }

    /// Delta since the watermark. Does not start a full mirror. A second
    /// caller while one pass is running returns. A pass that already hit
    /// the page cap, or a changelog the token cannot read, returns until
    /// launch or Apply changes clears the latch.
    /// Boot and the dashboard keep using `sync()` / `fullSync()`.
    func runIdleCatchUp() async {
        guard inFlight == nil, !writeInProgress, !userSyncWaiting, !idleRunning else { return }
        guard !idlePageCapLatched, !idleChangelogPermissionLatched else { return }
        idleRunning = true
        let task = Task { await self.performIdleCatchUp() }
        idleTask = task
        await task.value
        idleTask = nil
        idleRunning = false
    }

    /// Wait out writes and any idle pass, then let the caller start a user
    /// sync. Returns false when this caller joined an in-flight user sync.
    private func claimUserSync() async throws -> Bool {
        await waitForWriteChain()
        if let inFlight {
            try await inFlight.value
            return false
        }
        userSyncWaiting = true
        if let idle = idleTask {
            await idle.value
        }
        // A write may have replaced `writes` while this call waited.
        await waitForWriteChain()
        if let inFlight {
            userSyncWaiting = false
            try await inFlight.value
            return false
        }
        return true
    }

    /// Waits until the write chain has drained. A second write replaces
    /// `writes` while the first task is still the one we awaited, so this
    /// loops until `writeInProgress` is false after the latest task.
    private func waitForWriteChain() async {
        while writeInProgress || writes != nil {
            if let pending = writes {
                try? await pending.value
            }
            if !writeInProgress {
                return
            }
            await Task.yield()
        }
    }

    /// One full-mirror model. Sites and devices are required: a 403 there
    /// fails the sync. Every other model is skipped on 403 and its stored
    /// rows stay. The sync call is separate from this metadata: a tuple
    /// that also held the async closure was retained incorrectly.
    private enum MirrorModel: CaseIterable {
        case tenantGroups
        case deviceRoles
        case deviceTypes
        case tenants
        case regions
        case siteGroups
        case sites
        case locations
        case rackRoles
        case racks
        case devices
        case deviceBays
        case frontPorts
        case services
        case interfaces
        case cables

        var label: String {
            switch self {
            case .tenantGroups: return "Synchronising Tenant Groups..."
            case .deviceRoles: return "Synchronising Device Roles..."
            case .deviceTypes: return "Synchronising Device Types..."
            case .tenants: return "Synchronising Tenants..."
            case .regions: return "Synchronising Regions..."
            case .siteGroups: return "Synchronising Site Groups..."
            case .sites: return "Synchronising Sites..."
            case .locations: return "Synchronising Locations..."
            case .rackRoles: return "Synchronising Rack Roles..."
            case .racks: return "Synchronising Racks..."
            case .devices: return "Synchronising Devices..."
            case .deviceBays: return "Synchronising Device Bays..."
            case .frontPorts: return "Synchronising Front Ports..."
            case .services: return "Synchronising Services..."
            case .interfaces: return "Synchronising Interfaces..."
            case .cables: return "Synchronising Cables..."
            }
        }

        var path: String {
            switch self {
            case .tenantGroups: return "/api/tenancy/tenant-groups/"
            case .deviceRoles: return "/api/dcim/device-roles/"
            case .deviceTypes: return "/api/dcim/device-types/"
            case .tenants: return "/api/tenancy/tenants/"
            case .regions: return "/api/dcim/regions/"
            case .siteGroups: return "/api/dcim/site-groups/"
            case .sites: return "/api/dcim/sites/"
            case .locations: return "/api/dcim/locations/"
            case .rackRoles: return "/api/dcim/rack-roles/"
            case .racks: return "/api/dcim/racks/"
            case .devices: return "/api/dcim/devices/"
            case .deviceBays: return "/api/dcim/device-bays/"
            case .frontPorts: return "/api/dcim/front-ports/"
            case .services: return "/api/ipam/services/"
            case .interfaces: return "/api/dcim/interfaces/"
            case .cables: return "/api/dcim/cables/"
            }
        }

        var required: Bool {
            switch self {
            case .sites, .devices: return true
            default: return false
            }
        }
    }

    private func performFullSync(progress: (@Sendable (Int, String) -> Void)?) async throws {
        for (index, model) in MirrorModel.allCases.enumerated() {
            progress?(index, model.label)
            try await runMirrorStage(path: model.path, required: model.required) {
                try await self.syncMirror(model)
            }
        }
    }

    private func syncMirror(_ model: MirrorModel) async throws {
        switch model {
        case .tenantGroups: try await syncTenantGroups()
        case .deviceRoles: try await syncDeviceRoles()
        case .deviceTypes: try await syncDeviceTypes()
        case .tenants: try await syncTenants()
        case .regions: try await syncRegions()
        case .siteGroups: try await syncSiteGroups()
        case .sites: try await syncSites()
        case .locations: try await syncLocations()
        case .rackRoles: try await syncRackRoles()
        case .racks: try await syncRacks()
        case .devices: try await syncDevices()
        case .deviceBays: try await syncDeviceBays()
        case .frontPorts: try await syncFrontPorts()
        case .services: try await syncServices()
        case .interfaces: try await syncInterfaces()
        case .cables: try await syncCables()
        }
    }

    private static let changelogListPath = "/api/core/object-changes/"

    private static func isForbidden(_ error: Error) -> Bool {
        guard let sync = error as? NetBoxSyncError,
              case .httpStatus(let code, _) = sync else {
            return false
        }
        return code == 403
    }

    private static func permissionID(for path: String) -> String {
        "netbox.permission.\(path)"
    }

    private static func modelName(for path: String) -> String {
        let leaf = path.split(separator: "/").last.map(String.init) ?? "that model"
        return leaf.replacingOccurrences(of: "-", with: " ")
    }

    /// Optional model the token cannot read. The completion apply is not
    /// run, so stored rows for that model stay. Idle will not request the
    /// path again until a user sync clears `deniedListPaths`.
    private func noteOptionalForbidden(path: String) async {
        deniedListPaths.insert(path)
        let notice = OperatorNotice(
            id: Self.permissionID(for: path),
            source: .netbox,
            severity: .warning,
            message: "NetBox token cannot read \(Self.modelName(for: path)). Pulse kept syncing the rest.",
            occurredAt: Date()
        )
        await OperatorNoticeCenter.shared.post(notice)
        logger.error("NetBox refused \(path, privacy: .public); continuing without it")
    }

    private func noteChangelogForbidden() async {
        idleChangelogPermissionLatched = true
        let notice = OperatorNotice(
            id: Self.permissionID(for: Self.changelogListPath),
            source: .netbox,
            severity: .warning,
            message: "NetBox token cannot read the changelog. Pulse will try again on the next launch or Apply changes.",
            occurredAt: Date()
        )
        await OperatorNoticeCenter.shared.post(notice)
        logger.error("NetBox refused the changelog; waiting for Apply changes or launch")
    }

    private func clearPermission(path: String) async {
        deniedListPaths.remove(path)
        await OperatorNoticeCenter.shared.clear(id: Self.permissionID(for: path))
    }

    /// Sites and devices are the mirror: a 403 there fails the sync.
    /// Any other model's 403 is remembered, its local rows are left as
    /// they were, and the rest of the mirror continues. A 401 or a
    /// transport error still fails the sync.
    private func runMirrorStage(
        path: String,
        required: Bool,
        _ work: () async throws -> Void
    ) async throws {
        do {
            try await work()
            await clearPermission(path: path)
        } catch {
            guard Self.isForbidden(error), !required else { throw error }
            await noteOptionalForbidden(path: path)
        }
    }

    private func performBootSync(progress: (@Sendable (Int, String) -> Void)?) async throws {
        let plan = try await applyOnStore { context in
            try Self.decideSync(in: context)
        }
        switch plan {
        case .full(let reason):
            logger.info("NetBox full mirror (\(reason, privacy: .public))")
            let cursor = try? await latestChangelogCursor()
            try await performFullSync(progress: progress)
            try await stampFullSuccess(cursor: cursor)
        case .delta(let watermarkID):
            // 0 is the empty-changelog stamp, not a real object-change
            // id. Probing `/object-changes/0/` 404s and would force a
            // full mirror on every boot of a fresh instance.
            if watermarkID > 0, await changelogRecordMissing(id: watermarkID) {
                logger.error("Watermark \(watermarkID) is gone; forcing full mirror")
                let cursor = try? await latestChangelogCursor()
                try await performFullSync(progress: progress)
                try await stampFullSuccess(cursor: cursor)
                return
            }
            progress?(0, "Applying NetBox changes...")
            beginSeatPass(wholeStore: false)
            try await performDelta(
                after: watermarkID,
                fallbackToFullMirror: true,
                yieldToWriters: false
            )
        }
    }

    private enum SyncPlan: Sendable {
        case full(String)
        case delta(Int64)
    }

    private static func decideSync(in context: ModelContext) throws -> SyncPlan {
        var devicePeek = FetchDescriptor<Device>()
        devicePeek.fetchLimit = 1
        var sitePeek = FetchDescriptor<Site>()
        sitePeek.fetchLimit = 1
        let devices = try context.fetch(devicePeek)
        let sites = try context.fetch(sitePeek)
        let provider = try context.fetch(FetchDescriptor<SyncProvider>()).first
        if devices.isEmpty && sites.isEmpty {
            return .full("empty store")
        }
        guard let watermark = provider?.lastObjectChangeId else {
            return .full("no watermark")
        }
        if let lastFull = provider?.lastFullMirrorAt,
           Date().timeIntervalSince(lastFull) >= safetyMirrorInterval {
            return .full("safety interval")
        }
        return .delta(watermark)
    }

    // MARK: - Writes

    func patchInterface(
        id: Int64,
        enabled: Bool? = nil,
        description: String? = nil,
        label: String? = nil
    ) async throws {
        try await performWrite(announce: false, waitForSync: false) {
            let tier = self.subscriptionTier()
            try await self.applyOnStore { context in
                let deviceID = try LicenseSeatEvaluator.deviceID(forInterface: id, in: context)
                try LicenseSeatEvaluator.requireSeated(deviceID: deviceID, in: context, tier: tier)
            }
            let body = NetBoxWriteBody.InterfacePatch(
                enabled: enabled,
                description: description,
                label: label
            )
            _ = try await self.writer.patchInterface(id: id, body: body)
            // Apply the fields we sent. A full retrieve is another NetBox
            // round-trip and is what made enable/description feel seconds
            // slower than the web UI.
            try await self.applyOnStore { context in
                try Self.applyLocalInterfacePatch(
                    id: id,
                    enabled: enabled,
                    description: description,
                    label: label,
                    in: context
                )
            }
        }
    }

    func createCable(from a: Int64, to b: Int64) async throws {
        try await performWrite {
            let tier = self.subscriptionTier()
            try await self.applyOnStore { context in
                let left = try LicenseSeatEvaluator.deviceID(forInterface: a, in: context)
                let right = try LicenseSeatEvaluator.deviceID(forInterface: b, in: context)
                try LicenseSeatEvaluator.requireLink(a: left, b: right, in: context, tier: tier)
            }
            let created = try await self.writer.createCable(.connecting(a, to: b))
            try await self.applyCableAndEnds(id: created.id)
        }
    }

    func createCable(
        fromFrontPort a: Int64,
        toInterface b: Int64
    ) async throws {
        try await performWrite {
            let tier = self.subscriptionTier()
            try await self.applyOnStore { context in
                let left = try LicenseSeatEvaluator.deviceID(forFrontPort: a, in: context)
                let right = try LicenseSeatEvaluator.deviceID(forInterface: b, in: context)
                try LicenseSeatEvaluator.requireLink(a: left, b: right, in: context, tier: tier)
            }
            let created = try await self.writer.createCable(
                .connectingFrontPort(a, toInterface: b)
            )
            try await self.applyCableAndEnds(id: created.id)
        }
    }

    func createCable(
        fromFrontPort a: Int64,
        toFrontPort b: Int64
    ) async throws {
        try await performWrite {
            let tier = self.subscriptionTier()
            try await self.applyOnStore { context in
                let left = try LicenseSeatEvaluator.deviceID(forFrontPort: a, in: context)
                let right = try LicenseSeatEvaluator.deviceID(forFrontPort: b, in: context)
                try LicenseSeatEvaluator.requireLink(a: left, b: right, in: context, tier: tier)
            }
            let created = try await self.writer.createCable(
                .connectingFrontPorts(a, to: b)
            )
            try await self.applyCableAndEnds(id: created.id)
        }
    }

    func disconnectFrontPort(id: Int64, knownCableId: Int64?) async throws {
        try await performWrite {
            let tier = self.subscriptionTier()
            try await self.applyOnStore { context in
                try LicenseSeatEvaluator.requireLinkIfPeerKnown(
                    deviceID: try LicenseSeatEvaluator.deviceID(forFrontPort: id, in: context),
                    peer: try? LicenseSeatEvaluator.peerDeviceID(forFrontPort: id, in: context),
                    in: context,
                    tier: tier
                )
            }
            let cableId = try await self.resolveFrontPortCableID(id: id, known: knownCableId)
            let peer = try await self.applyOnStore { context -> (type: String, id: Int64)? in
                let descriptor = FetchDescriptor<FrontPort>(
                    predicate: #Predicate<FrontPort> { $0.id == id }
                )
                guard let row = try context.fetch(descriptor).first,
                      let peerID = row.connectedEndpointId,
                      let type = row.connectedEndpointType else {
                    return nil
                }
                return (type, peerID)
            }
            try await self.writer.deleteCable(id: cableId)
            try await self.deleteLocalCableAndRefreshEnds(id: cableId)
            try await self.applyDeltaItem(
                NetBoxDeltaItem(
                    kind: .frontPort,
                    objectID: id,
                    action: "update",
                    changeID: 0,
                    time: nil
                )
            )
            if let peer {
                if peer.type == "dcim.interface" {
                    try await self.applyDeltaItem(
                        NetBoxDeltaItem(
                            kind: .interface,
                            objectID: peer.id,
                            action: "update",
                            changeID: 0,
                            time: nil
                        )
                    )
                } else if peer.type == "dcim.frontport" {
                    try await self.applyDeltaItem(
                        NetBoxDeltaItem(
                            kind: .frontPort,
                            objectID: peer.id,
                            action: "update",
                            changeID: 0,
                            time: nil
                        )
                    )
                }
            }
        }
    }

    func deleteCable(id: Int64, refreshing interfaceIDs: [Int64]) async throws {
        try await performWrite {
            let tier = self.subscriptionTier()
            try await self.applyOnStore { context in
                try LicenseSeatEvaluator.requireSeatedEnds(
                    interfaceIDs: interfaceIDs, in: context, tier: tier
                )
            }
            try await self.writer.deleteCable(id: id)
            try await self.deleteLocalCableAndRefreshEnds(id: id, extraInterfaceIDs: interfaceIDs)
        }
    }

    /// Disconnect even when the local row predates `cableId`. A missing
    /// id is resolved from a live interface retrieve, then DELETE.
    func disconnectInterface(
        id: Int64,
        knownCableId: Int64?,
        refreshing interfaceIDs: [Int64]
    ) async throws {
        try await performWrite {
            let tier = self.subscriptionTier()
            try await self.applyOnStore { context in
                try LicenseSeatEvaluator.requireLinkIfPeerKnown(
                    deviceID: try LicenseSeatEvaluator.deviceID(forInterface: id, in: context),
                    peer: try? LicenseSeatEvaluator.peerDeviceID(forInterface: id, in: context),
                    in: context,
                    tier: tier
                )
            }
            let cableId = try await self.resolveCableID(interfaceID: id, known: knownCableId)
            try await self.writer.deleteCable(id: cableId)
            var ends = Set(interfaceIDs)
            ends.insert(id)
            try await self.deleteLocalCableAndRefreshEnds(id: cableId, extraInterfaceIDs: Array(ends))
        }
    }

    private func resolveCableID(interfaceID: Int64, known: Int64?) async throws -> Int64 {
        if let known { return known }
        let data = try await fetcher.get(path: "/api/dcim/interfaces/\(interfaceID)/", query: [])
        let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Interface.self, from: data)
        _ = try await applyOnStore {
            try NetBoxStore.applyInterfaces(
                [row], fetchComplete: false, skipped: 0, keeping: [], in: $0
            )
        }
        guard let cableID = row.cableID else {
            throw NetBoxSyncError.httpStatus(
                code: 404,
                body: "NetBox has no cable on interface \(interfaceID)"
            )
        }
        return cableID
    }

    private func resolveFrontPortCableID(id: Int64, known: Int64?) async throws -> Int64 {
        if let known { return known }
        let data = try await fetcher.get(path: "/api/dcim/front-ports/\(id)/", query: [])
        let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.FrontPort.self, from: data)
        _ = try await applyOnStore {
            try NetBoxStore.applyFrontPorts(
                [row], fetchComplete: false, skipped: 0, keeping: [], in: $0
            )
        }
        guard let cableID = row.cableID else {
            throw NetBoxSyncError.httpStatus(
                code: 404,
                body: "NetBox has no cable on front port \(id)"
            )
        }
        return cableID
    }

    func patchDevice(id: Int64, body: NetBoxWriteBody.DevicePatch) async throws {
        try await performWrite {
            if self.writePolicy.deviceAndSiteWritesEnabled {
                let tier = self.subscriptionTier()
                try await self.applyOnStore { context in
                    try LicenseSeatEvaluator.requireSeated(deviceID: id, in: context, tier: tier)
                }
            }
            _ = try await self.writer.patchDevice(id: id, body: body)
            try await self.applyDeltaItem(
                NetBoxDeltaItem(
                    kind: .device,
                    objectID: id,
                    action: "update",
                    changeID: 0,
                    time: nil
                )
            )
            await self.recordPatchedDeviceSeat(id)
        }
    }

    func createDevice(_ body: NetBoxWriteBody.DeviceCreate) async throws {
        try await performWrite {
            #if DEBUG
            let total = ContinuousClock.now
            #endif
            if self.writePolicy.deviceAndSiteWritesEnabled {
                let tier = self.subscriptionTier()
                #if DEBUG
                let admit = ContinuousClock.now
                #endif
                do {
                    try await self.applyOnStore { context in
                        try LicenseSeatEvaluator.requireAdmit(
                            roleID: body.role, in: context, tier: tier
                        )
                    }
                    #if DEBUG
                    self.logger.info("timing createDevice admit \(createDeviceMilliseconds(since: admit))ms")
                    #endif
                } catch {
                    self.logger.error(
                        "createDevice admit refused (tier \(tier.displayName, privacy: .public)): \(error.localizedDescription)"
                    )
                    throw error
                }
            }
            #if DEBUG
            let post = ContinuousClock.now
            #endif
            let response = try await self.writer.createDevice(body)
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Device.self, from: response.body)
            #if DEBUG
            self.logger.info(
                "timing createDevice POST /api/dcim/devices/ \(response.body.count) bytes id \(row.id) \(createDeviceMilliseconds(since: post))ms"
            )
            let stored = ContinuousClock.now
            #endif
            // The 201 is the device record. A follow-up GET repeats it,
            // including config_context, which Pulse does not store.
            try await self.upsertRetrieved(kind: .device, data: response.body)
            #if DEBUG
            self.logger.info(
                "timing createDevice store POST body \(createDeviceMilliseconds(since: stored))ms"
            )
            #endif
            if self.writePolicy.deviceAndSiteWritesEnabled {
                #if DEBUG
                let grant = ContinuousClock.now
                #endif
                await self.recordCreatedDeviceSeat(row.id)
                #if DEBUG
                self.logger.info("timing createDevice grant seat \(createDeviceMilliseconds(since: grant))ms")
                #endif
            }
            do {
                #if DEBUG
                let interfaces = ContinuousClock.now
                let count = try await self.refreshDeviceInterfaces(deviceID: row.id)
                self.logger.info(
                    "timing createDevice GET /api/dcim/interfaces/?device_id=\(row.id) \(count) rows \(createDeviceMilliseconds(since: interfaces))ms"
                )
                #else
                try await self.refreshDeviceInterfaces(deviceID: row.id)
                #endif
            } catch {
                self.logger.error(
                    "Could not load interfaces for new device \(row.id): \(error.localizedDescription)"
                )
            }
            #if DEBUG
            self.logger.info("timing createDevice total \(createDeviceMilliseconds(since: total))ms")
            #endif
        }
    }

    func createSite(_ body: NetBoxWriteBody.SiteCreate) async throws {
        try await performWrite {
            let response = try await self.writer.createSite(body)
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Site.self, from: response.body)
            try await self.applyDeltaItem(
                NetBoxDeltaItem(
                    kind: .site,
                    objectID: row.id,
                    action: "create",
                    changeID: 0,
                    time: nil
                )
            )
        }
    }

    func createRack(_ body: NetBoxWriteBody.RackCreate) async throws {
        try await performWrite {
            let response = try await self.writer.createRack(body)
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Rack.self, from: response.body)
            try await self.applyDeltaItem(
                NetBoxDeltaItem(
                    kind: .rack,
                    objectID: row.id,
                    action: "create",
                    changeID: 0,
                    time: nil
                )
            )
        }
    }

    /// Operator writes apply the object they touched. The changelog window
    /// belongs to `sync()`, Full Resync, and the idle loop. The idle pass
    /// stops before the next changelog page, and between objects, so this
    /// waits out the current page rather than the rest of the window.
    private func performWrite(
        announce: Bool = true,
        waitForSync: Bool = true,
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws {
        // A burst shares one quiet delta. Cancel the timer the previous
        // success armed before this write's POST starts.
        quietCatchUp?.cancel()
        quietCatchUp = nil
        writeDepth += 1
        writeInProgress = true
        var succeeded = false
        var serial: UInt64 = 0
        defer { finishWriteFrame(succeeded: succeeded, serial: serial) }

        if waitForSync, let running = inFlight {
            try await running.value
        }
        let previous = writes
        let task = Task { () throws -> SyncSeatUpdate? in
            try? await previous?.value
            if let idle = await self.idleTask {
                await idle.value
            }
            // A user sync may have claimed the engine while this write
            // waited for the idle pass to stop.
            if waitForSync, let running = await self.inFlight {
                try await running.value
            }
            do {
                try await work()
            } catch {
                self.pendingSeatUpdate = nil
                throw error
            }
            let update = self.pendingSeatUpdate
            self.pendingSeatUpdate = nil
            return update
        }
        writeSerial += 1
        serial = writeSerial
        writeTailSerial = serial
        writes = task
        do {
            let update = try await task.value
            succeeded = true
            if announce {
                await postApply(NetBoxApplyInfo(origin: .write, seatUpdate: update ?? .empty))
            }
        } catch {
            if let syncError = error as? NetBoxSyncError {
                await syncError.publish()
            }
            throw error
        }
    }

    /// Drops one `performWrite` frame. The quiet delta and the flag wait
    /// until the last frame in the chain returns.
    private func finishWriteFrame(succeeded: Bool, serial: UInt64) {
        if succeeded {
            writeChainNeedsCatchUp = true
        }
        writeDepth -= 1
        guard writeDepth == 0 else { return }
        if serial != 0, writeTailSerial == serial {
            writes = nil
        }
        writeInProgress = false
        if writeChainNeedsCatchUp {
            writeChainNeedsCatchUp = false
            scheduleQuietCatchUp()
        }
    }

    /// One delta, 2s after the last successful write. Rearming cancels the
    /// previous quiet task so a burst of adds shares a single pass. No-op
    /// until `startIdleChangelog()` has armed the loop (tests stay quiet).
    private func scheduleQuietCatchUp() {
        guard idleLoop != nil else { return }
        quietCatchUp?.cancel()
        quietCatchUp = Task {
            try? await Task.sleep(for: Self.idleChangelogQuietPeriod)
            guard !Task.isCancelled else { return }
            await self.runIdleCatchUp()
        }
    }

    private static func applyLocalInterfacePatch(
        id: Int64,
        enabled: Bool?,
        description: String?,
        label: String?,
        in context: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<Interface>(
            predicate: #Predicate<Interface> { $0.id == id }
        )
        guard let row = try context.fetch(descriptor).first else { return }
        if let enabled { row.enabled = enabled }
        if let description { row.interfaceDescription = description }
        if let label { row.label = label }
        try context.save()
    }

    // MARK: - Types

    private func syncTenantGroups() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/tenancy/tenant-groups/",
            extraQuery: [],
            as: Components.Schemas.TenantGroup.self
        )
        let records = rows.map(NetBoxMapping.tenantGroup)
        _ = try await applyOnStore { context in
            try NetBoxStore.applyTenantGroups(
                records, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncDeviceRoles() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/device-roles/",
            extraQuery: [],
            as: Components.Schemas.DeviceRole.self
        )
        let records = rows.map(NetBoxMapping.deviceRole)
        _ = try await applyOnStore { context in
            try NetBoxStore.applyDeviceRoles(
                records, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncDeviceTypes() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/device-types/",
            extraQuery: [],
            as: Components.Schemas.DeviceType.self
        )
        let records = rows.map(NetBoxMapping.deviceType)
        _ = try await applyOnStore { context in
            try NetBoxStore.applyDeviceTypes(
                records, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncTenants() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/tenancy/tenants/",
            extraQuery: [],
            as: NetBoxRecord.Tenant.self
        )
        _ = try await applyOnStore { context in
            try NetBoxStore.applyTenants(
                rows, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncRegions() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/regions/",
            extraQuery: [],
            as: Components.Schemas.Region.self
        )
        let records = rows.map(NetBoxMapping.region)
        _ = try await applyOnStore { context in
            try NetBoxStore.applyRegions(
                records, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncSiteGroups() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/site-groups/",
            extraQuery: [],
            as: Components.Schemas.SiteGroup.self
        )
        let records = rows.map(NetBoxMapping.siteGroup)
        _ = try await applyOnStore { context in
            try NetBoxStore.applySiteGroups(
                records, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncSites() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/sites/",
            extraQuery: [],
            as: NetBoxRecord.Site.self
        )
        _ = try await applyOnStore { context in
            try NetBoxStore.applySites(
                rows, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncLocations() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/locations/",
            extraQuery: [],
            as: NetBoxRecord.Location.self
        )
        _ = try await applyOnStore { context in
            try NetBoxStore.applyLocations(
                rows, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncRackRoles() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/rack-roles/",
            extraQuery: [],
            as: NetBoxRecord.RackRole.self
        )
        _ = try await applyOnStore { context in
            try NetBoxStore.applyRackRoles(
                rows, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncRacks() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/racks/",
            extraQuery: [],
            as: NetBoxRecord.Rack.self
        )
        _ = try await applyOnStore { context in
            try NetBoxStore.applyRacks(
                rows, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncDevices() async throws {
        let keeping = AcceptedInterfaceIDs()
        let walk = try await NetBoxPageIterator.streamDecoded(
            path: "/api/dcim/devices/",
            extraQuery: [],
            as: NetBoxRecord.Device.self,
            using: fetcher,
            maxPages: NetBoxPageIterator.interfaceMaxPages
        ) { page, _ in
            _ = try await self.applyOnStore { context in
                try NetBoxStore.applyDevices(
                    page, fetchComplete: false, skipped: 0, in: context
                )
            }
            await keeping.formUnion(Set(page.map(\.id)))
        }
        let seen = await keeping.ids
        _ = try await applyOnStore { context in
            try NetBoxStore.applyDevices(
                [],
                fetchComplete: true,
                skipped: walk.skipped,
                keeping: seen,
                in: context
            )
        }
    }

    private func syncDeviceBays() async throws {
        let keeping = AcceptedInterfaceIDs()
        let missingShelves = AcceptedInterfaceIDs()
        let walk = try await NetBoxPageIterator.streamDecoded(
            path: "/api/dcim/device-bays/",
            extraQuery: [],
            as: NetBoxRecord.DeviceBay.self,
            using: fetcher,
            maxPages: NetBoxPageIterator.interfaceMaxPages
        ) { page, _ in
            let result = try await self.applyOnStore { context in
                try NetBoxStore.applyDeviceBays(
                    page,
                    fetchComplete: false,
                    skipped: 0,
                    keeping: [],
                    in: context
                )
            }
            await keeping.formUnion(result.acceptedIDs)
            await missingShelves.formUnion(result.missingParentIDs)
        }
        let missing = await missingShelves.ids
        var retrySkipped = 0
        if !missing.isEmpty {
            try await fetchAndApplyDevices(ids: missing)
            for shelfID in missing.sorted() {
                let extra = [URLQueryItem(name: "device_id", value: String(shelfID))]
                let (rows, skipped) = try await fetchAll(
                    path: "/api/dcim/device-bays/",
                    extraQuery: extra,
                    as: NetBoxRecord.DeviceBay.self
                )
                retrySkipped += skipped
                let retry = try await applyOnStore { context in
                    try NetBoxStore.applyDeviceBays(
                        rows, fetchComplete: false, skipped: 0, keeping: [], in: context
                    )
                }
                await keeping.formUnion(retry.acceptedIDs)
                if !retry.missingParentIDs.isEmpty {
                    let sample = retry.missingParentIDs.sorted().prefix(5).map(String.init).joined(separator: ", ")
                    logger.error(
                        "Dropped device bays whose shelf is still missing after retrieve (\(retry.missingParentIDs.count) devices, e.g. \(sample))."
                    )
                }
            }
        }
        let seen = await keeping.ids
        let skipped = walk.skipped + retrySkipped
        _ = try await applyOnStore { context in
            try NetBoxStore.applyDeviceBays(
                [],
                fetchComplete: true,
                skipped: skipped,
                keeping: seen,
                in: context
            )
        }
    }

    private func syncFrontPorts() async throws {
        let keeping = AcceptedInterfaceIDs()
        let missingDevices = AcceptedInterfaceIDs()
        let walk = try await NetBoxPageIterator.streamDecoded(
            path: "/api/dcim/front-ports/",
            extraQuery: [],
            as: NetBoxRecord.FrontPort.self,
            using: fetcher,
            maxPages: NetBoxPageIterator.interfaceMaxPages
        ) { page, _ in
            let result = try await self.applyOnStore { context in
                try NetBoxStore.applyFrontPorts(
                    page,
                    fetchComplete: false,
                    skipped: 0,
                    keeping: [],
                    in: context
                )
            }
            await keeping.formUnion(result.acceptedIDs)
            await missingDevices.formUnion(result.missingParentIDs)
        }
        let missing = await missingDevices.ids
        var retrySkipped = 0
        if !missing.isEmpty {
            try await fetchAndApplyDevices(ids: missing)
            for deviceID in missing.sorted() {
                let extra = [URLQueryItem(name: "device_id", value: String(deviceID))]
                let (rows, skipped) = try await fetchAll(
                    path: "/api/dcim/front-ports/",
                    extraQuery: extra,
                    as: NetBoxRecord.FrontPort.self
                )
                retrySkipped += skipped
                let retry = try await applyOnStore { context in
                    try NetBoxStore.applyFrontPorts(
                        rows, fetchComplete: false, skipped: 0, keeping: [], in: context
                    )
                }
                await keeping.formUnion(retry.acceptedIDs)
                if !retry.missingParentIDs.isEmpty {
                    let sample = retry.missingParentIDs.sorted().prefix(5).map(String.init).joined(separator: ", ")
                    logger.error(
                        "Dropped front ports whose device is still missing after retrieve (\(retry.missingParentIDs.count) devices, e.g. \(sample))."
                    )
                }
            }
        }
        let seen = await keeping.ids
        let skipped = walk.skipped + retrySkipped
        _ = try await applyOnStore { context in
            try NetBoxStore.applyFrontPorts(
                [],
                fetchComplete: true,
                skipped: skipped,
                keeping: seen,
                in: context
            )
        }
    }

    /// Parents named by bays or front ports that were not in the store
    /// yet. Fetch by id and store so the children can attach.
    private func fetchAndApplyDevices(ids: Set<Int64>) async throws {
        guard !ids.isEmpty else { return }
        let extra = ids.sorted().map { URLQueryItem(name: "id", value: String($0)) }
        let (rows, _) = try await fetchAll(
            path: "/api/dcim/devices/",
            extraQuery: extra,
            as: NetBoxRecord.Device.self
        )
        guard !rows.isEmpty else { return }
        _ = try await applyOnStore { context in
            try NetBoxStore.applyDevices(
                rows, fetchComplete: false, skipped: 0, in: context
            )
        }
    }

    private func syncServices() async throws {
        let keeping = AcceptedInterfaceIDs()
        let walk = try await NetBoxPageIterator.streamDecoded(
            path: "/api/ipam/services/",
            extraQuery: [],
            as: NetBoxRecord.Service.self,
            using: fetcher,
            maxPages: NetBoxPageIterator.interfaceMaxPages
        ) { page, _ in
            _ = try await self.applyOnStore { context in
                try NetBoxStore.applyServices(
                    page, fetchComplete: false, skipped: 0, in: context
                )
            }
            await keeping.formUnion(Set(page.map(\.id)))
        }
        let seen = await keeping.ids
        _ = try await applyOnStore { context in
            try NetBoxStore.applyServices(
                [],
                fetchComplete: true,
                skipped: walk.skipped,
                keeping: seen,
                in: context
            )
        }
    }

    private func syncInterfaces() async throws {
        let keeping = AcceptedInterfaceIDs()
        let walk = try await NetBoxPageIterator.streamDecoded(
            path: "/api/dcim/interfaces/",
            extraQuery: [],
            as: NetBoxRecord.Interface.self,
            using: fetcher,
            maxPages: NetBoxPageIterator.interfaceMaxPages
        ) { page, _ in
            let result = try await self.applyOnStore { context in
                try NetBoxStore.applyInterfaces(
                    page,
                    fetchComplete: false,
                    skipped: 0,
                    keeping: [],
                    in: context
                )
            }
            await keeping.formUnion(result.acceptedIDs)
        }
        let seen = await keeping.ids
        _ = try await applyOnStore { context in
            try NetBoxStore.applyInterfaces(
                [],
                fetchComplete: true,
                skipped: walk.skipped,
                keeping: seen,
                in: context
            )
        }
    }

    private func syncCables() async throws {
        let keeping = AcceptedInterfaceIDs()
        let walk = try await NetBoxPageIterator.streamDecoded(
            path: "/api/dcim/cables/",
            extraQuery: [],
            as: NetBoxRecord.Cable.self,
            using: fetcher,
            maxPages: NetBoxPageIterator.interfaceMaxPages
        ) { page, _ in
            let result = try await self.applyOnStore { context in
                try NetBoxStore.applyCables(
                    page,
                    fetchComplete: false,
                    skipped: 0,
                    keeping: [],
                    in: context
                )
            }
            await keeping.formUnion(result.acceptedIDs)
        }
        let seen = await keeping.ids
        _ = try await applyOnStore { context in
            try NetBoxStore.applyCables(
                [],
                fetchComplete: true,
                skipped: walk.skipped,
                keeping: seen,
                in: context
            )
        }
    }

    // MARK: - Fetch

    private func fetchAll<T: Decodable & Sendable>(
        path: String,
        extraQuery: [URLQueryItem],
        as type: T.Type
    ) async throws -> (rows: [T], skipped: Int) {
        try await NetBoxPageIterator.fetchDecoded(
            path: path,
            extraQuery: extraQuery,
            as: type,
            using: fetcher
        )
    }

    /// SwiftData fetch/save on this actor can run at Background while boot
    /// or the dashboard wait at User-initiated — a priority inversion.
    /// Create the context on a detached user-initiated task instead.
    private func applyOnStore<Result: Sendable>(
        _ work: @Sendable @escaping (ModelContext) throws -> Result
    ) async throws -> Result {
        let container = modelContainer
        return try await Task.detached(priority: .userInitiated) {
            try work(ModelContext(container))
        }.value
    }

    // MARK: - Delta

    /// Template interfaces NetBox creates with the device. Never a delete pass.
    private func refreshDeviceInterfaces(deviceID: Int64) async throws -> Int {
        let extra = [URLQueryItem(name: "device_id", value: String(deviceID))]
        let (rows, _) = try await fetchAll(
            path: "/api/dcim/interfaces/",
            extraQuery: extra,
            as: NetBoxRecord.Interface.self
        )
        _ = try await applyOnStore {
            try NetBoxStore.applyInterfaces(
                rows, fetchComplete: false, skipped: 0, keeping: [], in: $0
            )
        }
        return rows.count
    }

    /// Changelog since the watermark, without a full mirror. Each fully
    /// applied page stamps its own high water before the next page is
    /// fetched. A transport or decode failure retries from that watermark.
    /// A page cap is reported once and latched. Pages applied before the
    /// cap stay applied. Launch and Apply changes clear the latch and
    /// still full-mirror when the cap is hit.
    private func performIdleCatchUp() async {
        beginSeatPass(wholeStore: false)
        let plan: SyncPlan
        do {
            plan = try await applyOnStore { context in
                try Self.decideSync(in: context)
            }
        } catch {
            logger.error("Idle changelog could not read the sync plan: \(error.localizedDescription)")
            return
        }
        switch plan {
        case .full(let reason):
            if lastIdleSkipLog != reason {
                logger.info("Idle changelog skipped; full mirror is due (\(reason, privacy: .public))")
                lastIdleSkipLog = reason
            }
            return
        case .delta(let watermarkID):
            lastIdleSkipLog = nil
            if watermarkID > 0, await changelogRecordMissing(id: watermarkID) {
                logger.error("Idle changelog skipped; watermark \(watermarkID) is gone")
                return
            }
            do {
                let applied = try await performDelta(
                    after: watermarkID,
                    fallbackToFullMirror: false,
                    yieldToWriters: true
                )
                if applied > 0 {
                    await postApply(await makeSeatNotice())
                }
            } catch let error as NetBoxSyncError where error == .pageLimitExceeded {
                idlePageCapLatched = true
                logger.error("Idle changelog exceeded the page cap; waiting for Apply changes or launch")
                await MainActor.run {
                    NetBoxSyncError.pageLimitExceeded.publish()
                }
                await postPartialDelta()
            } catch let error where Self.isForbidden(error) {
                logger.error("Idle changelog was refused; waiting for Apply changes or launch")
                await postPartialDelta()
            } catch {
                logger.error("Idle changelog failed: \(error.localizedDescription)")
                await postPartialDelta()
            }
        }
    }

    private func changelogRecordMissing(id: Int64) async -> Bool {
        do {
            _ = try await fetcher.get(path: "/api/core/object-changes/\(id)/", query: [])
            return false
        } catch NetBoxSyncError.httpStatus(let code, _) where code == 404 {
            return true
        } catch {
            return false
        }
    }

    /// Applies the `id__gt` window one page at a time. Returns how many
    /// objects were applied. A fully read page is coalesced on its own,
    /// applied, and stamped before the next page is fetched. The watermark
    /// never moves backward. `fallbackToFullMirror` is the boot / Apply
    /// changes page-cap path. The idle pass passes false and does not
    /// full-mirror. `yieldToWriters` stops before the next page, and
    /// between objects, when a write or a user sync is waiting. A page
    /// that was not fully applied is not stamped.
    @discardableResult
    private func performDelta(
        after watermarkID: Int64,
        fallbackToFullMirror: Bool,
        yieldToWriters: Bool
    ) async throws -> Int {
        let extra = [
            URLQueryItem(name: "id__gt", value: String(watermarkID)),
            URLQueryItem(name: "ordering", value: "id"),
        ]
        let progress = ChangelogCursor(cursor: watermarkID)
        do {
            _ = try await NetBoxPageIterator.streamDecoded(
                path: "/api/core/object-changes/",
                extraQuery: extra,
                as: NetBoxRecord.ObjectChange.self,
                using: fetcher,
                beforePage: {
                    if yieldToWriters {
                        try await self.stopIfWriterWaiting()
                    }
                }
            ) { page, pageSkipped in
                try await self.consumeChangelogPage(
                    page,
                    pageSkipped: pageSkipped,
                    yieldToWriters: yieldToWriters,
                    progress: progress
                )
            }
            if !progress.moved {
                try await stampDeltaSuccess(
                    id: watermarkID,
                    time: nil,
                    summary: "no changes"
                )
            }
            await clearPermission(path: Self.changelogListPath)
            await refreshTouchedSites(progress)
            return progress.applied
        } catch is ChangelogYield {
            logger.info("Idle changelog paused for a write or sync")
            await clearPermission(path: Self.changelogListPath)
            await refreshTouchedSites(progress)
            return progress.applied
        } catch let error as NetBoxSyncError where error == .pageLimitExceeded {
            if fallbackToFullMirror {
                logger.error("Changelog exceeded the page cap; falling back to a full mirror")
                do {
                    let cursor = try? await latestChangelogCursor()
                    try await performFullSync(progress: nil)
                    try await stampFullSuccess(cursor: cursor)
                } catch {
                    await refreshTouchedSites(progress)
                    throw error
                }
                beginSeatPass(wholeStore: true)
                await refreshTouchedSites(progress)
                return 0
            }
            logger.error("Changelog exceeded the page cap; applied pages stay stamped")
            await clearPermission(path: Self.changelogListPath)
            await refreshTouchedSites(progress)
            throw error
        } catch {
            if Self.isForbidden(error) {
                await noteChangelogForbidden()
            }
            await refreshTouchedSites(progress)
            throw error
        }
    }

    /// One changelog page. Throws `ChangelogYield` before stamping when a
    /// writer is waiting, and throws without stamping when the page skipped
    /// an element or an object apply failed. Unknown types are logged and
    /// still advance the high water when their id is ahead of the cursor.
    private func consumeChangelogPage(
        _ rows: [NetBoxRecord.ObjectChange],
        pageSkipped: Int,
        yieldToWriters: Bool,
        progress: ChangelogCursor
    ) async throws {
        if pageSkipped > 0 {
            throw NetBoxSyncError.dataError("Changelog page skipped \(pageSkipped) elements")
        }
        let planned = NetBoxDelta.coalesce(rows)
        for unknown in rows where NetBoxChangeKind(objectType: unknown.changedObjectType) == nil {
            logger.error(
                "Skipping unknown changelog type \(unknown.changedObjectType, privacy: .public) id \(unknown.changedObjectID)"
            )
        }
        for item in planned.items {
            if yieldToWriters, writeInProgress || inFlight != nil || userSyncWaiting {
                throw ChangelogYield()
            }
            let applied = try await applyDeltaItem(item)
            guard applied else { continue }
            progress.applied += 1
            passAppliedCount = progress.applied
            if item.kind == .device {
                passDeviceIDs.append(item.objectID)
                progress.touchedDeviceSites = true
            }
        }
        if let water = planned.highWater, water.id > progress.cursor {
            try await stampDeltaSuccess(
                id: water.id,
                time: water.time,
                summary: "applied \(progress.applied) objects"
            )
            progress.cursor = water.id
            progress.moved = true
        }
    }

    private func refreshTouchedSites(_ progress: ChangelogCursor) async {
        guard progress.touchedDeviceSites else { return }
        progress.touchedDeviceSites = false
        await SiteDataService(modelContainer: modelContainer).refreshSeverities()
    }

    /// False when the token cannot read this model. The local row stays,
    /// and the page may still stamp. A 404 still deletes the local row.
    @discardableResult
    private func applyDeltaItem(_ item: NetBoxDeltaItem) async throws -> Bool {
        if deniedListPaths.contains(item.kind.retrievePath) {
            return false
        }
        if item.kind == .cable {
            if item.action == "delete" {
                try await deleteLocalCableAndRefreshEnds(id: item.objectID)
                return true
            }
            return try await applyCableAndEnds(id: item.objectID)
        }
        if item.action == "delete" {
            try await deleteObject(kind: item.kind, id: item.objectID)
            return true
        }
        do {
            let data = try await fetcher.get(
                path: "\(item.kind.retrievePath)\(item.objectID)/",
                query: []
            )
            try await upsertRetrieved(kind: item.kind, data: data)
            await clearPermission(path: item.kind.retrievePath)
            return true
        } catch NetBoxSyncError.httpStatus(let code, _) where code == 404 {
            try await deleteObject(kind: item.kind, id: item.objectID)
            return true
        } catch {
            guard Self.isForbidden(error) else { throw error }
            await noteOptionalForbidden(path: item.kind.retrievePath)
            return false
        }
    }

    /// Persist the cable row and re-fetch both interface ends.
    /// False when the token cannot read cables. The local cable stays.
    private func applyCableAndEnds(id: Int64) async throws -> Bool {
        let data: Data
        do {
            data = try await fetcher.get(path: "/api/dcim/cables/\(id)/", query: [])
        } catch NetBoxSyncError.httpStatus(let code, _) where code == 404 {
            try await deleteLocalCableAndRefreshEnds(id: id)
            return true
        } catch {
            guard Self.isForbidden(error) else { throw error }
            await noteOptionalForbidden(path: NetBoxChangeKind.cable.retrievePath)
            return false
        }
        let cable = try NetBoxListDecoder.decodeObject(NetBoxRecord.Cable.self, from: data)
        _ = try await applyOnStore {
            try NetBoxStore.applyCables(
                [cable], fetchComplete: false, skipped: 0, keeping: [], in: $0
            )
        }
        for interfaceID in cable.interfaceIDs {
            try await applyDeltaItem(
                NetBoxDeltaItem(
                    kind: .interface,
                    objectID: interfaceID,
                    action: "update",
                    changeID: 0,
                    time: nil
                )
            )
        }
        for portID in cable.frontPortIDs {
            try await applyDeltaItem(
                NetBoxDeltaItem(
                    kind: .frontPort,
                    objectID: portID,
                    action: "update",
                    changeID: 0,
                    time: nil
                )
            )
        }
        await clearPermission(path: NetBoxChangeKind.cable.retrievePath)
        return true
    }

    private func deleteLocalCableAndRefreshEnds(
        id: Int64,
        extraInterfaceIDs: [Int64] = []
    ) async throws {
        let stored = try await applyOnStore { context -> [Int64] in
            let ends = try Self.localCableEnds(id: id, in: context)
            _ = try NetBoxStore.deleteIDs(Cable.self, ids: [id], in: context)
            return ends
        }
        var ends = Set(stored)
        ends.formUnion(extraInterfaceIDs)
        for interfaceID in ends {
            try await applyDeltaItem(
                NetBoxDeltaItem(
                    kind: .interface,
                    objectID: interfaceID,
                    action: "update",
                    changeID: 0,
                    time: nil
                )
            )
        }
    }

    private static func localCableEnds(id: Int64, in context: ModelContext) throws -> [Int64] {
        let descriptor = FetchDescriptor<Cable>(
            predicate: #Predicate<Cable> { $0.id == id }
        )
        guard let cable = try context.fetch(descriptor).first else { return [] }
        return [cable.aInterfaceId, cable.bInterfaceId].compactMap { $0 }
    }

    private func upsertRetrieved(kind: NetBoxChangeKind, data: Data) async throws {
        switch kind {
        case .tenantGroup:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.TenantGroup.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyTenantGroups([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .deviceRole:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.DeviceRole.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyDeviceRoles([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .deviceType:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.DeviceType.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyDeviceTypes([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .tenant:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Tenant.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyTenants([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .region:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Region.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyRegions([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .siteGroup:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.SiteGroup.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applySiteGroups([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .site:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Site.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applySites([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .location:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Location.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyLocations([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .rackRole:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.RackRole.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyRackRoles([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .rack:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Rack.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyRacks([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .device:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Device.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyDevices([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .deviceBay:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.DeviceBay.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyDeviceBays(
                    [row], fetchComplete: false, skipped: 0, keeping: [], in: $0
                )
            }
        case .frontPort:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.FrontPort.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyFrontPorts(
                    [row], fetchComplete: false, skipped: 0, keeping: [], in: $0
                )
            }
        case .interface:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Interface.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyInterfaces(
                    [row], fetchComplete: false, skipped: 0, keeping: [], in: $0
                )
            }
        case .service:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Service.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyServices([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .cable:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Cable.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyCables(
                    [row], fetchComplete: false, skipped: 0, keeping: [], in: $0
                )
            }
        }
    }

    private func deleteObject(kind: NetBoxChangeKind, id: Int64) async throws {
        _ = try await applyOnStore { context -> Int in
            switch kind {
            case .tenantGroup: return try NetBoxStore.deleteIDs(TenantGroup.self, ids: [id], in: context)
            case .deviceRole: return try NetBoxStore.deleteIDs(DeviceRole.self, ids: [id], in: context)
            case .deviceType: return try NetBoxStore.deleteIDs(DeviceType.self, ids: [id], in: context)
            case .tenant: return try NetBoxStore.deleteIDs(Tenant.self, ids: [id], in: context)
            case .region: return try NetBoxStore.deleteIDs(Region.self, ids: [id], in: context)
            case .siteGroup: return try NetBoxStore.deleteIDs(SiteGroup.self, ids: [id], in: context)
            case .site: return try NetBoxStore.deleteIDs(Site.self, ids: [id], in: context)
            case .location: return try NetBoxStore.deleteIDs(SiteLocation.self, ids: [id], in: context)
            case .rackRole: return try NetBoxStore.deleteIDs(RackRole.self, ids: [id], in: context)
            case .rack: return try NetBoxStore.deleteIDs(Rack.self, ids: [id], in: context)
            case .device: return try NetBoxStore.deleteIDs(Device.self, ids: [id], in: context)
            case .deviceBay: return try NetBoxStore.deleteIDs(DeviceBay.self, ids: [id], in: context)
            case .frontPort: return try NetBoxStore.deleteIDs(FrontPort.self, ids: [id], in: context)
            case .interface: return try NetBoxStore.deleteIDs(Interface.self, ids: [id], in: context)
            case .service: return try NetBoxStore.deleteIDs(Service.self, ids: [id], in: context)
            case .cable: return try NetBoxStore.deleteIDs(Cable.self, ids: [id], in: context)
            }
        }
    }

    private func latestChangelogCursor() async throws -> (id: Int64, time: Date?)? {
        let (rows, _) = try await NetBoxPageIterator.fetchDecoded(
            path: "/api/core/object-changes/",
            extraQuery: [
                URLQueryItem(name: "ordering", value: "-id"),
                URLQueryItem(name: "limit", value: "1"),
            ],
            as: NetBoxRecord.ObjectChange.self,
            using: fetcher,
            maxPages: 1
        )
        guard let first = rows.first else { return nil }
        return (first.id, first.time)
    }

    private func stampFullSuccess(cursor: (id: Int64, time: Date?)?) async throws {
        _ = try await applyOnStore { context in
            let now = Date()
            let provider = try Self.upsertProvider(in: context)
            provider.lastNetBoxUpdate = now
            provider.lastFullMirrorAt = now
            if let cursor {
                provider.lastObjectChangeId = cursor.id
                provider.lastObjectChangeTime = cursor.time
            } else if provider.lastObjectChangeId == nil {
                provider.lastObjectChangeId = 0
            }
            provider.lastDeltaSummary = "full mirror"
            try context.save()
            return true
        }
    }

    private func stampDeltaSuccess(id: Int64, time: Date?, summary: String) async throws {
        _ = try await applyOnStore { context in
            let provider = try Self.upsertProvider(in: context)
            provider.lastNetBoxUpdate = Date()
            provider.lastObjectChangeId = id
            if let time {
                provider.lastObjectChangeTime = time
            }
            provider.lastDeltaSummary = summary
            try context.save()
            return true
        }
    }

    private static func upsertProvider(in context: ModelContext) throws -> SyncProvider {
        let existing = try context.fetch(FetchDescriptor<SyncProvider>())
        if let provider = existing.first {
            return provider
        }
        let created = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
        context.insert(created)
        return created
    }

    private func beginSeatPass(wholeStore: Bool) {
        passDeviceIDs.removeAll(keepingCapacity: true)
        passAppliedCount = 0
        passSeatsWholeStore = wholeStore
    }

    /// Seats devices a delta already saved when a later page fails.
    /// A full-mirror pass seats from `sync()` / `fullSync()` instead.
    private func postPartialDelta() async {
        guard passAppliedCount > 0, !passSeatsWholeStore else { return }
        await postApply(await makeSeatNotice())
    }

    /// Grants after the pass has saved. A full mirror seats the whole
    /// store and skips rows whose stamp is already right. A delta seats
    /// the device ids that pass applied.
    private func makeSeatNotice() async -> NetBoxApplyInfo {
        let whole = passSeatsWholeStore
        let ids = passDeviceIDs
        let tier = subscriptionTier()
        let update: SyncSeatUpdate
        if whole || !ids.isEmpty {
            do {
                update = try await applyOnStore { context in
                    if whole {
                        return try LicenseSeatEvaluator.grantMirroredStore(
                            in: context, tier: tier
                        )
                    }
                    return try LicenseSeatEvaluator.grantArrivals(
                        deviceIDs: ids, in: context, tier: tier
                    )
                }
            } catch {
                self.logger.error("Seat grant failed: \(error.localizedDescription)")
                update = .empty
            }
        } else {
            update = .empty
        }
        return NetBoxApplyInfo(origin: .sync, seatUpdate: update)
    }

    private func recordCreatedDeviceSeat(_ id: Int64) async {
        let tier = subscriptionTier()
        do {
            pendingSeatUpdate = try await applyOnStore { context in
                try LicenseSeatEvaluator.grantNewDevice(id: id, in: context, tier: tier)
            }
        } catch {
            logger.error("createDevice seat grant failed: \(error.localizedDescription)")
        }
    }

    private func recordPatchedDeviceSeat(_ id: Int64) async {
        let tier = subscriptionTier()
        do {
            pendingSeatUpdate = try await applyOnStore { context in
                try LicenseSeatEvaluator.grantArrivals(
                    deviceIDs: [id], in: context, tier: tier
                )
            }
        } catch {
            logger.error("patchDevice seat grant failed: \(error.localizedDescription)")
        }
    }

    private func stopIfWriterWaiting() throws {
        if writeInProgress || inFlight != nil || userSyncWaiting {
            throw ChangelogYield()
        }
    }

    private func postApply(_ info: NetBoxApplyInfo) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .netBoxStoreDidApply,
                object: nil,
                userInfo: [NetBoxApplyInfo.userInfoKey: info]
            )
        }
    }
}

/// Stops an idle changelog before the next page, or between objects on
/// the page being applied. Not a NetBox error. Pages already applied
/// keep their watermark. The page that stopped is not stamped.
private struct ChangelogYield: Error {}

/// High water for the changelog pass currently being applied.
/// Mutated only on `NetBoxSyncEngine`.
private final class ChangelogCursor: @unchecked Sendable {
    var applied = 0
    var cursor: Int64
    var touchedDeviceSites = false
    var moved = false

    init(cursor: Int64) {
        self.cursor = cursor
    }
}

#if DEBUG
/// Milliseconds since `start`. Debug Add Device timing only.
private func createDeviceMilliseconds(since start: ContinuousClock.Instant) -> Int {
    let duration = start.duration(to: .now)
    let ms = Double(duration.components.seconds) * 1000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    return Int(ms.rounded())
}
#endif

private extension NetBoxSyncError {
    static func dataError(_ message: String) -> NetBoxSyncError {
        .httpStatus(code: 0, body: message)
    }
}

/// Accumulates accepted interface ids across streamed pages without
/// capturing a mutable `Set` in a Sendable closure.
private actor AcceptedInterfaceIDs {
    private(set) var ids: Set<Int64> = []
    func formUnion(_ other: Set<Int64>) { ids.formUnion(other) }
}

// MARK: - Environment

extension Notification.Name {
    /// Posted on the main actor after a successful write, full mirror,
    /// or delta apply has been saved. `userInfo` carries `NetBoxApplyInfo`.
    static let netBoxStoreDidApply = Notification.Name("netbox.storeDidApply")
}

struct NetBoxApplyInfo: Sendable {
    static let userInfoKey = "netbox.apply"

    enum Origin: Sendable, Equatable {
        case write
        case sync
    }

    var origin: Origin
    var seatUpdate: SyncSeatUpdate
}

private struct NetBoxSyncEngineKey: EnvironmentKey {
    static let defaultValue: NetBoxSyncEngine? = nil
}

extension EnvironmentValues {
    var netBoxSyncEngine: NetBoxSyncEngine? {
        get { self[NetBoxSyncEngineKey.self] }
        set { self[NetBoxSyncEngineKey.self] = newValue }
    }
}
