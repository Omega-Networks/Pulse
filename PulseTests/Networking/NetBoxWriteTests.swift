//
//  NetBoxWriteTests.swift
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

final class NetBoxWriteTests: XCTestCase {
    func testInterfacePatchOmitsNilAndDoesNotSendCustomFields() throws {
        let enabledOnly = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.InterfacePatch(enabled: false)
        )
        assertJSON(enabledOnly, ["enabled": false])

        let both = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.InterfacePatch(enabled: true, description: "uplink")
        )
        assertJSON(both, ["description": "uplink", "enabled": true])

        let cleared = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.InterfacePatch(description: "")
        )
        assertJSON(cleared, ["description": ""])

        let labelled = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.InterfacePatch(label: "uplink")
        )
        assertJSON(labelled, ["label": "uplink"])

        let clearedLabel = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.InterfacePatch(label: "")
        )
        assertJSON(clearedLabel, ["label": ""])
    }

    func testCustomFieldsSendsOnlyChangedKeys() throws {
        let body = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.InterfacePatch(
                customFields: [NetBoxCustomFields.coordinateX: .double(1.5)]
            )
        )
        assertJSON(body, ["custom_fields": [NetBoxCustomFields.coordinateX: 1.5]])
    }

    func testCableCreateUsesGenericObjectTerminations() throws {
        let body = try NetBoxWriteJSON.encode(NetBoxWriteBody.CableCreate.connecting(1, to: 2))
        assertJSON(body, [
            "a_terminations": [
                ["object_id": 1, "object_type": "dcim.interface"],
            ],
            "b_terminations": [
                ["object_id": 2, "object_type": "dcim.interface"],
            ],
        ])
    }

    func testDevicePatchAndSiteCreateJSONAreExact() throws {
        let device = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.DevicePatch(
                name: "core-1",
                customFields: [NetBoxCustomFields.zabbixID: .int(9)]
            )
        )
        assertJSON(device, [
            "custom_fields": [NetBoxCustomFields.zabbixID: 9],
            "name": "core-1",
        ])

        let site = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.SiteCreate(name: "Lab", slug: "lab", status: "active")
        )
        assertJSON(site, ["name": "Lab", "slug": "lab", "status": "active"])

        let created = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.DeviceCreate(
                name: "core-1",
                deviceType: 8,
                role: 6,
                site: 4,
                status: "active",
                tenant: 1,
                customFields: [NetBoxCustomFields.coordinateX: .double(10)]
            )
        )
        assertJSON(created, [
            "custom_fields": [NetBoxCustomFields.coordinateX: 10],
            "device_type": 8,
            "name": "core-1",
            "role": 6,
            "site": 4,
            "status": "active",
            "tenant": 1,
        ])
        XCTAssertEqual(NetBoxWriteBody.SiteCreate.slug(from: "Lab Site 1"), "lab-site-1")

        let frontCable = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.CableCreate.connectingFrontPort(80, toInterface: 12)
        )
        assertJSON(frontCable, [
            "a_terminations": [["object_id": 80, "object_type": "dcim.frontport"]],
            "b_terminations": [["object_id": 12, "object_type": "dcim.interface"]],
        ])

        let rack = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.RackCreate(name: "R1", site: 4, status: "active", uHeight: 42)
        )
        assertJSON(rack, [
            "name": "R1",
            "site": 4,
            "status": "active",
            "u_height": 42,
        ])

        let full = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.RackCreate(
                name: "01.1 - Primary Rack",
                site: 534,
                status: "active",
                uHeight: 18,
                startingUnit: 1,
                formFactor: "4-post-cabinet",
                width: 19,
                mountingDepth: 500,
                outerWidth: 600,
                outerHeight: 1008,
                outerDepth: 600,
                outerUnit: "mm",
                airflow: "front-to-rear",
                tenant: 1,
                location: 9,
                role: 3,
                weight: 54,
                maxWeight: 800,
                weightUnit: "kg"
            )
        )
        assertJSON(full, [
            "airflow": "front-to-rear",
            "form_factor": "4-post-cabinet",
            "location": 9,
            "max_weight": 800,
            "mounting_depth": 500,
            "name": "01.1 - Primary Rack",
            "outer_depth": 600,
            "outer_height": 1008,
            "outer_unit": "mm",
            "outer_width": 600,
            "role": 3,
            "site": 534,
            "starting_unit": 1,
            "status": "active",
            "tenant": 1,
            "u_height": 18,
            "weight": 54,
            "weight_unit": "kg",
            "width": 19,
        ])
    }

    func testDevicePatchSendsRackPositionFaceAndNullsOnUnrack() throws {
        let placed = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.DevicePatch(
                rack: 44,
                position: 12,
                face: "front"
            )
        )
        assertJSON(placed, [
            "face": "front",
            "position": 12,
            "rack": 44,
        ])

        let unracked = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.DevicePatch(clearRack: true)
        )
        assertJSON(unracked, [
            "position": NSNull(),
            "rack": NSNull(),
        ])

        let created = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.DeviceCreate(
                name: "PP-1",
                deviceType: 3,
                role: 18,
                site: 4,
                rack: 44,
                position: 10,
                face: "front"
            )
        )
        assertJSON(created, [
            "device_type": 3,
            "face": "front",
            "name": "PP-1",
            "position": 10,
            "rack": 44,
            "role": 18,
            "site": 4,
        ])
    }

    func testShippedPolicyDoesNotSendIfMatch() async throws {
        let container = try makeContainer()
        try seedInterface(in: container)
        let fetcher = WriteFetcher()
        fetcher.sendQueue = [
            NetBoxHTTPResponse(status: 200, body: Data("{}".utf8), etag: nil),
        ]
        fetcher.getBodies["/api/dcim/interfaces/88/"] = interfaceJSON(
            id: 88, enabled: false, description: "uplink", cableID: nil
        )
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.patchInterface(id: 88, enabled: false)
        XCTAssertEqual(fetcher.sends.map(\.method), ["PATCH"])
        XCTAssertNil(fetcher.sends.first?.ifMatch)
        assertJSON(try XCTUnwrap(fetcher.sends[0].body), ["enabled": false])
        let row = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<Interface>()).first
        )
        XCTAssertEqual(row.enabled, false)
        XCTAssertNil(row.interfaceDescription)
    }

    func testEmptyDescriptionPatchSendsEmptyStringNotOmit() async throws {
        let container = try makeContainer()
        try seedInterface(in: container)
        let fetcher = WriteFetcher()
        fetcher.sendQueue = [
            NetBoxHTTPResponse(status: 200, body: Data("{}".utf8), etag: nil),
        ]
        fetcher.getBodies["/api/dcim/interfaces/88/"] = interfaceJSON(
            id: 88, enabled: true, description: "", cableID: nil
        )
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.patchInterface(id: 88, description: "")
        XCTAssertEqual(fetcher.sends.map(\.method), ["PATCH"])
        assertJSON(try XCTUnwrap(fetcher.sends[0].body), ["description": ""])
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<Interface>()).first?.interfaceDescription,
            ""
        )
    }

    func testIfMatchPolicySendsHeaderFromGET() async throws {
        let container = try makeContainer()
        try seedInterface(in: container)
        let fetcher = WriteFetcher()
        fetcher.sendQueue = [
            NetBoxHTTPResponse(status: 200, body: Data("{}".utf8), etag: "W/\"2026-08-13\""),
            NetBoxHTTPResponse(status: 200, body: Data("{}".utf8), etag: nil),
        ]
        fetcher.getBodies["/api/dcim/interfaces/88/"] = interfaceJSON(
            id: 88, enabled: true, description: "", cableID: nil
        )
        let engine = NetBoxSyncEngine(
            modelContainer: container,
            fetcher: fetcher,
            writePolicy: NetBoxWritePolicy(deviceAndSiteWritesEnabled: false, sendIfMatch: true)
        )
        try await engine.patchInterface(id: 88, description: "core")
        XCTAssertEqual(fetcher.sends.map(\.method), ["GET", "PATCH"])
        XCTAssertEqual(fetcher.sends[1].ifMatch, "W/\"2026-08-13\"")
    }

    func testValidationAndForbiddenBodiesSurfaceVerbatim() async throws {
        let container = try makeContainer()
        try seedInterface(in: container)
        let fetcher = WriteFetcher()
        fetcher.sendError = NetBoxSyncError.httpStatus(
            code: 400,
            body: #"{"enabled":["This field is required."]}"#
        )
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        do {
            try await engine.patchInterface(id: 88, enabled: true)
            XCTFail("expected validation error")
        } catch let error as NetBoxSyncError {
            XCTAssertEqual(
                error,
                .httpStatus(code: 400, body: #"{"enabled":["This field is required."]}"#)
            )
        }
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<Interface>()).first?.enabled,
            true
        )

        fetcher.sendError = NetBoxSyncError.httpStatus(
            code: 403,
            body: #"{"detail":"You do not have permission to perform this action."}"#
        )
        do {
            try await engine.patchInterface(id: 88, enabled: false)
            XCTFail("expected 403")
        } catch let error as NetBoxSyncError {
            XCTAssertEqual(
                error,
                .httpStatus(
                    code: 403,
                    body: #"{"detail":"You do not have permission to perform this action."}"#
                )
            )
        }
    }

    func testConflict412IsReadableAndDoesNotOverwrite() async throws {
        let container = try makeContainer()
        try seedInterface(in: container)
        let fetcher = WriteFetcher()
        fetcher.sendError = NetBoxSyncError.httpStatus(
            code: 412,
            body: #"{"detail":"Object modified."}"#
        )
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        do {
            try await engine.patchInterface(id: 88, enabled: false)
            XCTFail("expected 412")
        } catch let error as NetBoxSyncError {
            XCTAssertEqual(
                error.localizedDescription,
                "NetBox conflict (412): Object modified."
            )
        }
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<Interface>()).first?.enabled,
            true
        )
    }

    func testCableCreateAndDeleteRefetchInterfaces() async throws {
        let container = try makeContainer()
        try seedInterface(in: container, extraIDs: [89])
        let fetcher = WriteFetcher()
        fetcher.sendQueue = [
            NetBoxHTTPResponse(
                status: 201,
                body: Data(#"{"id":9,"a_terminations":[{"object_type":"dcim.interface","object_id":88}],"b_terminations":[{"object_type":"dcim.interface","object_id":89}]}"#.utf8),
                etag: nil
            ),
        ]
        fetcher.getBodies["/api/dcim/cables/9/"] = Data(
            #"{"id":9,"a_terminations":[{"object_type":"dcim.interface","object_id":88}],"b_terminations":[{"object_type":"dcim.interface","object_id":89}]}"#.utf8
        )
        fetcher.getBodies["/api/dcim/interfaces/88/"] = interfaceJSON(
            id: 88, enabled: true, description: "", cableID: 9, endpoint: 89
        )
        fetcher.getBodies["/api/dcim/interfaces/89/"] = interfaceJSON(
            id: 89, enabled: true, description: "", cableID: 9, endpoint: 88
        )
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.createCable(from: 88, to: 89)
        XCTAssertEqual(fetcher.sends.map(\.method), ["POST"])
        XCTAssertEqual(fetcher.sends.first?.path, "/api/dcim/cables/")
        assertJSON(try XCTUnwrap(fetcher.sends[0].body), [
            "a_terminations": [["object_id": 88, "object_type": "dcim.interface"]],
            "b_terminations": [["object_id": 89, "object_type": "dcim.interface"]],
        ])
        let connected = try ModelContext(container).fetch(FetchDescriptor<Interface>())
        XCTAssertEqual(connected.count, 2)
        XCTAssertTrue(connected.allSatisfy { $0.cableId == 9 })
        let stored = try ModelContext(container).fetch(FetchDescriptor<Cable>())
        XCTAssertEqual(stored.map(\.id), [9])
        XCTAssertEqual(stored.first?.aInterfaceId, 88)
        XCTAssertEqual(stored.first?.bInterfaceId, 89)

        fetcher.sends.removeAll()
        fetcher.sendQueue = [
            NetBoxHTTPResponse(status: 204, body: Data(), etag: nil),
        ]
        fetcher.getBodies["/api/dcim/interfaces/88/"] = interfaceJSON(
            id: 88, enabled: true, description: "", cableID: nil
        )
        fetcher.getBodies["/api/dcim/interfaces/89/"] = interfaceJSON(
            id: 89, enabled: true, description: "", cableID: nil
        )
        try await engine.deleteCable(id: 9, refreshing: [88, 89])
        XCTAssertEqual(fetcher.sends.map(\.method), ["DELETE"])
        XCTAssertEqual(fetcher.sends.first?.path, "/api/dcim/cables/9/")
        let free = try ModelContext(container).fetch(FetchDescriptor<Interface>())
        XCTAssertTrue(free.allSatisfy { $0.cableId == nil })
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Cable>()).isEmpty)
    }

    func testDisconnectResolvesCableIdFromInterfaceRetrieve() async throws {
        let container = try makeContainer()
        try seedInterface(in: container, extraIDs: [89])
        let seed = ModelContext(container)
        let rows = try seed.fetch(FetchDescriptor<Interface>())
        rows.first { $0.id == 88 }?.connectedEndpointId = 89
        rows.first { $0.id == 88 }?.cableId = nil
        try seed.save()

        let fetcher = WriteFetcher()
        fetcher.getQueue["/api/dcim/interfaces/88/"] = [
            interfaceJSON(id: 88, enabled: true, description: "", cableID: 9, endpoint: 89),
            interfaceJSON(id: 88, enabled: true, description: "", cableID: nil),
        ]
        fetcher.getBodies["/api/dcim/interfaces/89/"] = interfaceJSON(
            id: 89, enabled: true, description: "", cableID: nil
        )
        fetcher.sendQueue = [
            NetBoxHTTPResponse(status: 204, body: Data(), etag: nil),
        ]
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.disconnectInterface(id: 88, knownCableId: nil, refreshing: [88, 89])
        XCTAssertEqual(fetcher.sends.map(\.method), ["DELETE"])
        XCTAssertEqual(fetcher.sends.first?.path, "/api/dcim/cables/9/")
        XCTAssertTrue(
            try ModelContext(container).fetch(FetchDescriptor<Interface>()).allSatisfy { $0.cableId == nil }
        )
    }

    func testDisconnectWithoutCableDoesNotDelete() async throws {
        let container = try makeContainer()
        try seedInterface(in: container)
        let fetcher = WriteFetcher()
        fetcher.getBodies["/api/dcim/interfaces/88/"] = interfaceJSON(
            id: 88, enabled: true, description: "", cableID: nil
        )
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        do {
            try await engine.disconnectInterface(id: 88, knownCableId: nil, refreshing: [88])
            XCTFail("expected missing cable")
        } catch let error as NetBoxSyncError {
            XCTAssertEqual(
                error,
                .httpStatus(code: 404, body: "NetBox has no cable on interface 88")
            )
        }
        XCTAssertTrue(fetcher.sends.isEmpty)
    }

    func testDeleteCableFailsClosedWhenEndsDoNotResolve() async throws {
        let container = try makeContainer()
        let fetcher = WriteFetcher()
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        do {
            try await engine.deleteCable(id: 1, refreshing: [999])
            XCTFail("unresolved cable ends must fail closed")
        } catch let error as BillingError {
            XCTAssertEqual(error, .linkRequiresBothSeats)
        }
        XCTAssertTrue(fetcher.sends.isEmpty)
    }

    func testDeviceAndSiteWritesStayGated() async throws {
        let container = try makeContainer()
        let fetcher = WriteFetcher()
        let engine = NetBoxSyncEngine(
            modelContainer: container,
            fetcher: fetcher,
            writePolicy: NetBoxWritePolicy(deviceAndSiteWritesEnabled: false, sendIfMatch: false)
        )
        do {
            try await engine.createSite(
                NetBoxWriteBody.SiteCreate(name: "Lab", slug: "lab", status: "active")
            )
            XCTFail("site create must stay gated")
        } catch let error as NetBoxSyncError {
            XCTAssertEqual(
                error,
                .writesDisabled("Device and site writes are implemented but gated off")
            )
        }
        do {
            try await engine.patchDevice(
                id: 1,
                body: NetBoxWriteBody.DevicePatch(name: "x")
            )
            XCTFail("device patch must stay gated")
        } catch let error as NetBoxSyncError {
            XCTAssertEqual(
                error,
                .writesDisabled("Device and site writes are implemented but gated off")
            )
        }
        XCTAssertTrue(fetcher.sends.isEmpty)
    }

    func testCreateSiteAndDevicePostWhenEnabled() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 4))
        seed.insert(DeviceRole(id: 6))
        seed.insert(DeviceType(id: 8))
        try seed.save()

        let fetcher = WriteFetcher()
        fetcher.sendQueue = [
            NetBoxHTTPResponse(
                status: 201,
                body: Data(#"{"id":12,"name":"Lab","slug":"lab","status":{"value":"active"}}"#.utf8),
                etag: nil
            ),
            NetBoxHTTPResponse(
                status: 201,
                body: Data(#"{"id":30,"name":"core-1","site":{"id":4},"role":{"id":6},"device_type":{"id":8}}"#.utf8),
                etag: nil
            ),
        ]
        fetcher.getBodies["/api/dcim/sites/12/"] = Data(
            #"{"id":12,"name":"Lab","slug":"lab","status":{"value":"active"}}"#.utf8
        )
        fetcher.getBodies["/api/dcim/devices/30/"] = Data(
            #"{"id":30,"name":"core-1","site":{"id":4},"role":{"id":6},"device_type":{"id":8}}"#.utf8
        )
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.createSite(
            NetBoxWriteBody.SiteCreate(name: "Lab", slug: "lab", status: "active")
        )
        try await engine.createDevice(
            NetBoxWriteBody.DeviceCreate(
                name: "core-1", deviceType: 8, role: 6, site: 4, status: "active"
            )
        )
        XCTAssertEqual(fetcher.sends.map(\.method), ["POST", "POST"])
        XCTAssertEqual(fetcher.sends.map(\.path), ["/api/dcim/sites/", "/api/dcim/devices/"])
        XCTAssertTrue(
            try ModelContext(container).fetch(FetchDescriptor<Device>()).contains { $0.id == 30 }
        )
    }

    func testCreateDeviceLoadsInterfacesForThatDevice() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 4))
        seed.insert(DeviceRole(id: 6))
        seed.insert(DeviceType(id: 8))
        try seed.save()

        let fetcher = WriteFetcher()
        fetcher.sendQueue = [
            NetBoxHTTPResponse(
                status: 201,
                body: Data(#"{"id":30,"name":"ap-1","site":{"id":4},"role":{"id":6},"device_type":{"id":8}}"#.utf8),
                etag: nil
            ),
        ]
        fetcher.getBodies["/api/dcim/devices/30/"] = Data(
            #"{"id":30,"name":"ap-1","site":{"id":4},"role":{"id":6},"device_type":{"id":8}}"#.utf8
        )
        fetcher.getBodies["/api/dcim/interfaces/"] = Data("""
        { "count": 1, "next": null, "results": [
          { "id": 501, "name": "wifi0",
            "device": { "id": 30, "name": "ap-1" },
            "enabled": true }
        ] }
        """.utf8)
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.createDevice(
            NetBoxWriteBody.DeviceCreate(
                name: "ap-1", deviceType: 8, role: 6, site: 4, status: "active"
            )
        )
        let ifaces = try ModelContext(container).fetch(FetchDescriptor<Interface>())
        XCTAssertEqual(ifaces.map(\.name), ["wifi0"])
        XCTAssertEqual(ifaces.first?.deviceId, 30)
    }

    func testRequireSeatedSkipsRackHardware() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let fillerRole = DeviceRole(id: 6)
        context.insert(fillerRole)
        let blank = Device(id: 9000)
        blank.deviceRole = fillerRole
        context.insert(blank)
        let switchRole = DeviceRole(id: 1)
        context.insert(switchRole)
        let granted = Date(timeIntervalSince1970: 1_600_000_000)
        for id in 1...50 {
            let device = Device(id: Int64(id))
            device.deviceRole = switchRole
            device.seatGrantedAt = granted
            context.insert(device)
        }
        let unseated = Device(id: 9001)
        unseated.deviceRole = switchRole
        context.insert(unseated)
        try context.save()

        let defaults = UserDefaults(suiteName: "pulse.tests.fillerSeat")!
        defaults.removePersistentDomain(forName: "pulse.tests.fillerSeat")
        RolePresentationStorage.save(.omegaDefault(), to: defaults)

        try LicenseSeatEvaluator.requireSeated(
            deviceID: 9000, in: context, defaults: defaults, tier: .free
        )
        XCTAssertThrowsError(
            try LicenseSeatEvaluator.requireSeated(
                deviceID: 9001, in: context, defaults: defaults, tier: .free
            )
        ) { error in
            XCTAssertEqual(error as? BillingError, .deviceNotSeated)
        }
    }

    func testRequireLinkAllowsOneHardwareEnd() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let fillerRole = DeviceRole(id: 6)
        context.insert(fillerRole)
        let panel = Device(id: 9000)
        panel.deviceRole = fillerRole
        context.insert(panel)
        let switchRole = DeviceRole(id: 1)
        context.insert(switchRole)
        let granted = Date(timeIntervalSince1970: 1_600_000_000)
        for id in 1...50 {
            let device = Device(id: Int64(id))
            device.deviceRole = switchRole
            device.seatGrantedAt = granted
            context.insert(device)
        }
        let unseated = Device(id: 9001)
        unseated.deviceRole = switchRole
        context.insert(unseated)
        try context.save()

        let defaults = UserDefaults(suiteName: "pulse.tests.fillerLink")!
        defaults.removePersistentDomain(forName: "pulse.tests.fillerLink")
        RolePresentationStorage.save(.omegaDefault(), to: defaults)

        try LicenseSeatEvaluator.requireLink(
            a: 9000, b: 1, in: context, defaults: defaults, tier: .free
        )
        XCTAssertThrowsError(
            try LicenseSeatEvaluator.requireLink(
                a: 9000, b: 9001, in: context, defaults: defaults, tier: .free
            )
        ) { error in
            XCTAssertEqual(error as? BillingError, .deviceNotSeated)
        }
    }

    func testCreateBillableDeviceAtCapIsRefused() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 4))
        let role = DeviceRole(id: 1)
        seed.insert(role)
        seed.insert(DeviceType(id: 8))
        let granted = Date(timeIntervalSince1970: 1_600_000_000)
        for id in 1...50 {
            let device = Device(id: Int64(id))
            device.created = granted
            device.seatGrantedAt = granted
            device.deviceRole = role
            seed.insert(device)
        }
        try seed.save()

        let fetcher = WriteFetcher()
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        do {
            try await engine.createDevice(
                NetBoxWriteBody.DeviceCreate(
                    name: "over-cap", deviceType: 8, role: 1, site: 4, status: "active"
                )
            )
            XCTFail("billable create at cap must refuse")
        } catch let error as BillingError {
            XCTAssertEqual(error, .tierCapReached(.free))
        }
        XCTAssertTrue(fetcher.sends.isEmpty)
    }

    func testEngineUsesInjectedEntitlementStoreTier() async throws {
        let entitlements = EntitlementStore(previewTier: .growth)
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 4))
        let role = DeviceRole(id: 1)
        seed.insert(role)
        seed.insert(DeviceType(id: 8))
        let granted = Date(timeIntervalSince1970: 1_600_000_000)
        for id in 1...50 {
            let device = Device(id: Int64(id))
            device.created = granted
            device.seatGrantedAt = granted
            device.deviceRole = role
            seed.insert(device)
        }
        try seed.save()

        let created = Data(
            #"{"id":51,"name":"plus-1","site":{"id":4},"role":{"id":1},"device_type":{"id":8}}"#.utf8
        )
        let fetcher = WriteFetcher()
        fetcher.sendQueue = [
            NetBoxHTTPResponse(status: 201, body: created, etag: nil),
        ]
        fetcher.getBodies["/api/dcim/devices/51/"] = created
        let engine = NetBoxSyncEngine(
            modelContainer: container,
            fetcher: fetcher,
            subscriptionTier: { entitlements.tier }
        )
        try await engine.createDevice(
            NetBoxWriteBody.DeviceCreate(
                name: "plus-1", deviceType: 8, role: 1, site: 4, status: "active"
            )
        )
        XCTAssertEqual(fetcher.sends.map(\.path), ["/api/dcim/devices/"])
        XCTAssertTrue(
            try ModelContext(container).fetch(FetchDescriptor<Device>()).contains { $0.id == 51 }
        )
    }

    func testUserDefaultsTierDoesNotLiftEngineCap() async throws {
        // Attack under test: the engine must ignore this key. Cap
        // source is the injected closure (default Free), not storage.
        UserDefaults.standard.set(SubscriptionTier.unlimited.rawValue, forKey: EntitlementStorage.key)
        defer { UserDefaults.standard.removeObject(forKey: EntitlementStorage.key) }

        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 4))
        let role = DeviceRole(id: 1)
        seed.insert(role)
        seed.insert(DeviceType(id: 8))
        let granted = Date(timeIntervalSince1970: 1_600_000_000)
        for id in 1...50 {
            let device = Device(id: Int64(id))
            device.created = granted
            device.seatGrantedAt = granted
            device.deviceRole = role
            seed.insert(device)
        }
        try seed.save()

        let fetcher = WriteFetcher()
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        do {
            try await engine.createDevice(
                NetBoxWriteBody.DeviceCreate(
                    name: "over-cap", deviceType: 8, role: 1, site: 4, status: "active"
                )
            )
            XCTFail("spoofed defaults must not lift the engine cap")
        } catch let error as BillingError {
            XCTAssertEqual(error, .tierCapReached(.free))
        }
        XCTAssertTrue(fetcher.sends.isEmpty)
    }

    func testCreateRackPostsWhenEnabled() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(Site(id: 4))
        try seed.save()

        let rackJSON = Data("""
        {
          "id": 44, "url": "u", "display": "R1", "name": "R1",
          "site": { "id": 4, "url": "u", "display": "Lab", "name": "Lab", "slug": "lab" },
          "status": { "value": "active", "label": "Active" },
          "u_height": 42, "starting_unit": 1
        }
        """.utf8)
        let fetcher = WriteFetcher()
        fetcher.sendQueue = [
            NetBoxHTTPResponse(status: 201, body: rackJSON, etag: nil),
        ]
        fetcher.getBodies["/api/dcim/racks/44/"] = rackJSON
        let engine = NetBoxSyncEngine(modelContainer: container, fetcher: fetcher)
        try await engine.createRack(
            NetBoxWriteBody.RackCreate(name: "R1", site: 4, status: "active", uHeight: 42)
        )
        XCTAssertEqual(fetcher.sends.map(\.method), ["POST"])
        XCTAssertEqual(fetcher.sends.map(\.path), ["/api/dcim/racks/"])
        XCTAssertTrue(
            try ModelContext(container).fetch(FetchDescriptor<Rack>()).contains { $0.id == 44 }
        )
    }

    func testSitePinHygieneAndRegionSuggestion() throws {
        XCTAssertEqual(
            NetBoxGeo.physicalAddress("328 Paremata Haywards Hill Rd, Judgeford, Porirua 5381, New Zealand"),
            "328 Paremata Haywards Hill Rd, Judgeford, Porirua 5381, New Zealand"
        )
        XCTAssertEqual(NetBoxGeo.physicalAddress(String(repeating: "a", count: 250)).count, 200)
        XCTAssertEqual(NetBoxGeo.latitude(-41.116328917), -41.11633, accuracy: 0.000001)
        XCTAssertEqual(NetBoxGeo.longitude(174.870069123), 174.87007, accuracy: 0.000001)
        let body = try NetBoxWriteJSON.encode(
            NetBoxWriteBody.SiteCreate(
                name: "Lab",
                slug: "lab",
                status: "active",
                latitude: NetBoxGeo.latitude(-41.116328917),
                longitude: NetBoxGeo.longitude(174.870069123)
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["latitude"] as? Double, NetBoxGeo.latitude(-41.116328917))
        XCTAssertEqual(
            NetBoxGeo.suggestedRegionID(
                regions: [(1, "Wellington"), (2, "Porirua"), (3, "Porirua City")],
                address: "328 Paremata Haywards Hill Rd, Judgeford, Porirua 5381"
            ),
            2
        )
    }

    func testConflictDescriptionAndLiveBodyHelper() {
        XCTAssertEqual(
            NetBoxSyncError.httpStatus(code: 412, body: "x").localizedDescription,
            "NetBox conflict (412): x"
        )
        XCTAssertEqual(
            NetBoxLiveFetcher.bodyString(Data(#"{"detail":"no"}"#.utf8)),
            #"{"detail":"no"}"#
        )
        XCTAssertEqual(NetBoxLiveFetcher.bodyString(Data()), "")
        let offline = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        XCTAssertEqual(
            NetBoxLiveFetcher.transportMessage(offline),
            "NetBox is unreachable. The change was not saved."
        )
        let html503 = """
        <!DOCTYPE html>
        <html><body><iframe src="/fortiadc_error_page/index.html"></iframe></body></html>
        """
        XCTAssertEqual(
            NetBoxSyncError.operatorMessage(code: 503, body: html503),
            "NetBox is temporarily unavailable."
        )
        XCTAssertEqual(
            NetBoxSyncError.httpStatus(code: 503, body: html503).localizedDescription,
            "NetBox 503: NetBox is temporarily unavailable."
        )
        XCTAssertEqual(
            NetBoxSyncError.operatorMessage(
                code: 403,
                body: "<html><body>Forbidden</body></html>"
            ),
            "NetBox refused this request. Check the API token and permissions."
        )
        XCTAssertEqual(
            NetBoxSyncError.operatorMessage(
                code: 403,
                body: #"{"detail":"You do not have permission to perform this action."}"#
            ),
            "You do not have permission to perform this action."
        )
        XCTAssertEqual(
            NetBoxSyncError.operatorMessage(
                code: 400,
                body: #"{"enabled":["This field is required."]}"#
            ),
            #"{"enabled":["This field is required."]}"#
        )
    }

    private func assertJSON(
        _ data: Data,
        _ expected: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let got = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
            let expectedData = try JSONSerialization.data(withJSONObject: expected)
            let exp = try XCTUnwrap(JSONSerialization.jsonObject(with: expectedData) as? NSDictionary)
            XCTAssertEqual(got, exp, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    private func interfaceJSON(
        id: Int64,
        enabled: Bool,
        description: String,
        cableID: Int64?,
        endpoint: Int64? = nil
    ) -> Data {
        var cable = "null"
        if let cableID {
            cable = #"{"id":\#(cableID)}"#
        }
        var endpoints = "[]"
        if let endpoint {
            endpoints = #"[{"id":\#(endpoint),"name":"eth\#(endpoint)","device":{"id":10}}]"#
        }
        return Data("""
        {
          "id": \(id), "name": "eth\(id)",
          "device": {"id": 10, "name": "core"},
          "enabled": \(enabled),
          "description": "\(description)",
          "cable": \(cable),
          "connected_endpoints": \(endpoints)
        }
        """.utf8)
    }

    private func seedInterface(in container: ModelContainer, extraIDs: [Int64] = []) throws {
        let context = ModelContext(container)
        let site = Site(id: 1)
        context.insert(site)
        let device = Device(id: 10)
        device.site = site
        context.insert(device)
        for id in [88] + extraIDs {
            let row = Interface(id: id)
            row.name = "eth\(id)"
            row.enabled = true
            row.deviceId = 10
            row.siteId = 1
            row.device = device
            context.insert(row)
        }
        try context.save()
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

private final class WriteFetcher: NetBoxFetching, @unchecked Sendable {
    var sends: [NetBoxHTTPRequest] = []
    var sendQueue: [NetBoxHTTPResponse] = []
    var sendError: Error?
    var getBodies: [String: Data] = [:]
    var getQueue: [String: [Data]] = [:]

    func get(path: String, query: [URLQueryItem]) async throws -> Data {
        if var pages = getQueue[path], !pages.isEmpty {
            let next = pages.removeFirst()
            getQueue[path] = pages
            return next
        }
        if let body = getBodies[path] {
            return body
        }
        throw NetBoxSyncError.httpStatus(code: 404, body: path)
    }

    func send(_ request: NetBoxHTTPRequest) async throws -> NetBoxHTTPResponse {
        sends.append(request)
        if let sendError {
            throw sendError
        }
        if !sendQueue.isEmpty {
            return sendQueue.removeFirst()
        }
        throw NetBoxSyncError.httpStatus(code: 500, body: "no queued write response")
    }
}
