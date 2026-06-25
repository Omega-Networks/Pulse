//
//  SSHConnectForm.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Pulse
//  The Platform for Unified Leadership in Smart Environments.
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

import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Pre-connect form for device-row SSH terminals. Renders inside
/// `SSHTerminalView.terminalArea` in the `.idle` (first appearance,
/// defaults not set) and `.failed` (retry after a failed attempt)
/// states.
///
/// **Why inline rather than a sheet.** On macOS, `.sheet` reads as
/// modal escalation — the user expects "you must answer this before
/// you can do anything else". Connection setup is not destructive
/// (the device is on the other side, untouched until bytes flow);
/// gating it behind a modal would mis-signal the affordance.
/// Inline replacement of the `ProgressView` composes with the
/// existing `.idle` → `.connecting` → `.connected` state machine and
/// gives `.failed` a natural retry path: the same form re-renders
/// with the error banner above it. ADR §4 closes the
/// `SSHConnectSheet` non-negotiable with this inline shape.
///
/// **Why the form owns no business logic.** The parent
/// (`SSHTerminalView`) owns the `username` and `selectedCredentialID`
/// `@State`, the `onConnect` and `onCancel` closures, and the
/// `ConnectionAttempt` nonce that drives the lifecycle. The form
/// renders bindings and reports button presses. The two static
/// helpers (`canConnect`, `biometricHint`) carry the small contract
/// pieces that pay rent on unit-test exposure — everything else is
/// SwiftUI rendering against bindings.
struct SSHConnectForm: View {

    /// Title shown above the form (e.g. the device name or
    /// `username@host:port`). Computed by the parent so the form
    /// stays type-agnostic about ad-hoc vs device modes.
    let title: String

    /// Pre-resolved primary IP for the connection. Form disables the
    /// Connect button when nil or empty — the device-row context
    /// menu already gates on `primaryIP` presence, but defence in
    /// depth keeps the form correct under stale data (e.g. NetBox
    /// sync clears the IP while the window is open).
    let primaryIP: String?

    /// SSH port for the connection. Read-only here; the form
    /// surfaces it as part of the connection summary so the operator
    /// can confirm the target before committing.
    let port: Int

    /// Operator's preferred default username for this device if one
    /// is set, used to pre-fill the username field. Empty string
    /// means "show the placeholder hint, do not pre-fill".
    let initialUsername: String

    /// Credential list to pick from. Sorted by label.
    let credentials: [SSHCredential]

    /// Error message banner shown above the form on retry from
    /// `.failed`. Nil at `.idle` (first attempt).
    let errorMessage: String?

    /// Whether the form is rendering against a device-backed
    /// connection. Drives visibility of the "Save as default"
    /// checkbox and the "Clear saved defaults" button — both are
    /// per-Device persistence gestures that have no meaning for
    /// ad-hoc connections.
    let isDeviceMode: Bool

    /// Whether the underlying Device row has either of its two
    /// default fields populated. Drives visibility of the "Clear
    /// saved defaults" button: hidden when there's nothing to clear,
    /// so the button disappears once the operator acts on it.
    let hasSavedDefaults: Bool

    @Binding var username: String
    @Binding var selectedCredentialID: UUID?

    /// Operator's "Save as default" gesture. Only rendered in device
    /// mode. Captured into the next `ConnectionAttempt` at Connect-
    /// click; the lifecycle persists `Device.defaultUsername` and
    /// `Device.defaultCredentialID` only on `status = .connected`.
    @Binding var saveAsDefault: Bool

    let onConnect: () -> Void
    let onCancel: () -> Void

