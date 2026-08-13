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

/// Single owner of NetBox read-sync. Boot and Sync Dashboard both call
/// `fullSync()`. Overlapping callers join the in-flight pass. `lastNetBoxUpdate`
/// is stamped only after every type applies successfully.
actor NetBoxSyncEngine {
    private let modelContainer: ModelContainer
    private let fetcher: any NetBoxFetching
    private let filter: NetBoxFilterConfiguration
    private let logger = Logger(subsystem: "netbox", category: "sync")
    private var inFlight: Task<Void, Error>?

    init(
        modelContainer: ModelContainer,
        fetcher: any NetBoxFetching = NetBoxLiveFetcher(),
        filter: NetBoxFilterConfiguration = .default
    ) {
        self.modelContainer = modelContainer
        self.fetcher = fetcher
        self.filter = filter
    }

    /// Tenant groups → roles → types → tenants → regions → site groups →
    /// sites → racks → devices → services, then streaming interfaces.
    /// `onInventoryReady` fires after services so boot can leave the
    /// loading screen while interfaces continue. Stamp still waits for
    /// the interface walk.
    func fullSync(
        progress: (@Sendable (Int, String) -> Void)? = nil,
        onInventoryReady: (@Sendable () async -> Void)? = nil
    ) async throws {
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task(priority: .userInitiated) {
            try await self.performFullSync(
                progress: progress,
                onInventoryReady: onInventoryReady
            )
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

    private func performFullSync(
        progress: (@Sendable (Int, String) -> Void)?,
        onInventoryReady: (@Sendable () async -> Void)?
    ) async throws {
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
        ]
        for (index, stage) in stages.enumerated() {
            progress?(index, stage.0)
            try await stage.1()
        }
        await onInventoryReady?()
        try await syncInterfaces()
        try await stampSuccess()
        await MainActor.run {
            RequestStatusManager.shared.clearSyncing(.netbox)
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
        await MainActor.run {
            RequestStatusManager.shared.updateStatus(
                .netbox,
                .syncing("Synchronising interfaces…")
            )
        }
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

    private func stampSuccess() async throws {
        _ = try await applyOnStore { context in
            let existing = try context.fetch(FetchDescriptor<SyncProvider>())
            if let provider = existing.first {
                provider.lastNetBoxUpdate = Date()
            } else {
                context.insert(
                    SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
                )
            }
            try context.save()
            return true
        }
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
