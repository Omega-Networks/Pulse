//
//  SSHConnectFormTests.swift
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

/// Pins the two structural-enforcement helpers behind the pre-connect
/// form. Both are the kind of regression that lands silently — a
/// "small simplification" of either helper would re-open the
/// connect-with-garbage-defaults failure mode the form exists to
/// close. Each test would be added back if deleted.
///
/// SwiftUI rendering, `@Query` resolution, and `.task` lifecycle are
/// deliberately not exercised here — those are the framework's job.
final class SSHConnectFormTests: XCTestCase {

    // MARK: - canConnect

    /// Empty username → disabled. The button-disable logic is the
    /// structural enforcement of "operator must think" before
    /// connecting: an empty field silently falling back to
    /// `NSUserName()` is precisely the failure mode this slice
    /// closes.
    func testCanConnectRejectsEmptyUsername() {
        let credentialID = UUID()
        XCTAssertFalse(SSHConnectForm.canConnect(
            username: "",
            credentialID: credentialID,
            primaryIP: "192.0.2.1"
        ))
    }

    /// Whitespace-only username → disabled. A space-bar press should
    /// not bypass the gate; `trimmingCharacters` is the canonical
    /// check.
    func testCanConnectRejectsWhitespaceOnlyUsername() {
        let credentialID = UUID()
        XCTAssertFalse(SSHConnectForm.canConnect(
            username: "   \t\n",
            credentialID: credentialID,
            primaryIP: "192.0.2.1"
        ))
    }

    /// Nil credential → disabled. Per the form's "default to nil
    /// with explicit pick-required placeholder" design, no
    /// credential means no connect — no first-credential-in-store
    /// fallback.
    func testCanConnectRejectsNilCredentialID() {
        XCTAssertFalse(SSHConnectForm.canConnect(
            username: "admin",
            credentialID: nil,
            primaryIP: "192.0.2.1"
        ))
    }

    /// Nil primary IP → disabled. Device row's context menu already
    /// gates on `primaryIP` presence, but defence in depth keeps the
    /// form correct under stale data (NetBox sync clears the IP
    /// while the window is open).
    func testCanConnectRejectsNilPrimaryIP() {
        let credentialID = UUID()
        XCTAssertFalse(SSHConnectForm.canConnect(
            username: "admin",
            credentialID: credentialID,
            primaryIP: nil
        ))
    }

    /// Empty-string primary IP → disabled. Same defence-in-depth as
    /// the nil case; SwiftData attribute could be present-but-blank
    /// on a row mid-edit.
    func testCanConnectRejectsEmptyPrimaryIP() {
        let credentialID = UUID()
        XCTAssertFalse(SSHConnectForm.canConnect(
            username: "admin",
            credentialID: credentialID,
            primaryIP: ""
        ))
    }

    /// All three fields valid → enabled. The happy path; the only
    /// shape that opens the Connect gate.
    func testCanConnectAcceptsValidInputs() {
        XCTAssertTrue(SSHConnectForm.canConnect(
            username: "admin",
            credentialID: UUID(),
            primaryIP: "192.0.2.1"
        ))
    }

    // MARK: - biometricHint

    /// Recording credential → operator sees the two-prompt warning
    /// before clicking Connect. The exact wording matters because
    /// operators read it for expectation-setting; a silent string
    /// change would land in a release without the "why is it asking
    /// twice?" moment the form was designed to close.
    func testBiometricHintForRecordingCredentialMentionsTwoPrompts() {
        let hint = SSHConnectForm.biometricHint(recordSessions: true)
        XCTAssertTrue(hint.lowercased().contains("two"),
            "Recording-credential hint should mention two prompts; got: \(hint)")
        XCTAssertTrue(hint.lowercased().contains("recording"),
            "Recording-credential hint should mention recording; got: \(hint)")
    }

    /// Non-recording credential → operator sees the one-prompt note.
    /// Distinct wording so the form composes cleanly with the
    /// existing `docs/credentials.md` operator-facing guide.
    func testBiometricHintForNonRecordingCredentialMentionsOnePrompt() {
        let hint = SSHConnectForm.biometricHint(recordSessions: false)
        XCTAssertTrue(hint.lowercased().contains("one"),
            "Non-recording hint should mention one prompt; got: \(hint)")
        XCTAssertFalse(hint.lowercased().contains("two"),
            "Non-recording hint must not mention two prompts; got: \(hint)")
    }

    // MARK: - autoFireAttempt (device mode)

