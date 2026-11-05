//
//  ProblemUpdateDraftTests.swift
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

final class ProblemUpdateDraftTests: XCTestCase {
    func testEachBitAlone() {
        XCTAssertEqual(draft { $0.closes = true }.action, 1)
        XCTAssertEqual(draft { $0.acknowledges = true }.action, 2)
        XCTAssertEqual(draft { $0.message = "looking" }.action, 4)
        XCTAssertEqual(draft { $0.severity = 4 }.action, 8)
        XCTAssertEqual(draft { $0.unacknowledges = true }.action, 16)
        XCTAssertEqual(draft { $0.suppression = .indefinitely }.action, 32)
        XCTAssertEqual(draft { $0.unsuppresses = true }.action, 64)
    }

    func testBlankMessageAddsNothing() {
        var blank = ProblemUpdateDraft(eventIds: ["1"])
        blank.message = "   "
        XCTAssertEqual(blank.action, 0)
        XCTAssertFalse(blank.isValid)
        XCTAssertNil(blank.requestBody["message"])
    }

    func testSuppressIndefinitelyIsZero() {
        let body = draft { $0.suppression = .indefinitely }.requestBody
        XCTAssertEqual(body["suppress_until"] as? Int, 0)
        XCTAssertFalse(body["suppress_until"] is String)
        XCTAssertEqual(draft { $0.suppression = .indefinitely }.suppressUntil, "0")
    }

    func testSuppressUntilIsThatDatesSeconds() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let update = draft { $0.suppression = .until(date) }
        XCTAssertEqual(update.suppressUntil, "1800000000")
        XCTAssertEqual(update.requestBody["suppress_until"] as? Int, 1_800_000_000)
    }

    func testPastUntilIsInvalid() {
        let update = draft { $0.suppression = .until(Date(timeIntervalSince1970: 1)) }
        XCTAssertFalse(update.isValid)
        XCTAssertEqual(update.invalidReason, "Suppress-until must be later than now")
    }

    func testSuppressWithUnsuppressIsInvalid() {
        let update = draft {
            $0.suppression = .indefinitely
            $0.unsuppresses = true
        }
        XCTAssertFalse(update.isValid)
        XCTAssertEqual(update.invalidReason, "Suppress and Unsuppress cannot both be set")
    }

    func testAcknowledgeWithUnacknowledgeIsInvalid() {
        let update = draft {
            $0.acknowledges = true
            $0.unacknowledges = true
        }
        XCTAssertFalse(update.isValid)
        XCTAssertEqual(update.invalidReason, "Acknowledge and Unacknowledge cannot both be set")
    }

    func testEmptyActionIsInvalid() {
        let update = ProblemUpdateDraft(eventIds: ["1"])
        XCTAssertFalse(update.isValid)
        XCTAssertEqual(update.invalidReason, "Choose at least one action")
    }

    func testCloseWithAcknowledgeAndMessageStaysValid() {
        let update = draft {
            $0.closes = true
            $0.acknowledges = true
            $0.message = "done"
        }
        XCTAssertTrue(update.isValid)
        XCTAssertNil(update.invalidReason)
        XCTAssertEqual(update.action, 7)
    }

    func testBodyOmitsNilKeysAndSendsActionAsANumber() {
        let body = draft { $0.acknowledges = true }.requestBody
        XCTAssertEqual(Set(body.keys), ["eventids", "action"])
        XCTAssertEqual(body["action"] as? Int, 2)
        XCTAssertNil(body["message"])
        XCTAssertNil(body["severity"])
        XCTAssertNil(body["suppress_until"])
    }

    private func draft(_ edit: (inout ProblemUpdateDraft) -> Void) -> ProblemUpdateDraft {
        var update = ProblemUpdateDraft(eventIds: ["739183001"])
        edit(&update)
        return update
    }
}