    /// Tapped when the operator clicks "Clear saved defaults". The
    /// parent owns the SwiftData write because the form is decoupled
    /// from `ModelContext`. Nil for ad-hoc surfaces; the form hides
    /// the button when the closure is nil or `hasSavedDefaults` is
    /// false.
    let onClearDefaults: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let errorMessage {
                errorBanner(errorMessage)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let primaryIP, !primaryIP.isEmpty {
                    Text("\(primaryIP):\(port)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No primary IP configured on this device.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Username")
                    .font(.subheadline.weight(.semibold))
                TextField(Self.usernamePlaceholder, text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .disableAutocorrection(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Credential")
                    .font(.subheadline.weight(.semibold))
                credentialPicker
                biometricHint
            }

            // "Save as default" gesture. Device mode only — ad-hoc
            // connections never persist to a SwiftData row, so the
            // checkbox would mis-signal the affordance. Operators
            // tick the box, connect successfully, and the next open
            // of this device row auto-fires.
            if isDeviceMode {
                Toggle("Save as default for this device", isOn: $saveAsDefault)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                    .help("Persist this username and credential as the device's defaults on a successful connect. Subsequent opens will auto-connect without showing this form.")
            }

            HStack(spacing: 12) {
                Button("Close", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect", action: onConnect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canConnect(
                        username: username,
                        credentialID: selectedCredentialID,
                        primaryIP: primaryIP
                    ))
            }

            // "Clear saved defaults" affordance. Rendered only in
            // device mode, only when something is saved, and only
            // when the parent supplied a handler. Tiny text button
            // below the primary action row so it does not compete
            // with Connect for the operator's eye; the affordance is
            // an undo gesture, not a primary action.
            if isDeviceMode, hasSavedDefaults, let onClearDefaults {
                HStack {
                    Spacer()
                    Button("Clear saved defaults", action: onClearDefaults)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        .onAppear {
            if username.isEmpty {
                username = initialUsername
            }
        }
    }

    @ViewBuilder
    private var credentialPicker: some View {
        if credentials.isEmpty {
            Text("No credentials in the local store. Open Settings → SSH to create one.")
                .font(.callout)
                .foregroundStyle(.red)
        } else {
            Picker("Credential", selection: $selectedCredentialID) {
                Text("Pick a credential").tag(UUID?.none)
                ForEach(credentials, id: \.id) { credential in
                    Text("\(credential.label) (\(credential.tier.label))")
                        .tag(UUID?.some(credential.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    /// Biometric-prompt-count preview below the credential picker.
    /// Closes the "why is it asking again?" moment by surfacing the
    /// back-to-back-prompts behaviour documented in
    /// `docs/credentials.md` "Connecting to a device" before the
    /// operator clicks Connect.
    @ViewBuilder
    private var biometricHint: some View {
        if let credentialID = selectedCredentialID,
           let credential = credentials.first(where: { $0.id == credentialID }) {
            Text(Self.biometricHint(recordSessions: credential.recordSessions))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Pure helpers (test seam)

    /// Whether the form has enough information to enable the Connect
    /// button. The button-disable logic is the structural enforcement
    /// of "operator must think" before connecting — picking a credential
    /// is explicit (no first-credential-in-store fallback), the
    /// username must be non-empty after trimming, and the primary IP
    /// must be present and non-empty (defence in depth against the
    /// device-row context-menu gate going stale).
    ///
    /// Exposed as a pure function so the test suite pins the contract
    /// without rendering the form: a regression here would silently
    /// re-introduce the "auto-connect with garbage defaults" failure
    /// mode this form exists to prevent.
    static func canConnect(username: String, credentialID: UUID?, primaryIP: String?) -> Bool {
        guard credentialID != nil,
              let primaryIP, !primaryIP.isEmpty,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    /// Operator-facing description of how many Touch ID / device-
    /// passcode prompts the upcoming connection will fire. Pure
    /// function so the test can pin the wording — the prompt-count
    /// matters for operator expectation-setting and a silent string
    /// change would land in a release without the "why is it asking
    /// twice?" surface the form was designed to close.
    static func biometricHint(recordSessions: Bool) -> String {
        if recordSessions {
            return "Two Touch ID prompts back-to-back: SSH signing + recording-key unwrap."
        } else {
            return "One Touch ID prompt on connect."
        }
    }

    /// Placeholder hint for the username field. Operator sees this
    /// when the field is empty; it is *not* pre-filled, so the form
    /// surfaces the fallback shape explicitly rather than connecting
    /// with it silently. macOS uses `NSUserName()` (the operator's
    /// short-name) to make the "wrong-user-by-default" failure mode
    /// visible at form-render time; iOS shows the literal word
    /// "username" because the iOS device user-shortname is rarely
    /// meaningful for network gear.
    static var usernamePlaceholder: String {
        #if os(macOS)
        return NSUserName()
        #else
        return "username"
        #endif
    }
}
