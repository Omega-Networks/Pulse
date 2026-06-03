//
//  DeviceWebTests.swift
//  PulseTests
//
//  Copyright © 2025-present Omega Networks Limited.
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
import XCTest
@testable import Pulse

/// Headless coverage for the Slice W2b pure logic: origin containment and the
/// toolbar load-status mapping. The on-device behaviour (the page rendering, the
/// trust prompt firing, navigation actually routing to the system browser) is a
/// manual gate, not headless.
final class DeviceWebTests: XCTestCase {

    // MARK: - WebOrigin containment

    func testOriginAllowsSameSchemeHostPort() {
        let origin = WebOrigin(scheme: "https", host: "10.0.0.1", port: 8006)
        XCTAssertTrue(origin.allows(URL(string: "https://10.0.0.1:8006/")!))
        XCTAssertTrue(origin.allows(URL(string: "https://10.0.0.1:8006/nodes/pve/summary?x=1")!))
    }

    func testOriginBlocksForeignOrigin() {
        let origin = WebOrigin(scheme: "https", host: "10.0.0.1", port: 8006)
        XCTAssertFalse(origin.allows(URL(string: "https://10.0.0.2:8006/")!), "different host")
        XCTAssertFalse(origin.allows(URL(string: "https://10.0.0.1:443/")!), "different port")
        XCTAssertFalse(origin.allows(URL(string: "http://10.0.0.1:8006/")!), "different scheme")
        XCTAssertFalse(origin.allows(URL(string: "https://evil.example.com/")!), "different host entirely")
    }

    func testOriginDefaultsPortFromScheme() {
        let origin = WebOrigin(scheme: "https", host: "host", port: 443)
        // A URL omitting the port resolves to 443 for https, so it is same-origin.
        XCTAssertTrue(origin.allows(URL(string: "https://host/")!))
        XCTAssertEqual(WebOrigin(url: URL(string: "https://host/")!), origin)
    }

    func testOriginInitNilWithoutHost() {
        XCTAssertNil(WebOrigin(url: URL(string: "about:blank")!))
    }

    // MARK: - WebLoadStatus

    func testLoadStatusResolution() {
        XCTAssertEqual(WebLoadStatus.resolve(isLoading: true, failure: nil), .loading)
        XCTAssertEqual(WebLoadStatus.resolve(isLoading: false, failure: nil), .loaded)
        // A recorded failure wins regardless of the loading flag.
        XCTAssertEqual(WebLoadStatus.resolve(isLoading: true, failure: "boom"), .failed("boom"))
        XCTAssertEqual(WebLoadStatus.resolve(isLoading: false, failure: "boom"), .failed("boom"))
    }

    func testLoadStatusLabels() {
        XCTAssertEqual(WebLoadStatus.loading.label, "Loading")
        XCTAssertEqual(WebLoadStatus.loaded.label, "Loaded")
        XCTAssertEqual(WebLoadStatus.failed("x").label, "Failed")
    }
}
