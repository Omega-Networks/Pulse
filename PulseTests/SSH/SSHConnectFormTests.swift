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
        let a = SSHTerminalView.ConnectionAttempt(nonce: UUID(), username: "admin", credentialID: credentialID, saveAsDefault: false)
        let b = SSHTerminalView.ConnectionAttempt(nonce: UUID(), username: "admin", credentialID: credentialID, saveAsDefault: false)
        XCTAssertNotEqual(a, b, "Two attempts with the same payload but different nonces must compare unequal so .task(id:) re-fires.")
    }

    /// Two attempts with identical username + credentialID + nonce but
    /// different `saveAsDefault` flags are NOT equal. The lifecycle is
    /// driven by `.task(id: connectionAttempt)`; if `saveAsDefault`
    /// didn't participate in identity, an operator who connected once
    /// without ticking the box, then opened the form again to retry
    /// with the box ticked, would see no re-fire (the other fields
    /// already match). Including `saveAsDefault` in `Hashable` keeps
    /// the checkbox state observable to the lifecycle.
    func testConnectionAttemptIdentityIncludesSaveAsDefault() {
        let nonce = UUID()
        let credentialID = UUID()
        let optedOut = SSHTerminalView.ConnectionAttempt(nonce: nonce, username: "admin", credentialID: credentialID, saveAsDefault: false)
        let optedIn = SSHTerminalView.ConnectionAttempt(nonce: nonce, username: "admin", credentialID: credentialID, saveAsDefault: true)
        XCTAssertNotEqual(optedOut, optedIn, "Toggling saveAsDefault between attempts must invalidate identity so .task(id:) re-fires.")
    }

    // MARK: - autoFireAttempt persistence opt-out contract

    /// Auto-fired device-mode attempts must carry `saveAsDefault:
    /// false`. The no-silent-persistence contract: defaults
    /// persistence is exclusively an explicit operator gesture via
    /// the form checkbox, never a side-effect of an auto-fire path.
    /// A regression here would silently re-persist defaults on every
    /// successful auto-fire — exactly the "shared/jumphost credential
    /// stomps another operator's defaults" failure mode the explicit
    /// opt-in posture exists to prevent.
    func testAutoFireDeviceModeNeverOptsIntoSaveAsDefault() {
        let credentialID = UUID()
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .device(42),
            deviceDefaultUsername: "admin",
            deviceDefaultCredentialID: credentialID,
            knownCredentialIDs: [credentialID]
        )
        XCTAssertNotNil(attempt)
        XCTAssertFalse(attempt?.saveAsDefault ?? true, "Auto-fired device-mode attempt must opt out of persistence.")
    }

    /// Auto-fired ad-hoc-mode attempts also opt out. Ad-hoc surfaces
    /// don't write to a Device row anyway (no `device` to persist
    /// to), but the contract is stated on the attempt itself so it
    /// holds uniformly across modes.
    func testAutoFireAdHocModeNeverOptsIntoSaveAsDefault() {
        let attempt = SSHTerminalView.autoFireAttempt(
            connection: .adHoc(host: "127.0.0.1", port: 22, username: "root", credentialID: UUID()),
            deviceDefaultUsername: nil,
            deviceDefaultCredentialID: nil,
            knownCredentialIDs: []
        )
        XCTAssertNotNil(attempt)
        XCTAssertFalse(attempt?.saveAsDefault ?? true, "Auto-fired ad-hoc attempt must opt out of persistence.")
    }

    // MARK: - applyDeviceDefaultsIfRequested

    /// Opt-out attempt → no write. The contract that makes "failed
    /// attempts persist nothing" meaningful: the lifecycle reaches
    /// the persistence call site **only** after `status = .connected`,
    /// and even then the helper writes only when the attempt opted
    /// in. Setting `saveAsDefault: false` and asserting both Device
    /// fields stay nil pins the gate on the simulated "failed
    /// attempt would have persisted" path: a regression that wrote
    /// unconditionally would silently turn every connect into a
    /// defaults stomp.
    @MainActor
    func testApplyDeviceDefaultsIfRequestedSkipsWriteWhenOptedOut() {
        let device = Device(id: 42)
        XCTAssertNil(device.defaultUsername)
        XCTAssertNil(device.defaultCredentialID)
        let credentialID = UUID()
        let attempt = SSHTerminalView.ConnectionAttempt(
            nonce: UUID(),
            username: "admin",
            credentialID: credentialID,
            saveAsDefault: false
        )
        let wrote = SSHTerminalView.applyDeviceDefaultsIfRequested(attempt: attempt, device: device)
        XCTAssertFalse(wrote, "Opt-out attempt must not write.")
        XCTAssertNil(device.defaultUsername, "defaultUsername must remain nil after opt-out attempt.")
        XCTAssertNil(device.defaultCredentialID, "defaultCredentialID must remain nil after opt-out attempt.")
    }

    /// Opt-in attempt → both fields written from the attempt's
    /// snapshot. The happy path that closes the "every device row
    /// sees the form on every connect" failure mode this slice exists
    /// to fix.
    @MainActor
    func testApplyDeviceDefaultsIfRequestedWritesBothFieldsWhenOptedIn() {
        let device = Device(id: 42)
        let credentialID = UUID()
        let attempt = SSHTerminalView.ConnectionAttempt(
            nonce: UUID(),
            username: "admin",
            credentialID: credentialID,
            saveAsDefault: true
        )
        let wrote = SSHTerminalView.applyDeviceDefaultsIfRequested(attempt: attempt, device: device)
        XCTAssertTrue(wrote)
        XCTAssertEqual(device.defaultUsername, "admin")
        XCTAssertEqual(device.defaultCredentialID, credentialID)
    }

    /// Opt-in but no device (ad-hoc connection) → no write. Defence
    /// in depth: ad-hoc surfaces never render the checkbox so the
    /// flag should never arrive as `true` from that path, but the
    /// helper holds the contract regardless of the caller's
    /// hygiene.
    @MainActor
    func testApplyDeviceDefaultsIfRequestedSkipsWriteForNilDevice() {
        let attempt = SSHTerminalView.ConnectionAttempt(
            nonce: UUID(),
            username: "admin",
            credentialID: UUID(),
            saveAsDefault: true
        )
        let wrote = SSHTerminalView.applyDeviceDefaultsIfRequested(attempt: attempt, device: nil)
        XCTAssertFalse(wrote, "Nil device must produce no write even when the attempt opted in.")
    }

    // MARK: - clearDeviceDefaults

    /// Clear-defaults nils both fields in one gesture. A
    /// half-cleared row (one field nil, the other still set) is its
    /// own footgun — the next open would either show the form with
    /// one field pre-filled (confusing) or auto-fire with stale
    /// half-state. Symmetry is the property the test pins.
    @MainActor
    func testClearDeviceDefaultsNilsBothFieldsAtomically() {
        let device = Device(id: 42)
        device.defaultUsername = "admin"
        device.defaultCredentialID = UUID()
        SSHTerminalView.clearDeviceDefaults(device: device)
        XCTAssertNil(device.defaultUsername, "defaultUsername must be nil after clear.")
        XCTAssertNil(device.defaultCredentialID, "defaultCredentialID must be nil after clear.")
    }

    // MARK: - Device.primaryIPAddress (CIDR strip)
    //
    // The strip's correctness is the wire-shape contract the SSH
    // connect path depends on: NIOSSH's `Channel.connect(host:port:)`
    // resolves the host literally and fails opaquely ("Connect
    // timeout (10 s)") if handed a CIDR-shaped string. Tests live in
    // this file because the SSH connect path is the consumer; a
    // dedicated `DevicePrimaryIPAddressTests.swift` would need
    // pbxproj surgery for one property and the existing test target
    // already imports `@testable import Pulse` plus `Device`.

    /// IPv4 host address `1.1.1.1/32` strips to `1.1.1.1`. The
    /// canonical NetBox shape for a device's primary management IP.
    @MainActor
    func testPrimaryIPAddressStripsIPv4Host32() {
        let device = Device(id: 42)
        device.primaryIP = "1.1.1.1/32"
        XCTAssertEqual(device.primaryIPAddress, "1.1.1.1")
    }

    /// IPv4 subnet address `192.0.2.10/24` strips to `192.0.2.10`.
    /// NetBox can carry non-/32 prefixes when the operator records
    /// the address within its subnet context rather than as a host;
    /// the strip behaviour is the same regardless of prefix length.
    @MainActor
    func testPrimaryIPAddressStripsIPv4Subnet24() {
        let device = Device(id: 42)
        device.primaryIP = "192.0.2.10/24"
        XCTAssertEqual(device.primaryIPAddress, "192.0.2.10")
    }

    /// IPv6 host address `2001:db8::1/128` strips to `2001:db8::1`.
    /// The strip operates on the first `/`, which IPv6 CIDR notation
    /// uses for the prefix length; no IPv6 address text contains a
    /// literal `/` for any other reason.
    @MainActor
    func testPrimaryIPAddressStripsIPv6() {
        let device = Device(id: 42)
        device.primaryIP = "2001:db8::1/128"
        XCTAssertEqual(device.primaryIPAddress, "2001:db8::1")
    }

    /// An address without a CIDR prefix returns unchanged. Defence
    /// in depth against a future NetBox export shape change or an
    /// operator-edited row that happens to omit the mask; the strip
    /// must not mutate the value when there's nothing to strip.
    @MainActor
    func testPrimaryIPAddressPassesThroughWhenNoSlash() {
        let device = Device(id: 42)
        device.primaryIP = "10.0.0.1"
        XCTAssertEqual(device.primaryIPAddress, "10.0.0.1")
    }

    /// nil primaryIP returns nil. Callers gate on the optional
    /// (`guard let host = device.primaryIPAddress, !host.isEmpty
    /// else { ... }`); a regression that returned an empty string
    /// instead of nil would bypass the guard and feed an empty host
    /// to NIOSSH.
    @MainActor
    func testPrimaryIPAddressReturnsNilWhenSourceIsNil() {
        let device = Device(id: 42)
        device.primaryIP = nil
        XCTAssertNil(device.primaryIPAddress)
    }

    /// Empty primaryIP returns empty (the prefix before the absent
    /// slash is the empty string). The caller's `!isEmpty` guard
    /// catches this; we test the contract here so the caller-side
    /// guard remains the gate of record rather than implicit on
    /// strip behaviour.
    @MainActor
    func testPrimaryIPAddressReturnsEmptyWhenSourceIsEmpty() {
        let device = Device(id: 42)
        device.primaryIP = ""
        XCTAssertEqual(device.primaryIPAddress, "")
    }

    /// Malformed `/32` (mask-only, no address) strips to empty.
    /// Matches the empty-source contract above; combined with the
    /// caller's `!isEmpty` guard this routes to the
    /// "no primary IP configured" failure path rather than to a
    /// NIOSSH connect attempt against an empty host.
    @MainActor
    func testPrimaryIPAddressStripsToEmptyForMaskOnlyInput() {
        let device = Device(id: 42)
        device.primaryIP = "/32"
        XCTAssertEqual(device.primaryIPAddress, "")
    }

    // MARK: - Toolbar contract (statusPillCopy + primaryActionShape)
    //
    // The toolbar status pill's one-word copy and the primary-action
    // button's presence are operator-facing contracts pinned in the
    // ADR's routing-disambiguation note. A silent string
    // change to the pill copy, or a status-to-action mapping
    // regression that hid the Disconnect / Reconnect button at the
    // wrong moment, would land in a release without review. These
    // tests pin both contracts as pure functions over the
    // `ConnectionStatus` enum.

    /// `.idle` maps to "Idle" for exhaustiveness even though the
    /// toolbar hides the pill in that state. The mapping is pinned
    /// for the full enum surface so a future maintainer who decides
    /// to surface the pill in `.idle` doesn't have to re-derive the
    /// copy.
    func testStatusPillCopyIdle() {
        XCTAssertEqual(SSHTerminalView.statusPillCopy(for: .idle), "Idle")
    }

    func testStatusPillCopyConnecting() {
        XCTAssertEqual(SSHTerminalView.statusPillCopy(for: .connecting), "Connecting")
    }

    func testStatusPillCopyConnected() {
        XCTAssertEqual(SSHTerminalView.statusPillCopy(for: .connected), "Connected")
    }

    func testStatusPillCopyDisconnected() {
        XCTAssertEqual(SSHTerminalView.statusPillCopy(for: .disconnected("cause")), "Disconnected")
    }

    func testStatusPillCopyFailed() {
        XCTAssertEqual(SSHTerminalView.statusPillCopy(for: .failed("reason")), "Failed")
    }

    /// `.idle` and `.connecting` produce no primary action — the
    /// toolbar shows neither Disconnect nor Reconnect at these
    /// states. Pre-connect actions live in the in-view form; the
    /// in-flight handshake is visualised by the status pill turning
    /// yellow, no action button.
    func testPrimaryActionShapeIdleIsNil() {
        XCTAssertNil(SSHTerminalView.primaryActionShape(for: .idle))
    }

    func testPrimaryActionShapeConnectingIsNil() {
        XCTAssertNil(SSHTerminalView.primaryActionShape(for: .connecting))
    }

    /// `.connected` maps to `.disconnect`. The action's behaviour
    /// (calls `dismiss()`, drives `.task` cancellation, fires the
    /// deferred `client.close()`) is wired in `primaryActionButton`;
    /// the mapping pinned here is the "which action is showing"
    /// contract.
    func testPrimaryActionShapeConnectedIsDisconnect() {
        XCTAssertEqual(SSHTerminalView.primaryActionShape(for: .connected), .disconnect)
    }

    /// `.disconnected` maps to `.reconnect`. Operator can re-fire
    /// the lifecycle from the captured form values without
    /// returning to the form.
    func testPrimaryActionShapeDisconnectedIsReconnect() {
        XCTAssertEqual(SSHTerminalView.primaryActionShape(for: .disconnected("cause")), .reconnect)
    }

    /// `.failed` also maps to `.reconnect`. Same retry path; the
    /// in-view form re-renders with the error banner above so the
    /// operator can fix the username or credential and click
    /// Reconnect in the toolbar, OR Connect on the form. Two paths
    /// to the same re-fire (toolbar uses captured values; form
    /// re-binds them); deliberate complements.
    func testPrimaryActionShapeFailedIsReconnect() {
        XCTAssertEqual(SSHTerminalView.primaryActionShape(for: .failed("reason")), .reconnect)
    }
}
