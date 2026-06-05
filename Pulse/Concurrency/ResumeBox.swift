//
//  ResumeBox.swift
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

// MARK: - ResumeBox

/// Lock-protected single-resume wrapper around a `CheckedContinuation`, with
/// late-attach support. One generic box shared by every coordinator that bridges
/// an async decision to a SwiftUI prompt: TLS trust (`TLSTrustCoordinator`), SSH
/// host-key mismatch (`HostKeyMismatchCoordinator`), and the web download
/// save / foreign-origin prompts (`WebDownloadCenter`).
///
/// **Why a shared generic, not a per-coordinator copy.** The box is the
/// load-bearing safety primitive: the operator-action, timeout,
/// concurrent-decide-degrade, and external-cancellation paths all call
/// `resumeIfNeeded(...)`, and the box guarantees the underlying continuation
/// resumes *exactly once* even when they race. Without it, a timeout firing the
/// same instant the operator clicks would double-resume and crash. The earlier
/// per-coordinator copies drifted (one shipped a dismissible-sheet regression),
/// so the one correct implementation lives here, parameterised on whatever
/// `Decision` the coordinator returns.
///
/// **Late-attach support.** The box is created *before* `withCheckedContinuation`
/// so a cancellation handler can reach it. If a resume arrives before the
/// continuation is attached (the cancellation handler firing in a tight race
/// with the body's synchronous setup), the decision is parked in
/// `deferredDecision` and delivered at attach time. Subsequent resumes are
/// dropped.
final class ResumeBox<Decision: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Decision, Never>?
    private var deferredDecision: Decision?

    init() {}

    func attach(_ c: CheckedContinuation<Decision, Never>) {
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

    func resumeIfNeeded(with decision: Decision) {
        lock.lock()
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(returning: decision)
            return
        }
        // Continuation not attached yet (cancellation racing the body's
        // synchronous setup). Park the decision so attach can deliver it.
        // Subsequent resumes are dropped.
        if deferredDecision == nil {
            deferredDecision = decision
        }
        lock.unlock()
    }
}
