//
//  NetBoxSyncEngineTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
//

import Foundation
import SwiftData
import XCTest
@testable import Pulse

final class NetBoxSyncEngineTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Service.self, WebHostTrust.self,
            Event.self, SyncProvider.self, PowerSenseDevice.self, PowerSenseEvent.self,
            SSHCredential.self, KnownHost.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    func testFullSyncStampsOnlyAfterEveryTypeSucceeds() async throws {
        let container = try makeContainer()
        let fetcher = MockNetBoxFetcher()
        fetcher.emptySuccess = true
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.fullSync()
        let context = ModelContext(container)
        let providers = try context.fetch(FetchDescriptor<SyncProvider>())
        XCTAssertEqual(providers.count, 1)
        XCTAssertNotNil(providers.first?.lastNetBoxUpdate)
        XCTAssertTrue(fetcher.paths.contains("/api/tenancy/tenant-groups/"))
        XCTAssertTrue(fetcher.paths.contains("/api/dcim/regions/"))
        XCTAssertTrue(fetcher.paths.contains("/api/dcim/devices/"))
        XCTAssertTrue(fetcher.paths.contains("/api/ipam/services/"))
    }

    func testFailureDoesNotStampAndDoesNotDelete() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let existing = TenantGroup(id: 1)
        existing.name = "Keep"
        seed.insert(existing)
        let originalStamp = Date(timeIntervalSince1970: 1_700_000_000)
        seed.insert(SyncProvider(lastNetBoxUpdate: originalStamp, lastZabbixUpdate: originalStamp))
        try seed.save()

        let fetcher = MockNetBoxFetcher()
        fetcher.emptySuccess = true
        fetcher.failPath = "/api/tenancy/tenant-groups/"
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)

        do {
            try await engine.fullSync()
            XCTFail("expected failure")
        } catch let error as NetBoxSyncError {
            XCTAssertEqual(error, .httpStatus(code: 500, body: "boom"))
        }

        let context = ModelContext(container)
        let groups = try context.fetch(FetchDescriptor<TenantGroup>())
        XCTAssertEqual(groups.map(\.id), [1])
        let stamped = try context.fetch(FetchDescriptor<SyncProvider>()).first?.lastNetBoxUpdate
        XCTAssertEqual(stamped?.timeIntervalSince1970, originalStamp.timeIntervalSince1970)
    }

    func testOverlappingFullSyncCoalesces() async throws {
        let container = try makeContainer()
        let fetcher = MockNetBoxFetcher()
        fetcher.emptySuccess = true
        fetcher.delayNanoseconds = 50_000_000
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)

        async let first: Void = engine.fullSync()
        async let second: Void = engine.fullSync()
        _ = try await (first, second)

        let groupCalls = fetcher.paths.filter { $0 == "/api/tenancy/tenant-groups/" }.count
        XCTAssertEqual(groupCalls, 1)
    }

    func testTenantGroupsAreFetchedAndStored() async throws {
        let container = try makeContainer()
        let fetcher = MockNetBoxFetcher()
        fetcher.emptySuccess = true
        fetcher.bodies["/api/tenancy/tenant-groups/"] = Data("""
        { "count": 1, "next": null, "results": [
          { "id": 1, "url": "u", "display_url": "d", "display": "G",
            "name": "G", "slug": "g",
            "created": "2024-01-02T03:04:05Z",
            "last_updated": "2024-01-02T03:04:05Z",
            "tenant_count": 0, "_depth": 0 }
        ] }
        """.utf8)
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.fullSync()
        let groups = try ModelContext(container).fetch(FetchDescriptor<TenantGroup>())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "G")
    }

    func testDeviceQueryUsesFilterExcludes() async throws {
        let container = try makeContainer()
        let fetcher = MockNetBoxFetcher()
        fetcher.emptySuccess = true
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.fullSync()
        let deviceQuery = try XCTUnwrap(fetcher.queries["/api/dcim/devices/"])
        let names = deviceQuery.map(\.name)
        XCTAssertTrue(names.contains("manufacturer_id__n"))
        XCTAssertTrue(names.contains("role_id__n"))
        XCTAssertEqual(deviceQuery.first { $0.name == "manufacturer_id__n" }?.value, "5")
        XCTAssertTrue(deviceQuery.contains { $0.name == "role_id__n" && $0.value == "29" })
        XCTAssertTrue(deviceQuery.contains { $0.name == "role_id__n" && $0.value == "30" })
    }
}

private final class MockNetBoxFetcher: NetBoxFetching, @unchecked Sendable {
    var paths: [String] = []
    var queries: [String: [URLQueryItem]] = [:]
    var bodies: [String: Data] = [:]
    var failPath: String?
    var emptySuccess = false
    var delayNanoseconds: UInt64 = 0

    private let emptyPage = Data(#"{"count":0,"next":null,"results":[]}"#.utf8)

    func get(path: String, query: [URLQueryItem]) async throws -> Data {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        paths.append(path)
        queries[path] = query
        if path == failPath {
            throw NetBoxSyncError.httpStatus(code: 500, body: "boom")
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
