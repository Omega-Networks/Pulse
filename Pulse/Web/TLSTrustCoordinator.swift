//
//  TLSTrustCoordinator.swift
//  Pulse
//
//  Copyright © 2025-present Omega Networks Limited.
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

import Foundation
import OSLog
import SwiftUI

// MARK: - TLS trust decision (operator-chosen)

/// The operator's response to a TLS trust prompt. Mirrors
/// `HostKeyMismatchDecision`. `forget` is only meaningful for a mismatch (there
/// is nothing to forget on first sight), so the sheet offers it only in the
/// mismatch shape.
enum TLSTrustDecision: Equatable, Sendable {
    case accept
    case reject(reason: String?)
    case forget
}

// MARK: - TLS trust coordinator

/// Bridges the web navigation decider's async server-trust challenge to the
/// SwiftUI sheet flow, mirroring `HostKeyMismatchCoordinator`.
///
/// **Flow.** When the decider meets an untrusted certificate, it calls
/// `decide(...)`. The coordinator suspends a `CheckedContinuation`, posts a
/// `PendingTLSTrust` to its `@Published pending` (driving a `.sheet(item:)` on
/// `DeviceWebView`), and starts a timeout task. The sheet's buttons resume the
/// continuation through the pending's `resume` closure; dismissing the sheet
/// clears `pending` via the item binding.
///
/// **Single-resume safety / timeout / cancellation.** Identical in shape to the
/// SSH coordinator: a lock-protected `ResumeBox` guarantees exactly-once
/// resume across the operator path, the 90-second timeout (defaulting per ADR
/// §5, injectable for tests), the concurrent-decide degrade, and external task
/// cancellation. See `HostKeyMismatchCoordinator` for the full rationale.
@MainActor
final class TLSTrustCoordinator: ObservableObject {

    @Published var pending: PendingTLSTrust?

    /// Bumped each time the operator accepts a trust prompt. The view observes
    /// this to reload the page so it connects with the now-pinned certificate:
    /// accepting a server-trust challenge does not reliably resume the suspended
    /// provisional navigation, so an explicit reload is the robust path.
    @Published private(set) var acceptTick = 0

    private let decisionTimeout: Duration

    init(decisionTimeout: Duration = .seconds(90)) {
        self.decisionTimeout = decisionTimeout
    }

    /// Identifies the modal and carries what the sheet renders. The `recorded*`
    /// fields are nil for a first-sight prompt and populated for a mismatch.
    struct PendingTLSTrust: Identifiable, Sendable {
        let id = UUID()
        let host: String
        let port: Int
        let scheme: String
        /// Why the certificate is not already trusted, shown to the operator
        /// (e.g. "self-signed or untrusted certificate").
        let reason: String
        let presentedFingerprint: String
        let presentedAlgorithm: String
        let recordedFingerprint: String?
        let recordedAlgorithm: String?
        let recordedFirstSeenAt: Date?
        let resume: @Sendable (TLSTrustDecision) -> Void

        var isMismatch: Bool { recordedFingerprint != nil }
    }

    nonisolated func decide(
        host: String,
        port: Int,
        scheme: String,
        reason: String,
        presentedFingerprint: String,
        presentedAlgorithm: String,
        recordedFingerprint: String? = nil,
        recordedAlgorithm: String? = nil,
        recordedFirstSeenAt: Date? = nil
    ) async -> TLSTrustDecision {
        let box = ResumeBox()
        let logger = Logger(subsystem: "pulse", category: "web.trust")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TLSTrustDecision, Never>) in
                box.attach(continuation)

                let request = PendingTLSTrust(
                    host: host,
                    port: port,
                    scheme: scheme,
                    reason: reason,
                    presentedFingerprint: presentedFingerprint,
                    presentedAlgorithm: presentedAlgorithm,
                    recordedFingerprint: recordedFingerprint,
                    recordedAlgorithm: recordedAlgorithm,
                    recordedFirstSeenAt: recordedFirstSeenAt,
                    resume: { [weak self] decision in
                        if case .accept = decision {
                            Task { @MainActor in self?.acceptTick += 1 }
                        }
                        box.resumeIfNeeded(with: decision)
                    }
                )
                let requestID = request.id
                let timeout = self.decisionTimeout

                Task { @MainActor in
                    // One coordinator per web window. A second decide while the
                    // first is in flight is a contract violation: fault-log it
                    // (lands in Console.app and any SIEM ingesting os_log) and
                    // resolve the second call with an explicit reason so the
                    // audit trail explains what happened.
                    if self.pending != nil {
                        logger.fault(
                            "web.trust.concurrent_decide host=\(host, privacy: .public) port=\(port)"
                        )
                        box.resumeIfNeeded(with: .reject(reason: "concurrent_decide"))
                        return
                    }
                    self.pending = request
                }

