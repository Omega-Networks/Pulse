//
//  NetBoxSyncEngine.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
    /// sites → racks → devices → services.
    func fullSync(progress: (@Sendable (Int, String) -> Void)? = nil) async throws {
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task { try await self.performFullSync(progress: progress) }
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
        ]
        for (index, stage) in stages.enumerated() {
            progress?(index, stage.0)
            try await stage.1()
        }
        try stampSuccess()
    }

    // MARK: - Types

    private func syncTenantGroups() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/tenancy/tenant-groups/",
            extraQuery: [],
            as: Components.Schemas.TenantGroup.self
        )
        _ = try NetBoxStore.applyTenantGroups(
            rows.map(NetBoxMapping.tenantGroup),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
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
        _ = try NetBoxStore.applyDeviceRoles(
            rows.map(NetBoxMapping.deviceRole),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
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
        _ = try NetBoxStore.applyDeviceTypes(
            rows.map(NetBoxMapping.deviceType),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
    }

    private func syncTenants() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/tenancy/tenants/",
            extraQuery: [],
            as: Components.Schemas.Tenant.self
        )
        _ = try NetBoxStore.applyTenants(
            rows.map(NetBoxMapping.tenant),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
    }

    private func syncRegions() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/regions/",
            extraQuery: [],
            as: Components.Schemas.Region.self
        )
        _ = try NetBoxStore.applyRegions(
            rows.map(NetBoxMapping.region),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
    }

    private func syncSiteGroups() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/site-groups/",
            extraQuery: [],
            as: Components.Schemas.SiteGroup.self
        )
        _ = try NetBoxStore.applySiteGroups(
            rows.map(NetBoxMapping.siteGroup),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
    }

    private func syncSites() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/sites/",
            extraQuery: [],
            as: Components.Schemas.Site.self
        )
        _ = try NetBoxStore.applySites(
            rows.map(NetBoxMapping.site),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
    }

    private func syncRacks() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/dcim/racks/",
            extraQuery: [],
            as: Components.Schemas.Rack.self
        )
        _ = try NetBoxStore.applyRacks(
            rows.map(NetBoxMapping.rack),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
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
            as: Components.Schemas.DeviceWithConfigContext.self
        )
        _ = try NetBoxStore.applyDevices(
            rows.map(NetBoxMapping.device),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
    }

    private func syncServices() async throws {
        let (rows, skipped) = try await fetchAll(
            path: "/api/ipam/services/",
            extraQuery: [],
            as: Components.Schemas.Service.self
        )
        _ = try NetBoxStore.applyServices(
            rows.map(NetBoxMapping.service),
            fetchComplete: true,
            skipped: skipped,
            in: ModelContext(modelContainer)
        )
    }

    // MARK: - Fetch

    private func fetchAll<T: Decodable & Sendable>(
        path: String,
        extraQuery: [URLQueryItem],
        as type: T.Type
    ) async throws -> (rows: [T], skipped: Int) {
        var skipped = 0
        var rows: [T] = []
        var offset = 0
        while true {
            var query = extraQuery
            query.append(URLQueryItem(name: "limit", value: String(NetBoxPageIterator.pageLimit)))
            query.append(URLQueryItem(name: "offset", value: String(offset)))
            let data = try await fetcher.get(path: path, query: query)
            let page = try NetBoxListDecoder.decodePage(T.self, from: data)
            skipped += page.skipped
            rows.append(contentsOf: page.results)
            guard page.next != nil else { break }
            guard !page.results.isEmpty else { throw NetBoxSyncError.emptyPageWithNext }
            offset += page.results.count
        }
        return (rows, skipped)
    }

    private func stampSuccess() throws {
        let context = ModelContext(modelContainer)
        let existing = try context.fetch(FetchDescriptor<SyncProvider>())
        if let provider = existing.first {
            provider.lastNetBoxUpdate = Date()
        } else {
            context.insert(
                SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date.distantPast)
            )
        }
        try context.save()
    }
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
