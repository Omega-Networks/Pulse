//
//  CredentialAuditTests.swift
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
//  This program is free software: communities can deploy it for sovereignty, academia can
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import XCTest
@testable import Pulse

/// Coverage for `CredentialAudit`, the typed surface that every
/// `credential.*` event (create / import / delete and the recording
/// toggle) flows through. The DEBUG-only `TestObserver` lets us assert on
/// the signal stream structurally rather than scraping `os_log`.
///
/// Pins the public event shape so a future field-drop (e.g. removing
/// `tier`) is a compile error at the call site here, and guards the
/// five-case `credential.*` token contract that the ADR §7 SIEM rules
/// depend on.
final class CredentialAuditTests: XCTestCase {

    func testEachEventCaseRoundTripsThroughTheObserver() {
        let capture = CredentialAudit.TestObserver.shared.startCapturing()

        let seID = UUID()
        let portableID = UUID()
        let deletedID = UUID()
        let toggledID = UUID()

        CredentialAudit.created(credentialID: seID, tier: .secureEnclave)
        CredentialAudit.imported(credentialID: portableID, tier: .portable)
        CredentialAudit.deleted(credentialID: deletedID, tier: .secureEnclave)
        CredentialAudit.recordingEnabled(credentialID: toggledID)
        CredentialAudit.recordingDisabled(credentialID: toggledID)

        let events = capture.events
        XCTAssertEqual(events.count, 5)

        guard events.count == 5 else { return }

        XCTAssertEqual(events[0], .created(credentialID: seID, tier: .secureEnclave))
        XCTAssertEqual(events[1], .imported(credentialID: portableID, tier: .portable))
        XCTAssertEqual(events[2], .deleted(credentialID: deletedID, tier: .secureEnclave))
        XCTAssertEqual(events[3], .recordingEnabled(credentialID: toggledID))
        XCTAssertEqual(events[4], .recordingDisabled(credentialID: toggledID))
    }
}
