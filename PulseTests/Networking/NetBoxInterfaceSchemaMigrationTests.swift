//
//  NetBoxInterfaceSchemaMigrationTests.swift
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

final class NetBoxInterfaceSchemaMigrationTests: XCTestCase {
    /// Types shipped by P1. Adding `Interface.self` is the P2 schema change.
    private static let p1Types: [any PersistentModel.Type] = [
        TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
        Rack.self, SiteGroup.self, Site.self, Device.self, Service.self, WebHostTrust.self,
        Event.self, SyncProvider.self, PowerSenseDevice.self, PowerSenseEvent.self,
        SSHCredential.self, KnownHost.self
    ]

    func testP1StoreOpensAfterAddingInterfaceModel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-p2-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("pulse.store")

        do {
            let schema = Schema(Self.p1Types)
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            context.insert(Device(id: 42))
            try context.save()
        }

        let schema = Schema(Self.p1Types + [Interface.self])
        let config = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let devices = try context.fetch(FetchDescriptor<Device>())
        XCTAssertEqual(devices.map(\.id), [42])
        let interfaces = try context.fetch(FetchDescriptor<Interface>())
        XCTAssertTrue(interfaces.isEmpty)
        XCTAssertEqual(devices.first?.interfaces?.count ?? 0, 0)
    }
}
