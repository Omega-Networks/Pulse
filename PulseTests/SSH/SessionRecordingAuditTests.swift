//
//  SessionRecordingAuditTests.swift
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

import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import Pulse

/// Coverage for `SessionRecordingAudit` — the typed audit surface that
/// every `session.recording.*` and `credential.recording.*` event now
/// flows through. The DEBUG-only `TestObserver` lets us assert on the
/// signal stream structurally rather than scraping `os_log` output.
///
/// The tests fall in two groups:
///
/// 1. **Direct emission.** Each event case is fired through the
///    convenience API and the captured event compared field-for-field.
///    Pins the public shape so a future field-drop is a compile error
///    at the call site here.
///
/// 2. **Integration.** Drive a real `SessionLogWriter` and
///    `SessionLogRetention.purge` and assert that the events they
///    emit are the structured ones — proves the inline `os_log` calls
///    in commits 2–5 were fully routed through the new surface.
final class SessionRecordingAuditTests: XCTestCase {

    // MARK: - Direct emission

    func testEachEventCaseRoundTripsThroughTheObserver() {
        let capture = SessionRecordingAudit.TestObserver.shared.startCapturing()

        let sessionID = UUID()
        let credentialID = UUID()
        SessionRecordingAudit.recordingOpened(
            sessionID: sessionID,
            credentialID: credentialID,
            deviceID: 42,
            pulselogRelativePath: "Pulse/Sessions/dev-42/session.pulselog"
        )
        SessionRecordingAudit.recordingClosed(
            sessionID: sessionID,
            recordCount: 17,
            chainHeadHash: "deadbeef",
            durationMs: 1234
        )
        SessionRecordingAudit.recordingFailed(
            sessionID: sessionID,
            reason: .backPressureOverflow
        )
        SessionRecordingAudit.recordingFailed(
            sessionID: sessionID,
            reason: .sealFailure(detail: "GCM internal")
        )
        SessionRecordingAudit.replayUnwrapped(sessionID: sessionID)
        SessionRecordingAudit.replayChainBroken(sessionID: sessionID, brokenAtSeq: 5)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        SessionRecordingAudit.purged(count: 3, oldestPurgedDate: oldDate)
        SessionRecordingAudit.purgeFailed(reason: "walkFault")
        SessionRecordingAudit.credentialRecordingEnabled(credentialID: credentialID)
        SessionRecordingAudit.credentialRecordingDisabled(credentialID: credentialID)

        let events = capture.events
        XCTAssertEqual(events.count, 10)

        guard events.count == 10 else { return }

        XCTAssertEqual(events[0], .recordingOpened(
            sessionID: sessionID,
            credentialID: credentialID,
            deviceID: 42,
            pulselogRelativePath: "Pulse/Sessions/dev-42/session.pulselog"
        ))
        XCTAssertEqual(events[1], .recordingClosed(
            sessionID: sessionID,
            recordCount: 17,
            chainHeadHash: "deadbeef",
            durationMs: 1234
        ))
        XCTAssertEqual(events[2], .recordingFailed(sessionID: sessionID, reason: .backPressureOverflow))
        XCTAssertEqual(events[3], .recordingFailed(sessionID: sessionID, reason: .sealFailure(detail: "GCM internal")))
        XCTAssertEqual(events[4], .replayUnwrapped(sessionID: sessionID))
        XCTAssertEqual(events[5], .replayChainBroken(sessionID: sessionID, brokenAtSeq: 5))
        XCTAssertEqual(events[6], .purged(count: 3, oldestPurgedDate: oldDate))
        XCTAssertEqual(events[7], .purgeFailed(reason: "walkFault"))
        XCTAssertEqual(events[8], .credentialRecordingEnabled(credentialID: credentialID))
        XCTAssertEqual(events[9], .credentialRecordingDisabled(credentialID: credentialID))
    }

    func testFailureReasonAuditStrings() {
        // Stable strings the audit emission and any SIEM rule depend
        // on. Regression-guard against renames.
        XCTAssertEqual(SessionRecordingAudit.FailureReason.sealFailure(detail: "").auditReason, "seal_failure")
        XCTAssertEqual(SessionRecordingAudit.FailureReason.writeFailure(detail: "").auditReason, "write_failure")
        XCTAssertEqual(SessionRecordingAudit.FailureReason.encodeFailure(detail: "").auditReason, "encode_failure")
        XCTAssertEqual(SessionRecordingAudit.FailureReason.backPressureOverflow.auditReason, "back_pressure_overflow")
    }

    // MARK: - Writer integration

    func testWriterStructuralFailureEmitsRecordingFailedNotClosed() async throws {
        let capture = SessionRecordingAudit.TestObserver.shared.startCapturing()

        // Force a write failure on the first record append.
        let store = SessionLogWriterTests.InMemoryStore(failOnAppendAfter: 1)
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        let writer = try await SessionLogWriter.open(
            deviceID: 1,
            credentialID: UUID(),
            username: "x",
            host: "x",
            port: 22,
            store: store,
            wrappingPublicKey: { wrappingPriv.publicKey }
        )
        capture.reset()

        _ = writer.tryEnqueue(direction: .out, bytes: ArraySlice([0x41]))
        await writer.__drainForTests()

        let failed = capture.events.first { event in
            if case .recordingFailed = event { return true }
            return false
        }
        guard case .recordingFailed(_, let reason) = failed else {
            return XCTFail("Expected recordingFailed event")
        }
        XCTAssertEqual(reason.auditReason, "write_failure")

        // The close() that runs from finaliseAfterStructuralStop must
        // NOT also emit recordingClosed; the failed event is the
        // terminating signal for this session.
        await writer.close(exitCauseDescription: "operator_close")
        let closedEventsAfterFailure = capture.events.filter { event in
            if case .recordingClosed = event { return true }
            return false
        }
        XCTAssertEqual(closedEventsAfterFailure.count, 0)
    }

    // MARK: - Retention integration

    func testRetentionEnumerateFailureEmitsPurgeFailed() {
        let capture = SessionRecordingAudit.TestObserver.shared.startCapturing()

        let store = SessionLogRetentionTests.InMemoryRetentionStore(
            entries: [],
            enumerateError: NSError(domain: "walkFault", code: 1)
        )

        _ = SessionLogRetention.purge(maxAge: 60, referenceDate: .now, store: store)

        let failed = capture.events.first { event in
            if case .purgeFailed = event { return true }
            return false
        }
        XCTAssertNotNil(failed)
    }
}
