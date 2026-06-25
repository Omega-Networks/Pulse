//
//  TLSTrustCoordinatorTests.swift
//  PulseTests
//
//  Copyright © 2025-present Omega Networks Limited.
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

import Foundation
import XCTest
@testable import Pulse

/// Headless coverage for the TLS trust coordinator's continuation bridge and the
/// trust prompt's security default. The on-device behaviour (the sheet actually
/// presenting, the page actually loading) is a W2b gate.
final class TLSTrustCoordinatorTests: XCTestCase {

    /// Wait for the coordinator to post its pending request, polling the
    /// MainActor-isolated property.
    private func awaitPending(_ coordinator: TLSTrustCoordinator) async throws -> TLSTrustCoordinator.PendingTLSTrust {
        for _ in 0..<400 {
            if let pending = await coordinator.pending { return pending }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw XCTSkip("coordinator never posted a pending request")
    }

    func testTimeoutRejectsWithDecisionTimeout() async {
        let coordinator = await TLSTrustCoordinator(decisionTimeout: .milliseconds(50))
        let decision = await coordinator.decide(
            host: "10.0.0.1",
            port: 443,
            scheme: "https",
            reason: "self-signed or untrusted certificate",
            presentedFingerprint: "fp",
            presentedAlgorithm: "EC-256"
        )
        XCTAssertEqual(decision, .reject(reason: "decision_timeout"))
    }

    func testFirstSightAcceptResumes() async throws {
        let coordinator = await TLSTrustCoordinator(decisionTimeout: .seconds(30))
        async let decision = coordinator.decide(
            host: "10.0.0.1",
            port: 443,
            scheme: "https",
            reason: "self-signed or untrusted certificate",
            presentedFingerprint: "fp",
            presentedAlgorithm: "EC-256"
        )
        let pending = try await awaitPending(coordinator)
        XCTAssertFalse(pending.isMismatch)
        pending.resume(.accept)
        let result = await decision
        XCTAssertEqual(result, .accept)
    }

    func testMismatchPendingCarriesRecordedFingerprint() async throws {
        let coordinator = await TLSTrustCoordinator(decisionTimeout: .seconds(30))
        async let decision = coordinator.decide(
            host: "host",
            port: 443,
            scheme: "https",
            reason: "changed certificate",
            presentedFingerprint: "new",
            presentedAlgorithm: "EC-256",
            recordedFingerprint: "old",
            recordedAlgorithm: "EC-256",
            recordedFirstSeenAt: Date(timeIntervalSince1970: 0)
        )
        let pending = try await awaitPending(coordinator)
        XCTAssertTrue(pending.isMismatch)
        XCTAssertEqual(pending.recordedFingerprint, "old")
        pending.resume(.reject(reason: nil))
        let result = await decision
        XCTAssertEqual(result, .reject(reason: nil))
    }

    func testSheetDefaultFocusIsReject() {
        // The load-bearing security property: a stray Return must never extend
        // trust. Pinned here so a refactor of the sheet cannot silently flip it.
        XCTAssertEqual(TLSTrustPromptSheet.defaultFocus, .reject)
    }

    // MARK: - Coalescing

    func testConcurrentSameHostCoalescesOntoOneDecision() async throws {
        let coordinator = await TLSTrustCoordinator(decisionTimeout: .seconds(30))
        async let d1 = coordinator.decide(
            host: "h", port: 8006, scheme: "https",
            reason: "self-signed or untrusted certificate",
            presentedFingerprint: "fp", presentedAlgorithm: "EC-256"
        )
        let pending = try await awaitPending(coordinator)

        // A second concurrent challenge for the same host:port coalesces onto the
        // prompt already on screen, rather than posting a new one or being rejected.
        async let d2 = coordinator.decide(
            host: "h", port: 8006, scheme: "https",
            reason: "self-signed or untrusted certificate",
            presentedFingerprint: "fp", presentedAlgorithm: "EC-256"
        )
        try await Task.sleep(for: .milliseconds(50))
        let promptID = await coordinator.pending?.id
        XCTAssertEqual(promptID, pending.id, "the second challenge must not post a new prompt")

        // One operator decision resolves both in-flight challenges.
        pending.resume(.accept)
        let r1 = await d1
        let r2 = await d2
        XCTAssertEqual(r1, .accept)
        XCTAssertEqual(r2, .accept)
        let cleared = await coordinator.pending
        XCTAssertNil(cleared)
    }

    func testConcurrentDifferentHostRejectsWithoutDisturbingThePrompt() async throws {
        let coordinator = await TLSTrustCoordinator(decisionTimeout: .seconds(30))
        async let d1 = coordinator.decide(
            host: "a", port: 443, scheme: "https",
            reason: "self-signed or untrusted certificate",
            presentedFingerprint: "fpA", presentedAlgorithm: "EC-256"
        )
        let pending = try await awaitPending(coordinator)

        // A different host:port while one is pending is a single-origin-window
        // contract violation: rejected, and the first prompt is left standing.
        let other = await coordinator.decide(
            host: "b", port: 443, scheme: "https",
            reason: "self-signed or untrusted certificate",
            presentedFingerprint: "fpB", presentedAlgorithm: "EC-256"
        )
        XCTAssertEqual(other, .reject(reason: "concurrent_decide"))
        let promptID = await coordinator.pending?.id
        XCTAssertEqual(promptID, pending.id)

        pending.resume(.reject(reason: nil))
        _ = await d1
    }

    // MARK: - Reload-signal dedup

    func testNotePinCommittedBumpsAcceptTickOncePerAccept() async throws {
        let coordinator = await TLSTrustCoordinator(decisionTimeout: .seconds(30))
        async let decision = coordinator.decide(
            host: "h", port: 443, scheme: "https",
            reason: "self-signed or untrusted certificate",
            presentedFingerprint: "fp", presentedAlgorithm: "EC-256"
        )
        let pending = try await awaitPending(coordinator)
        pending.resume(.accept)
        _ = await decision

        let before = await coordinator.acceptTick
        // A burst of coalesced accepts each calls notePinCommitted; only the first
        // bumps the reload signal.
        await coordinator.notePinCommitted()
        await coordinator.notePinCommitted()
        let after = await coordinator.acceptTick
        XCTAssertEqual(after - before, 1)
    }

    func testRejectLeavesReloadSignalUnarmed() async throws {
        let coordinator = await TLSTrustCoordinator(decisionTimeout: .seconds(30))
        async let decision = coordinator.decide(
            host: "h", port: 443, scheme: "https",
            reason: "self-signed or untrusted certificate",
            presentedFingerprint: "fp", presentedAlgorithm: "EC-256"
        )
        let pending = try await awaitPending(coordinator)
        pending.resume(.reject(reason: nil))
        _ = await decision

        let before = await coordinator.acceptTick
        // No accept happened, so a stray notePinCommitted must not bump acceptTick.
        await coordinator.notePinCommitted()
        let after = await coordinator.acceptTick
        XCTAssertEqual(after, before)
    }
}