    /// Both defaults present + credential exists → auto-fire is
    /// eligible. The "double-click and go" muscle-memory path.
    func testAutoFireDeviceModeWithBothDefaultsAndKnownCredential() {
        let credentialID = UUID()
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .device(42),
            deviceDefaultUsername: "admin",
            deviceDefaultCredentialID: credentialID,
            knownCredentialIDs: [credentialID]
        )
        XCTAssertNotNil(attempt)
        XCTAssertEqual(attempt?.username, "admin")
        XCTAssertEqual(attempt?.credentialID, credentialID)
    }

    /// Both defaults present but the referenced credential has been
    /// deleted → form, not auto-fire. The defence-in-depth check
    /// against stale `defaultCredentialID` pointers; without it, a
    /// deleted-credential connect attempt would fail late inside the
    /// lifecycle rather than surfacing the form for explicit
    /// recovery.
    func testAutoFireDeviceModeWithStaleCredentialIDReturnsNil() {
        let staleID = UUID()
        let otherID = UUID()
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .device(42),
            deviceDefaultUsername: "admin",
            deviceDefaultCredentialID: staleID,
            knownCredentialIDs: [otherID]
        )
        XCTAssertNil(attempt)
    }

    /// Username default missing → form. Connecting with `NSUserName()`
    /// would be the wrong behaviour for network gear; the form is
    /// the operator's "type the right username" moment.
    func testAutoFireDeviceModeWithoutUsernameReturnsNil() {
        let credentialID = UUID()
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .device(42),
            deviceDefaultUsername: nil,
            deviceDefaultCredentialID: credentialID,
            knownCredentialIDs: [credentialID]
        )
        XCTAssertNil(attempt)
    }

    /// Username present but whitespace-only → form. A row with
    /// `defaultUsername = " "` is operator-input that does not count
    /// as "configured"; trimming catches it.
    func testAutoFireDeviceModeWithWhitespaceUsernameReturnsNil() {
        let credentialID = UUID()
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .device(42),
            deviceDefaultUsername: "   ",
            deviceDefaultCredentialID: credentialID,
            knownCredentialIDs: [credentialID]
        )
        XCTAssertNil(attempt)
    }

    /// Credential default missing → form. Operator gets the picker
    /// rather than a silent failure mid-lifecycle.
    func testAutoFireDeviceModeWithoutCredentialReturnsNil() {
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .device(42),
            deviceDefaultUsername: "admin",
            deviceDefaultCredentialID: nil,
            knownCredentialIDs: [UUID()]
        )
        XCTAssertNil(attempt)
    }

    /// Both defaults nil → form. The vast majority of devices in
    /// production today (since no UI exists yet to set the defaults).
    func testAutoFireDeviceModeWithNeitherDefaultReturnsNil() {
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .device(42),
            deviceDefaultUsername: nil,
            deviceDefaultCredentialID: nil,
            knownCredentialIDs: []
        )
        XCTAssertNil(attempt)
    }

    /// Username trims to non-empty → auto-fire uses the trimmed
    /// value. Operator-set "admin " (trailing space from a paste)
    /// should still auto-fire cleanly with the trimmed username.
    func testAutoFireDeviceModeTrimsUsernameBeforeAttempt() {
        let credentialID = UUID()
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .device(42),
            deviceDefaultUsername: "  admin\n",
            deviceDefaultCredentialID: credentialID,
            knownCredentialIDs: [credentialID]
        )
        XCTAssertEqual(attempt?.username, "admin")
    }

    // MARK: - autoFireAttempt (ad-hoc mode)

    /// Ad-hoc mode → always auto-fire with the connection enum's
    /// values. The upstream debug surface (`DebugSSHMenu`) already
    /// gathered username + credential, so the form is bypassed and
    /// the lifecycle runs immediately.
    func testAutoFireAdHocModeReturnsAttemptFromConnectionValues() {
        let credentialID = UUID()
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .adHoc(host: "127.0.0.1", port: 22, username: "root", credentialID: credentialID),
            deviceDefaultUsername: nil,
            deviceDefaultCredentialID: nil,
            knownCredentialIDs: []
        )
        XCTAssertNotNil(attempt)
        XCTAssertEqual(attempt?.username, "root")
        XCTAssertEqual(attempt?.credentialID, credentialID)
    }

    // MARK: - ConnectionAttempt identity

    /// Two attempts with identical username + credentialID but
    /// different nonces are NOT equal — the nonce is the
    /// re-fire mechanism for the `.task(id: connectionAttempt)`
    /// modifier. Without nonce-based identity, an operator clicking
    /// Connect a second time with the same fields after a failed
    /// attempt would not retrigger the lifecycle.
    func testConnectionAttemptIdentityIncludesNonce() {
        let credentialID = UUID()
        let a = SSHTerminalView.ConnectionAttempt(nonce: UUID(), username: "admin", credentialID: credentialID)
        let b = SSHTerminalView.ConnectionAttempt(nonce: UUID(), username: "admin", credentialID: credentialID)
        XCTAssertNotEqual(a, b, "Two attempts with the same payload but different nonces must compare unequal so .task(id:) re-fires.")
    }
}
