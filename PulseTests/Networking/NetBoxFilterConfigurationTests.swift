//
//  NetBoxFilterConfigurationTests.swift
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

import XCTest
@testable import Pulse

final class NetBoxFilterConfigurationTests: XCTestCase {
    func testDefaultMatchesLegacyHardcodedIDs() {
        let filter = NetBoxFilterConfiguration.default
        XCTAssertEqual(filter.excludedManufacturerQuery, [5])
        XCTAssertEqual(filter.excludedRoleQueryAsInts, [29, 30])
        XCTAssertEqual(filter.excludedRoleQueryAsStrings, ["29", "30"])
        XCTAssertEqual(filter.staticDeviceRoleQuery, [6, 7, 18, 27])
    }

    func testIncludesDeviceRespectsBothAxes() {
        let filter = NetBoxFilterConfiguration.default
        XCTAssertTrue(filter.includesDevice(manufacturerID: 1, roleID: 1))
        XCTAssertFalse(filter.includesDevice(manufacturerID: 5, roleID: 1))
        XCTAssertFalse(filter.includesDevice(manufacturerID: 1, roleID: 29))
        XCTAssertTrue(filter.includesDevice(manufacturerID: nil, roleID: nil))
    }

    func testIncludesDeviceTypeAndRole() {
        let filter = NetBoxFilterConfiguration.default
        XCTAssertFalse(filter.includesDeviceType(manufacturerID: 5))
        XCTAssertTrue(filter.includesDeviceType(manufacturerID: 1))
        XCTAssertFalse(filter.includesDeviceRole(id: 30))
        XCTAssertTrue(filter.includesDeviceRole(id: 1))
        XCTAssertTrue(filter.isStaticDeviceRole(id: 6))
        XCTAssertFalse(filter.isStaticDeviceRole(id: 1))
    }
}
