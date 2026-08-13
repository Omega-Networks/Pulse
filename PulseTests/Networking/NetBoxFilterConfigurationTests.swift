//
//  NetBoxFilterConfigurationTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
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
