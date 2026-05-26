//
//  HostKeyMismatchCoordinator.swift
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

import Foundation
import OSLog
import SwiftUI

/// Bridges `SSHHostKeyDelegate`'s async `HostKeyMismatchDecisionProvider`
/// requirement to the SwiftUI sheet flow. The connecting view
/// (`SSHTerminalView`) owns one via `@StateObject` and passes it as
/// the `hostKeyMismatchProvider` to `SSHClient`.
///
/// **Flow.** When the delegate hits a mismatch, it calls `decide(...)`.
/// The coordinator suspends a `CheckedContinuation`, posts a
/// `PendingRequest` to its `@Published pending` property (which
/// drives a `.sheet(item:)` on the connecting view), and starts a
/// timeout task. The sheet's three buttons call back into
/// `resolve(_:)`, which resumes the continuation. If the timeout
/// fires before the operator decides, the coordinator itself resumes
/// the continuation with `.reject(reason: "decision_timeout")` and
/// clears the pending request so the sheet dismisses.
///
/// **Single-resume safety.** The continuation must be resumed
/// exactly once. `ResumeBox` is a lock-protected single-resume
/// wrapper: both the operator-action path and the timeout path call
/// `resumeIfNeeded(...)` and the box drops all but the first call.
/// Without the box a timeout firing the same instant the operator
/// clicks Reject would double-resume and crash.
///
/// **Decision timeout.** Defaults to 90 seconds per the ADR §5
/// amendment. Tests inject a shorter value via the constructor so
/// the timeout path exercises in a reasonable time.
@MainActor
final class HostKeyMismatchCoordinator: ObservableObject, HostKeyMismatchDecisionProvider {

    @Published var pending: PendingRequest?

    private let decisionTimeout: Duration

    init(decisionTimeout: Duration = .seconds(90)) {
        self.decisionTimeout = decisionTimeout
    }

    /// The shape `.sheet(item:)` consumes: a value that identifies
    /// the modal and carries the data needed to render it. The
    /// resume closure is captured here so the sheet's button
    /// handlers can call it without reaching back to the
    /// coordinator's identity.
    struct PendingRequest: Identifiable, Sendable {
        let id = UUID()
        let host: String
        let port: Int
        let recordedFingerprint: String
        let recordedAlgorithm: String
        let recordedFirstSeenAt: Date
        let newFingerprint: String
        let newAlgorithm: String
        let resume: @Sendable (HostKeyMismatchDecision) -> Void
    }

    // MARK: - HostKeyMismatchDecisionProvider

    nonisolated func decide(
        host: String,
        port: Int,
        recordedFingerprint: String,
        recordedAlgorithm: String,
        recordedFirstSeenAt: Date,
        newFingerprint: String,
        newAlgorithm: String
    ) async -> HostKeyMismatchDecision {
        // The box is created before the continuation so the cancellation
        // handler can reach it without a circular capture. The reshaped
        // ResumeBox holds the resume in a `deferredDecision` slot if the
        // attach happens after a cancel.
        let box = ResumeBox()
        let logger = Logger(subsystem: "pulse", category: "hostkey.coordinator")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HostKeyMismatchDecision, Never>) in
                box.attach(continuation)

                let request = PendingRequest(
                    host: host,
                    port: port,
                    recordedFingerprint: recordedFingerprint,
                    recordedAlgorithm: recordedAlgorithm,
                    recordedFirstSeenAt: recordedFirstSeenAt,
                    newFingerprint: newFingerprint,
                    newAlgorithm: newAlgorithm,
                    resume: { decision in box.resumeIfNeeded(with: decision) }
                )
                let requestID = request.id
                let timeout = self.decisionTimeout

                Task { @MainActor in
                    // V1 contract: one coordinator per terminal view. A
                    // second decide while the first is in flight is a
                    // contract violation. Degrade gracefully: fault-log
                    // the violation (lands in Console.app and any SIEM
                    // ingesting os_log) and resolve the second call with
                    // an explicit reject reason so the audit trail
                    // explains what happened. No assertionFailure: debug
                    // and release behave identically, and the test in
                    // step 11 runs without preprocessor gating.
                    if self.pending != nil {
                        logger.fault(
                            "hostkey.coordinator.concurrent_decide host=\(host, privacy: .public) port=\(port)"
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
            // Parent view torn down (window closed, navigation popped,
            // task scope cancelled). Distinguish this from
            // decision_timeout in the audit vocabulary so operations can
            // tell "walked away" from "closed the window". ResumeBox's
            // single-resume contract makes the timeout-or-sheet path
            // idempotent if either races us.
            box.resumeIfNeeded(with: .reject(reason: "cancelled"))
            Task { @MainActor in self.pending = nil }
        }
    }

    // MARK: - Sheet resolution (called from the SwiftUI button handlers)

    func resolve(_ decision: HostKeyMismatchDecision) {
        guard let pending else { return }
        pending.resume(decision)
        self.pending = nil
    }

    private func clearPendingIfMatching(_ id: UUID) {
        if pending?.id == id {
            pending = nil
        }
    }
}

// MARK: - ResumeBox

/// Lock-protected single-resume wrapper around a `CheckedContinuation`.
/// The coordinator's operator-action, timeout, concurrent-decide-degrade,
/// and external-cancellation paths all call `resumeIfNeeded(...)`; the box
/// guarantees the underlying continuation resumes exactly once even when
/// they race.
///
/// **Late-attach support.** The box is created before
/// `withCheckedContinuation` so the cancellation handler can reach it. If
/// a resume call arrives before the continuation is attached (the
/// cancellation handler firing in a tight race), the decision is parked
/// in `deferredDecision` and applied at attach time.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostKeyMismatchDecision, Never>?
    private var deferredDecision: HostKeyMismatchDecision?

    init() {}

    func attach(_ c: CheckedContinuation<HostKeyMismatchDecision, Never>) {
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

    func resumeIfNeeded(with decision: HostKeyMismatchDecision) {
        lock.lock()
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(returning: decision)
            return
        }
        // Continuation not attached yet (cancellation racing with the
        // body's synchronous setup). Park the decision so attach can
        // deliver it. Subsequent resumes are dropped.
        if deferredDecision == nil {
            deferredDecision = decision
        }
        lock.unlock()
    }
}
