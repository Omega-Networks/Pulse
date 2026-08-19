//
//  RolePresentationTests.swift
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

final class RolePresentationTests: XCTestCase {
    func testOmegaDefaultHidesFillerRolesFromGraphAndList() {
        let presentation = RolePresentation.omegaDefault()
        let panel = presentation.policy(for: 6)
        XCTAssertTrue(panel.hideFromGraph)
        XCTAssertTrue(panel.hideFromDeviceList)
        XCTAssertTrue(panel.skipMonitoring)
        XCTAssertTrue(panel.showInRack)
        XCTAssertTrue(panel.treatAsFiller)
        XCTAssertFalse(panel.countsTowardLicense)
        XCTAssertFalse(presentation.countsTowardLicense(roleID: 6))

        let switchRole = presentation.policy(for: 1)
        XCTAssertFalse(switchRole.hideFromGraph)
        XCTAssertFalse(switchRole.hideFromDeviceList)
        XCTAssertFalse(switchRole.treatAsFiller)
        XCTAssertTrue(switchRole.showInRack)
        XCTAssertTrue(switchRole.countsTowardLicense)
    }

    func testRoundTripPersistsOverride() {
        let defaults = UserDefaults(suiteName: "pulse.tests.rolePresentation")!
        defaults.removePersistentDomain(forName: "pulse.tests.rolePresentation")
        var presentation = RolePresentation.omegaDefault()
        presentation.policies[6] = RolePolicy(
            hideFromGraph: false,
            hideFromDeviceList: true,
            skipMonitoring: true,
            showInRack: true,
            treatAsFiller: true
        )
        RolePresentationStorage.save(presentation, to: defaults)
        let loaded = RolePresentationStorage.load(from: defaults)
        XCTAssertFalse(loaded.policy(for: 6).hideFromGraph)
        XCTAssertTrue(loaded.policy(for: 6).hideFromDeviceList)
        XCTAssertTrue(loaded.policy(for: 7).hideFromGraph)
    }

    func testCorruptDefaultsFallBackToOmegaDefault() {
        let defaults = UserDefaults(suiteName: "pulse.tests.rolePresentation.corrupt")!
        defaults.removePersistentDomain(forName: "pulse.tests.rolePresentation.corrupt")
        defaults.set(Data("not-json".utf8), forKey: RolePresentationStorage.key)
        let loaded = RolePresentationStorage.load(from: defaults)
        XCTAssertTrue(loaded.policy(for: 18).treatAsFiller)
        XCTAssertFalse(loaded.policy(for: 18).countsTowardLicense)
    }

    func testLicenseIsDerivedFromVisibilityNotAStoredFlag() throws {
        let hardware = Data("""
        {"hideFromGraph":true,"hideFromDeviceList":true,"skipMonitoring":true,"showInRack":true,"treatAsFiller":true,"countsTowardLicense":true}
        """.utf8)
        let hardwarePolicy = try JSONDecoder().decode(RolePolicy.self, from: hardware)
        XCTAssertFalse(hardwarePolicy.countsTowardLicense)

        let operatorJSON = Data("""
        {"hideFromGraph":false,"hideFromDeviceList":false,"skipMonitoring":false,"showInRack":true,"treatAsFiller":false,"countsTowardLicense":false}
        """.utf8)
        let operatorPolicy = try JSONDecoder().decode(RolePolicy.self, from: operatorJSON)
        XCTAssertTrue(operatorPolicy.countsTowardLicense)

        var rackOnly = RolePolicy.operatorDevice
        rackOnly.hideFromGraph = true
        rackOnly.hideFromDeviceList = true
        rackOnly.showInRack = true
        rackOnly.treatAsFiller = false
        XCTAssertTrue(rackOnly.countsTowardLicense)

        var hidden = RolePolicy.operatorDevice
        hidden.hideFromGraph = true
        hidden.hideFromDeviceList = true
        hidden.showInRack = false
        XCTAssertFalse(hidden.countsTowardLicense)
    }
}
