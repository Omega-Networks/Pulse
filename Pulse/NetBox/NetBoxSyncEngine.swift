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

/// Single owner of NetBox read-sync and MACD writes. Boot and Sync
/// Dashboard both call `fullSync()`. Overlapping callers join the
/// in-flight pass. `lastNetBoxUpdate` is stamped only after every type
/// applies successfully. Writes wait for that pass, then re-fetch
/// through the delta-apply path — no speculative local state.
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
    private var writes: Task<Void, Error>?

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

    /// Boot entry: delta when a watermark is usable, otherwise a full mirror.
    func sync(progress: (@Sendable (Int, String) -> Void)? = nil) async throws {
        try? await writes?.value
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task(priority: .userInitiated) {
            try await self.performBootSync(progress: progress)
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            try await task.value
            await announceStoreDidApply()
        } catch {
            logger.error("NetBox sync failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Settings → Sync Data. Always a full mirror, then a fresh watermark.
    func fullSync(progress: (@Sendable (Int, String) -> Void)? = nil) async throws {
        try? await writes?.value
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task(priority: .userInitiated) {
            let cursor = try? await self.latestChangelogCursor()
            try await self.performFullSync(progress: progress)
            try await self.stampFullSuccess(cursor: cursor)
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            try await task.value
            await announceStoreDidApply()
        } catch {
            logger.error("NetBox full sync failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func performFullSync(progress: (@Sendable (Int, String) -> Void)?) async throws {
        let stages: [(String, () async throws -> Void)] = [
            ("Synchronising Tenant Groups...", { try await self.syncTenantGroups() }),
            ("Synchronising Device Roles...", { try await self.syncDeviceRoles() }),
            ("Synchronising Device Types...", { try await self.syncDeviceTypes() }),
            ("Synchronising Tenants...", { try await self.syncTenants() }),
            ("Synchronising Regions...", { try await self.syncRegions() }),
            ("Synchronising Site Groups...", { try await self.syncSiteGroups() }),
            ("Synchronising Sites...", { try await self.syncSites() }),
            ("Synchronising Locations...", { try await self.syncLocations() }),
            ("Synchronising Rack Roles...", { try await self.syncRackRoles() }),
            ("Synchronising Racks...", { try await self.syncRacks() }),
            ("Synchronising Devices...", { try await self.syncDevices() }),
            ("Synchronising Device Bays...", { try await self.syncDeviceBays() }),
            ("Synchronising Front Ports...", { try await self.syncFrontPorts() }),
            ("Synchronising Services...", { try await self.syncServices() }),
            ("Synchronising Interfaces...", { try await self.syncInterfaces() }),
            ("Synchronising Cables...", { try await self.syncCables() }),
        ]
        for (index, stage) in stages.enumerated() {
            progress?(index, stage.0)
            try await stage.1()
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
            try await performDelta(after: watermarkID)
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
        try await performWrite(catchUp: false, announce: false, waitForSync: false) {
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
        }
    }

    func createDevice(_ body: NetBoxWriteBody.DeviceCreate) async throws {
        try await performWrite {
            if self.writePolicy.deviceAndSiteWritesEnabled {
                let tier = self.subscriptionTier()
                do {
                    try await self.applyOnStore { context in
                        try LicenseSeatEvaluator.requireAdmit(
                            roleID: body.role, in: context, tier: tier
                        )
                    }
                } catch {
                    self.logger.error(
                        "createDevice admit refused (tier \(tier.displayName, privacy: .public)): \(error.localizedDescription)"
                    )
                    throw error
                }
            }
            let response = try await self.writer.createDevice(body)
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Device.self, from: response.body)
            try await self.applyDeltaItem(
                NetBoxDeltaItem(
                    kind: .device,
                    objectID: row.id,
                    action: "create",
                    changeID: 0,
                    time: nil
                )
            )
            do {
                try await self.refreshDeviceInterfaces(deviceID: row.id)
            } catch {
                self.logger.error(
                    "Could not load interfaces for new device \(row.id): \(error.localizedDescription)"
                )
            }
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

    private func performWrite(
        catchUp: Bool = true,
        announce: Bool = true,
        waitForSync: Bool = true,
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws {
        if waitForSync, let inFlight {
            try await inFlight.value
        }
        let previous = writes
        let task = Task {
            try? await previous?.value
            try await work()
        }
        writes = task
        do {
            try await task.value
            if announce {
                await MainActor.run {
                    NotificationCenter.default.post(name: .netBoxStoreDidApply, object: nil)
                }
            }
            if catchUp {
                await catchUpWatermark()
            }
        } catch {
            if let syncError = error as? NetBoxSyncError {
                await syncError.publish()
            }
            throw error
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
    private func refreshDeviceInterfaces(deviceID: Int64) async throws {
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
    }

    /// Advance the changelog watermark after a write so the next boot
    /// does not re-walk side effects. Failure is logged, not thrown.
    private func catchUpWatermark() async {
        let watermark: Int64?
        do {
            watermark = try await applyOnStore { context in
                try context.fetch(FetchDescriptor<SyncProvider>()).first?.lastObjectChangeId
            }
        } catch {
            logger.error("Post-write watermark read failed: \(error.localizedDescription)")
            return
        }
        guard let watermark else { return }
        do {
            try await performDelta(after: watermark)
        } catch {
            logger.error("Post-write changelog catch-up failed: \(error.localizedDescription)")
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

    private func performDelta(after watermarkID: Int64) async throws {
        let extra = [
            URLQueryItem(name: "id__gt", value: String(watermarkID)),
            URLQueryItem(name: "ordering", value: "id"),
        ]
        let rows: [NetBoxRecord.ObjectChange]
        let skipped: Int
        do {
            (rows, skipped) = try await fetchAll(
                path: "/api/core/object-changes/",
                extraQuery: extra,
                as: NetBoxRecord.ObjectChange.self
            )
        } catch NetBoxSyncError.pageLimitExceeded {
            logger.error("Changelog exceeded the page cap; falling back to a full mirror")
            let cursor = try? await latestChangelogCursor()
            try await performFullSync(progress: nil)
            try await stampFullSuccess(cursor: cursor)
            return
        }
        if skipped > 0 {
            throw NetBoxSyncError.dataError("Changelog page skipped \(skipped) elements")
        }
        let planned = NetBoxDelta.coalesce(rows)
        for unknown in rows where NetBoxChangeKind(objectType: unknown.changedObjectType) == nil {
            logger.error(
                "Skipping unknown changelog type \(unknown.changedObjectType, privacy: .public) id \(unknown.changedObjectID)"
            )
        }
        var touchedDeviceSites = false
        for item in planned.items {
            try await applyDeltaItem(item)
            if item.kind == .device { touchedDeviceSites = true }
        }
        if let water = planned.highWater {
            try await stampDeltaSuccess(
                id: water.id,
                time: water.time,
                summary: "applied \(planned.items.count) objects"
            )
        } else {
            try await stampDeltaSuccess(
                id: watermarkID,
                time: nil,
                summary: "no changes"
            )
        }
        if touchedDeviceSites {
            await SiteDataService(modelContainer: modelContainer).refreshSeverities()
        }
    }

    private func applyDeltaItem(_ item: NetBoxDeltaItem) async throws {
        if item.kind == .cable {
            if item.action == "delete" {
                try await deleteLocalCableAndRefreshEnds(id: item.objectID)
            } else {
                try await applyCableAndEnds(id: item.objectID)
            }
            return
        }
        if item.action == "delete" {
            try await deleteObject(kind: item.kind, id: item.objectID)
            return
        }
        do {
            let data = try await fetcher.get(
                path: "\(item.kind.retrievePath)\(item.objectID)/",
                query: []
            )
            try await upsertRetrieved(kind: item.kind, data: data)
        } catch NetBoxSyncError.httpStatus(let code, _) where code == 404 {
            try await deleteObject(kind: item.kind, id: item.objectID)
        }
    }

    /// Persist the cable row and re-fetch both interface ends.
    private func applyCableAndEnds(id: Int64) async throws {
        let data: Data
        do {
            data = try await fetcher.get(path: "/api/dcim/cables/\(id)/", query: [])
        } catch NetBoxSyncError.httpStatus(let code, _) where code == 404 {
            try await deleteLocalCableAndRefreshEnds(id: id)
            return
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

    private func announceStoreDidApply() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .netBoxStoreDidApply, object: nil)
        }
    }
}

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
    /// or delta apply has been re-fetched into SwiftData.
    static let netBoxStoreDidApply = Notification.Name("netbox.storeDidApply")
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
