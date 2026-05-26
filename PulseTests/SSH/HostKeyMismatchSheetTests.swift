//
//  HostKeyMismatchSheetTests.swift
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
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import XCTest
@testable import Pulse

/// Pins the load-bearing security default on the host-key mismatch
/// sheet: when the modal appears, focus starts on Reject. A stray
/// Return key on this sheet must never accept a key rotation; the
/// constant the test asserts is the source of truth that the sheet's
/// `.onAppear` reads to set its `@FocusState`. SwiftUI's `@FocusState`
/// is private and cannot be inspected from a unit test without
/// rendering, so the contract is pinned via the constant.
///
/// Visual contract (button colours: accept amber, reject red, forget
/// neutral) is verified by eye in the lab procedure rather than by
/// unit test. A colour-wiring regression is operator-obvious; the
/// keyboard-focus default is silent.
final class HostKeyMismatchSheetTests: XCTestCase {

    func testDefaultFocusIsRejectAction() {
        XCTAssertEqual(HostKeyMismatchSheet.defaultFocus, .reject)
    }
}
