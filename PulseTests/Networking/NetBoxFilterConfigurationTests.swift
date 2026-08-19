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
    func testDefaultSyncScopeHasNoInstanceExcludes() {
        XCTAssertEqual(NetBoxFilterConfiguration.default, NetBoxFilterConfiguration())
    }

    func testFillerRolesArePresentationDefaultsNotSyncExcludes() {
        XCTAssertEqual(RolePresentation.defaultFillerRoleIDs, [6, 7, 18, 27])
        let presentation = RolePresentation.omegaDefault()
        for id in RolePresentation.defaultFillerRoleIDs {
            XCTAssertTrue(presentation.policy(for: id).treatAsFiller)
            XCTAssertFalse(presentation.countsTowardLicense(roleID: id))
        }
    }
}
