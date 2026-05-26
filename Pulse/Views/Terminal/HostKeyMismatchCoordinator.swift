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
        await withCheckedContinuation { (continuation: CheckedContinuation<HostKeyMismatchDecision, Never>) in
            let box = ResumeBox(continuation: continuation)
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
                self.pending = request
            }

            Task {
                try? await Task.sleep(for: timeout)
                box.resumeIfNeeded(with: .reject(reason: "decision_timeout"))
                await self.clearPendingIfMatching(requestID)
            }
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
/// The coordinator's operator-action path and timeout path both call
/// `resumeIfNeeded(...)`; the box guarantees the underlying
/// continuation resumes exactly once even when they race.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostKeyMismatchDecision, Never>?

    init(continuation: CheckedContinuation<HostKeyMismatchDecision, Never>) {
        self.continuation = continuation
    }

    func resumeIfNeeded(with decision: HostKeyMismatchDecision) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: decision)
    }
}
