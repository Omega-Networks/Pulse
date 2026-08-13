//
//  SiteTopologyEdgesTests.swift
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

final class SiteTopologyEdgesTests: XCTestCase {
    private func makeVO(
        id: Int64,
        deviceId: Int64,
        siteId: Int64,
        endpoint: Int64?
    ) -> InterfaceVO {
        var vo = InterfaceVO(id: id)
        vo.name = "eth\(id)"
        vo.deviceId = deviceId
        vo.siteId = siteId
        vo.connectedEndpointId = endpoint
        return vo
    }

    func testDeriveDedupesUndirectedPairAndDropsMissingEnd() {
        let a = makeVO(id: 1, deviceId: 10, siteId: 4, endpoint: 2)
        let b = makeVO(id: 2, deviceId: 11, siteId: 4, endpoint: 1)
        let dangling = makeVO(id: 3, deviceId: 10, siteId: 4, endpoint: 99)
        let isolated = makeVO(id: 4, deviceId: 12, siteId: 4, endpoint: nil)

        let edges = SiteTopologyEdges.derive(from: [a, b, dangling, isolated])
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(Set([edges[0].start.id, edges[0].end.id]), [1, 2])
    }

    func testFetchVOsIsScopedBySiteAndDevice() throws {
        let schema = Schema([
            TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self,
            Rack.self, SiteGroup.self, Site.self, Device.self, Interface.self, Service.self,
            WebHostTrust.self, Event.self, SyncProvider.self, PowerSenseDevice.self,
            PowerSenseEvent.self, SSHCredential.self, KnownHost.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let site = Site(id: 4)
        context.insert(site)
        let device = Device(id: 10)
        device.site = site
        context.insert(device)
        let other = Device(id: 11)
        context.insert(other)

        let a = Interface(id: 1)
        a.deviceId = 10
        a.siteId = 4
        a.device = device
        a.connectedEndpointId = 2
        context.insert(a)
        let b = Interface(id: 2)
        b.deviceId = 10
        b.siteId = 4
        b.device = device
        context.insert(b)
        let elsewhere = Interface(id: 3)
        elsewhere.deviceId = 11
        elsewhere.siteId = 9
        elsewhere.device = other
        context.insert(elsewhere)
        try context.save()

        let siteVOs = try SiteTopologyEdges.fetchVOs(siteId: 4, in: context)
        XCTAssertEqual(Set(siteVOs.map(\.id)), [1, 2])
        let deviceVOs = try SiteTopologyEdges.fetchVOs(deviceId: 10, in: context)
        XCTAssertEqual(Set(deviceVOs.map(\.id)), [1, 2])
    }
}