                Task {
                    try? await Task.sleep(for: timeout)
                    box.resumeIfNeeded(with: .reject(reason: "decision_timeout"))
                    await self.clearPendingIfMatching(requestID)
                }
            }
        } onCancel: {
            // Parent view torn down (window closed). Distinguish from
            // decision_timeout in the audit vocabulary.
            box.resumeIfNeeded(with: .reject(reason: "cancelled"))
            Task { @MainActor in self.pending = nil }
        }
    }

    private func clearPendingIfMatching(_ id: UUID) {
        if pending?.id == id {
            pending = nil
        }
    }
}

// MARK: - ResumeBox

/// Lock-protected single-resume wrapper around a `CheckedContinuation`, with
/// late-attach support. Identical in contract to the SSH coordinator's
/// `ResumeBox`; see that type for the rationale.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TLSTrustDecision, Never>?
    private var deferredDecision: TLSTrustDecision?

    init() {}

    func attach(_ c: CheckedContinuation<TLSTrustDecision, Never>) {
        lock.lock()
        if let deferred = deferredDecision {
            deferredDecision = nil
            lock.unlock()
            c.resume(returning: deferred)
            return
        }
        continuation = c
        lock.unlock()
    }

    func resumeIfNeeded(with decision: TLSTrustDecision) {
        lock.lock()
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(returning: decision)
            return
        }
        if deferredDecision == nil {
            deferredDecision = decision
        }
        lock.unlock()
    }
}

// MARK: - TLS trust prompt sheet

/// Modal presented when a device-web TLS certificate is not already trusted.
/// Two shapes, both following ADR §5's trust-UI conventions:
///
/// - **First sight** (no prior pin): the certificate is self-signed or
///   otherwise untrusted. Buttons: Cancel (red, default focus) and Trust
///   (orange). Accepting pins the certificate.
/// - **Mismatch** (a stored pin differs): the presented certificate differs
///   from the trusted one. Buttons: Forget (neutral), Reject (red, default
///   focus), Accept (orange). Mirrors `HostKeyMismatchSheet`.
///
/// `defaultFocus = .reject` is the load-bearing security property: a stray
/// Return key must never extend trust. Pinned by a unit test.
struct TLSTrustPromptSheet: View {

    static let defaultFocus: FocusedButton = .reject

    enum FocusedButton: Hashable {
        case accept
        case reject
        case forget
    }

    let pending: TLSTrustCoordinator.PendingTLSTrust

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedButton: FocusedButton?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            certificateDetails
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
            Label(
                pending.isMismatch ? "Certificate has changed" : "Untrusted certificate",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.title2.weight(.semibold))
            .foregroundStyle(.red)
            Text(headerExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerExplanation: String {
        if pending.isMismatch {
            return "The certificate \(pending.host):\(pending.port) is presenting differs from the one Pulse has trusted for this device. This could be a legitimate rotation or a man-in-the-middle attempt."
        }
        return "\(pending.host):\(pending.port) presented a \(pending.reason). Pulse cannot verify it against a trusted authority. Trust it only if you recognise this device."
    }

    private var certificateDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pending.isMismatch, let recordedFingerprint = pending.recordedFingerprint {
                fingerprintRow(
                    heading: "Trusted",
                    fingerprint: recordedFingerprint,
                    algorithm: pending.recordedAlgorithm ?? "",
                    caption: pending.recordedFirstSeenAt.map {
                        "First trusted \($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? ""
                )
                Divider()
            }
            fingerprintRow(
                heading: "Presented",
                fingerprint: pending.presentedFingerprint,
                algorithm: pending.presentedAlgorithm,
                caption: "Right now, from \(pending.host):\(pending.port)"
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
                if !algorithm.isEmpty {
                    Text(algorithm)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                }
                if !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if pending.isMismatch {
                Button("Forget", role: .none) {
                    resolve(.forget)
                }
                .focused($focusedButton, equals: .forget)
            }

            Spacer()

            Button(pending.isMismatch ? "Reject" : "Cancel", role: .cancel) {
                resolve(.reject(reason: nil))
            }
            .keyboardShortcut(.cancelAction)
            .tint(.red)
            .focused($focusedButton, equals: .reject)

            Button(pending.isMismatch ? "Accept" : "Trust") {
                resolve(.accept)
            }
            .tint(.orange)
            .focused($focusedButton, equals: .accept)
        }
    }

    private func resolve(_ decision: TLSTrustDecision) {
        pending.resume(decision)
        dismiss()
    }
}
