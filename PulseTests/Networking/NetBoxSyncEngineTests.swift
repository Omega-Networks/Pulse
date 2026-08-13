//
//  NetBoxSyncEngineTests.swift
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

final class NetBoxSyncEngineTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Interface.self, Service.self, WebHostTrust.self,
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

    func testTenantsAreFetchedAndStored() async throws {
        let container = try makeContainer()
        let fetcher = MockNetBoxFetcher()
        fetcher.emptySuccess = true
        fetcher.bodies["/api/tenancy/tenant-groups/"] = Data("""
        { "count": 1, "next": null, "results": [
          { "id": 4, "url": "u", "display_url": "d", "display": "Customers",
            "name": "Customers", "slug": "customers",
            "created": "2024-01-02T03:04:05Z",
            "last_updated": "2024-01-02T03:04:05Z",
            "tenant_count": 1, "_depth": 0 }
        ] }
        """.utf8)
        fetcher.bodies["/api/tenancy/tenants/"] = Data("""
        { "count": 1, "next": null, "results": [
          {
            "id": 1, "url": "u", "display_url": "d", "display": "Acme",
            "name": "Acme", "slug": "acme",
            "group": {
              "id": 4, "url": "u", "display": "Customers",
              "name": "Customers", "slug": "customers", "_depth": 0
            },
            "created": "2022-04-27T09:47:32.110929Z",
            "last_updated": "2022-04-27T09:50:23.049511Z"
          }
        ] }
        """.utf8)
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.fullSync()
        let tenants = try ModelContext(container).fetch(FetchDescriptor<Tenant>())
        XCTAssertEqual(tenants.count, 1)
        XCTAssertEqual(tenants.first?.name, "Acme")
        XCTAssertEqual(tenants.first?.group?.id, 4)
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

    func testInterfaceWalkUsesRoleExcludeAndRunsAfterInventoryReady() async throws {
        let container = try makeContainer()
        let fetcher = MockNetBoxFetcher()
        fetcher.emptySuccess = true
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        var readyAtCount = -1
        try await engine.fullSync(onInventoryReady: {
            readyAtCount = fetcher.paths.count
        })
        XCTAssertTrue(fetcher.paths.contains("/api/dcim/interfaces/"))
        XCTAssertGreaterThanOrEqual(readyAtCount, 0)
        XCTAssertFalse(fetcher.paths.prefix(readyAtCount).contains("/api/dcim/interfaces/"))
        let query = try XCTUnwrap(fetcher.queries["/api/dcim/interfaces/"])
        XCTAssertTrue(query.contains { $0.name == "device_role_id__n" && $0.value == "29" })
        XCTAssertTrue(query.contains { $0.name == "device_role_id__n" && $0.value == "30" })
    }

    func testInterfaceMidWalkFailureDoesNotStampOrDelete() async throws {
        let container = try makeContainer()
        let sitePage = Data("""
        {"count":1,"next":null,"results":[
          {"id":1,"name":"Lab","display":"Lab"}
        ]}
        """.utf8)
        let devicePage = Data("""
        {"count":1,"next":null,"results":[
          {"id":10,"name":"core",
           "site":{"id":1},"role":{"id":2},"device_type":{"id":8}}
        ]}
        """.utf8)
        let page1 = Data("""
        {"count":2,"next":"x","results":[
          {"id":1,"name":"eth0","device":{"id":10,"name":"d"},
           "enabled":true,"mtu":1500,"speed":1000,
           "lag":null,"bridge":null,"parent":null}
        ]}
        """.utf8)
        let fetcher = MockNetBoxFetcher()
        fetcher.emptySuccess = true
        fetcher.bodies["/api/dcim/sites/"] = sitePage
        fetcher.bodies["/api/dcim/devices/"] = devicePage
        fetcher.sequentialBodies["/api/dcim/interfaces/"] = [page1]
        fetcher.failAfterSequential = true
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        do {
            try await engine.fullSync()
            XCTFail("expected mid-walk failure")
        } catch {
            // expected
        }
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncProvider>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Interface>()).map(\.id), [1])
    }
}

private final class MockNetBoxFetcher: NetBoxFetching, @unchecked Sendable {
    var paths: [String] = []
    var queries: [String: [URLQueryItem]] = [:]
    var bodies: [String: Data] = [:]
    var sequentialBodies: [String: [Data]] = [:]
    var sequentialIndex: [String: Int] = [:]
    var failAfterSequential = false
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
        if let pages = sequentialBodies[path] {
            let index = sequentialIndex[path, default: 0]
            sequentialIndex[path] = index + 1
            if index < pages.count {
                return pages[index]
            }
            if failAfterSequential {
                throw NetBoxSyncError.httpStatus(code: 500, body: "mid-walk")
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
