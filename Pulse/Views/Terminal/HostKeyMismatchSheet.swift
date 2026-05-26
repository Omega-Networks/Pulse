//
//  HostKeyMismatchSheet.swift
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

/// Modal presented when the server's host key fingerprint differs from
/// the stored TOFU pin. Three operator actions, each with the visual
/// contract from ADR §5's three-mode trust UI:
///
/// - **Accept** (amber). Treat the new key as a legitimate rotation:
///   replace the stored pin and let the connection proceed. Amber
///   matches the TOFU-acceptance state in the rest of the trust UI;
///   it signals "this is the moment you implicitly extend trust".
/// - **Reject** (red). The default. Treat the mismatch as suspect:
///   the connection is aborted and the stored pin is unchanged.
///   `defaultFocus = .reject` is the load-bearing security property
///   of this sheet — a stray Return key must never accept a key
///   rotation, and the test in `HostKeyMismatchSheetTests` pins it.
/// - **Forget** (neutral). Delete the stored pin; the next connection
///   to this host:port becomes a fresh TOFU. Operator pick when they
///   know the host genuinely re-keyed and want to start the trust
///   relationship over.
///
/// The sheet only gathers the operator's decision; the trust-store
/// mutation and the audit event are the delegate's concern. A
/// subsequent change wires the `resume` closure to a
/// `CheckedContinuation` the delegate awaits with a 90-second
/// timeout.
struct HostKeyMismatchSheet: View {

    /// The button the sheet focuses on appear. **Reject** is the
    /// security-relevant default: a stray Return key on this sheet
    /// must never accept a key rotation. The static constant exists
    /// so the test in `HostKeyMismatchSheetTests` pins the contract
    /// without rendering the view (SwiftUI's `@FocusState` is private
    /// state and not directly inspectable from a unit test).
    static let defaultFocus: FocusedButton = .reject

    enum FocusedButton: Hashable {
        case accept
        case reject
        case forget
    }

    let host: String
    let port: Int
    let recordedFingerprint: String
    let recordedAlgorithm: String
    let recordedFirstSeenAt: Date
    let newFingerprint: String
    let newAlgorithm: String

    /// Operator's chosen action. The owning view wraps this in a
    /// continuation; the delegate awaits the continuation under a
    /// 90-second timeout.
    let resume: (HostKeyMismatchDecision) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedButton: FocusedButton?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            fingerprintComparison
            actions
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 540)
        .onAppear {
            focusedButton = Self.defaultFocus
        }
    }

    // MARK: - View sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Host key has changed", systemImage: "exclamationmark.shield.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text("The fingerprint \(host):\(port) is presenting differs from the key Pulse has pinned for this device. This could be a legitimate key rotation or a man-in-the-middle attempt.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fingerprintComparison: some View {
        VStack(alignment: .leading, spacing: 12) {
            fingerprintRow(
                heading: "Stored",
                fingerprint: recordedFingerprint,
                algorithm: recordedAlgorithm,
                caption: "First seen \(recordedFirstSeenAt.formatted(date: .abbreviated, time: .shortened))"
            )
            Divider()
            fingerprintRow(
                heading: "Presented",
                fingerprint: newFingerprint,
                algorithm: newAlgorithm,
                caption: "Right now, from \(host):\(port)"
            )
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fingerprintRow(
        heading: String,
        fingerprint: String,
        algorithm: String,
        caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(fingerprint)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(algorithm)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            // Forget is on the left because it's the "start over" action:
            // operationally less common than reject, semantically separate
            // from the accept/reject pair. Visual order: forget · spacer ·
            // reject · accept.
            Button("Forget", role: .none) {
                resolve(.forget)
            }
            .focused($focusedButton, equals: .forget)

            Spacer()

            Button("Reject", role: .cancel) {
                resolve(.reject(reason: nil))
            }
            .keyboardShortcut(.cancelAction)
            .tint(.red)
            .focused($focusedButton, equals: .reject)

            // Accept is the only action that writes new trust state.
            // No `role: .destructive`: HIG reserves that role for actions
            // that delete data or are otherwise irreversible. Pinning a
            // new fingerprint is neither — the prior pin can be
            // re-asserted by an operator who knows the previous
            // fingerprint. The orange tint carries the visual weight.
            Button("Accept") {
                resolve(.accept(fingerprintSHA256: newFingerprint, algorithm: newAlgorithm))
            }
            .tint(.orange)
            .focused($focusedButton, equals: .accept)
        }
    }

    private func resolve(_ decision: HostKeyMismatchDecision) {
        resume(decision)
        dismiss()
    }
}
