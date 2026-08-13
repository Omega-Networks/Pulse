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
    private let filter: NetBoxFilterConfiguration
    private let writePolicy: NetBoxWritePolicy
    private let logger = Logger(subsystem: "netbox", category: "sync")
    private var inFlight: Task<Void, Error>?
    private var writes: Task<Void, Error>?

    init(
        modelContainer: ModelContainer,
        fetcher: any NetBoxFetching = NetBoxLiveFetcher(),
        filter: NetBoxFilterConfiguration = .default,
        writePolicy: NetBoxWritePolicy = .shipped
    ) {
        self.modelContainer = modelContainer
        self.fetcher = fetcher
        self.filter = filter
        self.writePolicy = writePolicy
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
            try await self.performFullSync(progress: progress)
            try await self.stampFullSuccess()
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            try await task.value
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
            ("Synchronising Racks...", { try await self.syncRacks() }),
            ("Synchronising Devices...", { try await self.syncDevices() }),
            ("Synchronising Services...", { try await self.syncServices() }),
            ("Synchronising Interfaces...", { try await self.syncInterfaces() }),
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
            try await performFullSync(progress: progress)
            try await stampFullSuccess()
        case .delta(let watermarkID):
            if await changelogRecordMissing(id: watermarkID) {
                logger.error("Watermark \(watermarkID) is gone; forcing full mirror")
                try await performFullSync(progress: progress)
                try await stampFullSuccess()
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

    func patchInterface(id: Int64, enabled: Bool? = nil, description: String? = nil) async throws {
        try await performWrite {
            let body = NetBoxWriteBody.InterfacePatch(
                enabled: enabled,
                description: description
            )
            _ = try await self.writer.patchInterface(id: id, body: body)
            try await self.applyDeltaItem(
                NetBoxDeltaItem(
                    kind: .interface,
                    objectID: id,
                    action: "update",
                    changeID: 0,
                    time: nil
                )
            )
        }
    }

    func createCable(from a: Int64, to b: Int64) async throws {
        try await performWrite {
            let created = try await self.writer.createCable(.connecting(a, to: b))
            try await self.refreshCableInterfaces(id: created.id)
        }
    }

    func deleteCable(id: Int64, refreshing interfaceIDs: [Int64]) async throws {
        try await performWrite {
            try await self.writer.deleteCable(id: id)
            for interfaceID in interfaceIDs {
                try await self.applyDeltaItem(
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
    }

    func patchDevice(id: Int64, body: NetBoxWriteBody.DevicePatch) async throws {
        try await performWrite {
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

    private func performWrite(_ work: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight {
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
        } catch {
            if let syncError = error as? NetBoxSyncError {
                await syncError.publish()
            }
            throw error
        }
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
        let extra = filter.excludedRoleQueryAsInts.map {
            URLQueryItem(name: "id__n", value: String($0))
        }
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/device-roles/",
            extraQuery: extra,
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
        let extra = filter.excludedManufacturerQuery.map {
            URLQueryItem(name: "manufacturer_id__n", value: String($0))
        }
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/device-types/",
            extraQuery: extra,
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
        var extra = filter.excludedManufacturerQuery.map {
            URLQueryItem(name: "manufacturer_id__n", value: String($0))
        }
        extra += filter.excludedRoleQueryAsStrings.map {
            URLQueryItem(name: "role_id__n", value: $0)
        }
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/devices/",
            extraQuery: extra,
            as: NetBoxRecord.Device.self
        )
        _ = try await applyOnStore { context in
            try NetBoxStore.applyDevices(
                rows, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncServices() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/ipam/services/",
            extraQuery: [],
            as: NetBoxRecord.Service.self
        )
        _ = try await applyOnStore { context in
            try NetBoxStore.applyServices(
                rows, fetchComplete: true, skipped: skipped, in: context
            )
        }
    }

    private func syncInterfaces() async throws {
        let extra = filter.excludedRoleQueryAsInts.map {
            URLQueryItem(name: "device_role_id__n", value: String($0))
        }
        let keeping = AcceptedInterfaceIDs()
        let walk = try await NetBoxPageIterator.streamDecoded(
            path: "/api/dcim/interfaces/",
            extraQuery: extra,
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
        let (rows, skipped) = try await fetchAll(
            path: "/api/core/object-changes/",
            extraQuery: extra,
            as: NetBoxRecord.ObjectChange.self
        )
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
        if item.action == "delete" {
            try await deleteObject(kind: item.kind, id: item.objectID)
            return
        }
        if item.kind == .cable {
            try await refreshCableInterfaces(id: item.objectID)
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

    private func refreshCableInterfaces(id: Int64) async throws {
        let data: Data
        do {
            data = try await fetcher.get(path: "/api/dcim/cables/\(id)/", query: [])
        } catch NetBoxSyncError.httpStatus(let code, _) where code == 404 {
            return
        }
        let cable = try NetBoxListDecoder.decodeObject(NetBoxRecord.Cable.self, from: data)
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
            guard filter.includesDeviceRole(id: Int(row.id)) else {
                try await deleteObject(kind: .deviceRole, id: row.id)
                return
            }
            _ = try await applyOnStore {
                try NetBoxStore.applyDeviceRoles([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .deviceType:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.DeviceType.self, from: data)
            guard filter.includesDeviceType(manufacturerID: Int(row.manufacturerID)) else {
                try await deleteObject(kind: .deviceType, id: row.id)
                return
            }
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
        case .rack:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Rack.self, from: data)
            _ = try await applyOnStore {
                try NetBoxStore.applyRacks([row], fetchComplete: false, skipped: 0, in: $0)
            }
        case .device:
            let row = try NetBoxListDecoder.decodeObject(NetBoxRecord.Device.self, from: data)
            guard filter.includesDevice(
                manufacturerID: row.manufacturerID.map(Int.init),
                roleID: Int(row.roleID)
            ) else {
                try await deleteObject(kind: .device, id: row.id)
                return
            }
            _ = try await applyOnStore {
                try NetBoxStore.applyDevices([row], fetchComplete: false, skipped: 0, in: $0)
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
            break
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
            case .rack: return try NetBoxStore.deleteIDs(Rack.self, ids: [id], in: context)
            case .device: return try NetBoxStore.deleteIDs(Device.self, ids: [id], in: context)
            case .interface: return try NetBoxStore.deleteIDs(Interface.self, ids: [id], in: context)
            case .service: return try NetBoxStore.deleteIDs(Service.self, ids: [id], in: context)
            case .cable: return 0
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

    private func stampFullSuccess() async throws {
        let cursor = try? await latestChangelogCursor()
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

private struct NetBoxSyncEngineKey: EnvironmentKey {
    static let defaultValue: NetBoxSyncEngine? = nil
}

extension EnvironmentValues {
    var netBoxSyncEngine: NetBoxSyncEngine? {
        get { self[NetBoxSyncEngineKey.self] }
        set { self[NetBoxSyncEngineKey.self] = newValue }
    }
}
