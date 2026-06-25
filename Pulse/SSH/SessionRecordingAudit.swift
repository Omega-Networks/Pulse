//
//  SessionRecordingAudit.swift
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
import NIOConcurrencyHelpers
import OSLog

// MARK: - SessionRecordingAudit

/// Typed emitter for the session-recording audit surface defined in
/// ADR §7. Replaces inline `os_log` calls scattered across the writer,
/// retention, and replay paths with a single chokepoint where event
/// names and field sets are enforced by the type system.
///
/// Why a typed `Event` enum rather than a `Logger` extension:
///
/// - **Field sets stay enforced.** Adding or removing a field on, say,
///   `session.recording.closed` is a compile error at every call site.
///   `Logger`-based emissions would only break the dashboard
///   downstream of the change.
/// - **Tests assert structurally.** `__captureEventsForTests` returns
///   a typed `[Event]` so tests can match `recording.closed` events by
///   sessionID and recordCount without scraping the os_log surface
///   (which is awkward to query from XCTest).
/// - **One name, one place.** A future SIEM rule looking for
///   `session.recording.replayChainBroken` can grep this file alone
///   for the source of truth on what fields it carries.
///
/// The actual `os_log` emission still happens — the typed event maps to
/// a `Logger.notice` or `.error` call internally — so operator-side
/// observability via `log show` is unchanged.
enum SessionRecordingAudit {

    // MARK: - Event

    /// Every audit signal the recording stack emits, in one place. Field sets match
    /// the ADR §7 "Audit events" table. Plaintext session bytes and
    /// key material are deliberately absent from every case —
    /// regression-checkable structurally.
    enum Event: Sendable, Equatable {

        // MARK: Recording lifecycle (category: ssh.recording)

        case recordingOpened(
            sessionID: UUID,
            credentialID: UUID,
            deviceID: Int64?,
            pulselogRelativePath: String
        )
        case recordingClosed(
            sessionID: UUID,
            recordCount: UInt64,
            chainHeadHash: String,
            durationMs: Int
        )
        case recordingFailed(
            sessionID: UUID,
            reason: FailureReason
        )

        // MARK: Replay (category: ssh.recording)

        /// Biometric succeeded; the operator now has access to the
        /// recorded plaintext. Fires regardless of subsequent chain
        /// validation outcome — the *access* event is security-relevant
        /// independent of file integrity.
        case replayUnwrapped(sessionID: UUID)

        /// Chain validation failed during replay. Distinct from
        /// `replayUnwrapped` so any future SIEM rule can fire cleanly
        /// on tamper-after-access.
        case replayChainBroken(sessionID: UUID, brokenAtSeq: UInt64)

        // MARK: Retention (category: ssh.recording)

        case purged(count: Int, oldestPurgedDate: Date?)
        case purgeFailed(reason: String)
    }

    /// Reason a recording transitioned mid-stream to the terminal stop
    /// state. Stable string forms come from `auditReason` so SIEM rules
    /// can match without parsing free-text.
    enum FailureReason: Sendable, Equatable {
        case sealFailure(detail: String)
        case writeFailure(detail: String)
        case encodeFailure(detail: String)
        case backPressureOverflow

        var auditReason: String {
            switch self {
            case .sealFailure: return "seal_failure"
            case .writeFailure: return "write_failure"
            case .encodeFailure: return "encode_failure"
            case .backPressureOverflow: return "back_pressure_overflow"
            }
        }

        var detail: String? {
            switch self {
            case .sealFailure(let d), .writeFailure(let d), .encodeFailure(let d):
                return d
            case .backPressureOverflow:
                return nil
            }
        }
    }

    // MARK: - Emit

    private static let recordingLogger = Logger(subsystem: "pulse", category: "ssh.recording")

    /// Single entry point. Production callers use the convenience
    /// methods below; this is the bottleneck where `os_log` happens.
    static func emit(_ event: Event) {
        log(event)
        #if DEBUG
        TestObserver.shared.notify(event)
        #endif
    }

    private static func log(_ event: Event) {
        switch event {
        case let .recordingOpened(sessionID, credentialID, deviceID, path):
            recordingLogger.notice(
                "session.recording.opened sessionID=\(sessionID.uuidString, privacy: .public) credentialID=\(credentialID.uuidString, privacy: .public) deviceID=\(deviceID.map(String.init) ?? "nil", privacy: .public) path=\(path, privacy: .public)"
            )
        case let .recordingClosed(sessionID, recordCount, chainHeadHash, durationMs):
            recordingLogger.notice(
                "session.recording.closed sessionID=\(sessionID.uuidString, privacy: .public) recordCount=\(recordCount, privacy: .public) chainHeadHash=\(chainHeadHash, privacy: .public) durationMs=\(durationMs, privacy: .public)"
            )
        case let .recordingFailed(sessionID, reason):
            let detail = reason.detail ?? ""
            recordingLogger.error(
                "session.recording.failed sessionID=\(sessionID.uuidString, privacy: .public) reason=\(reason.auditReason, privacy: .public) detail=\(detail, privacy: .public)"
            )
        case let .replayUnwrapped(sessionID):
            recordingLogger.notice(
                "session.recording.replayUnwrapped sessionID=\(sessionID.uuidString, privacy: .public)"
            )
        case let .replayChainBroken(sessionID, brokenAtSeq):
            recordingLogger.error(
                "session.recording.replayChainBroken sessionID=\(sessionID.uuidString, privacy: .public) brokenAtSeq=\(brokenAtSeq, privacy: .public)"
            )
        case let .purged(count, oldestPurgedDate):
            let oldestISO = oldestPurgedDate.map { SessionLogTimestamp.iso8601(from: $0) } ?? "nil"
            recordingLogger.notice(
                "session.recording.purged count=\(count, privacy: .public) oldestPurgedDate=\(oldestISO, privacy: .public)"
            )
        case let .purgeFailed(reason):
            recordingLogger.error(
                "session.recording.purgeFailed reason=\(reason, privacy: .public)"
            )
        }
    }
}

// MARK: - Convenience emitters

extension SessionRecordingAudit {

    static func recordingOpened(
        sessionID: UUID,
        credentialID: UUID,
        deviceID: Int64?,
        pulselogRelativePath: String
    ) {
        emit(.recordingOpened(
            sessionID: sessionID,
            credentialID: credentialID,
            deviceID: deviceID,
            pulselogRelativePath: pulselogRelativePath
        ))
    }

    static func recordingClosed(
        sessionID: UUID,
        recordCount: UInt64,
        chainHeadHash: String,
        durationMs: Int
    ) {
        emit(.recordingClosed(
            sessionID: sessionID,
            recordCount: recordCount,
            chainHeadHash: chainHeadHash,
            durationMs: durationMs
        ))
    }

    static func recordingFailed(sessionID: UUID, reason: FailureReason) {
        emit(.recordingFailed(sessionID: sessionID, reason: reason))
    }

    static func replayUnwrapped(sessionID: UUID) {
        emit(.replayUnwrapped(sessionID: sessionID))
    }

    static func replayChainBroken(sessionID: UUID, brokenAtSeq: UInt64) {
        emit(.replayChainBroken(sessionID: sessionID, brokenAtSeq: brokenAtSeq))
    }

    static func purged(count: Int, oldestPurgedDate: Date?) {
        emit(.purged(count: count, oldestPurgedDate: oldestPurgedDate))
    }

    static func purgeFailed(reason: String) {
        emit(.purgeFailed(reason: reason))
    }
}

// MARK: - Test observer

#if DEBUG

extension SessionRecordingAudit {

    /// Captures every emitted event for the lifetime of a
    /// `CaptureToken`. Tests use this to assert on the audit signal
    /// without scraping `log show`. The token's `deinit` removes the
    /// observer so a leaked token from a misbehaving test doesn't
    /// continue capturing events into the next test.
    ///
    /// Concurrency: events fire from arbitrary cooperative-pool
    /// threads (the writer actor's executor for recording lifecycle,
    /// `Task.detached` for retention). The observer uses a
    /// `NIOLockedValueBox` so the test thread reads a coherent
    /// snapshot at assertion time.
    final class TestObserver: @unchecked Sendable {
        static let shared = TestObserver()

        private let activeCaptures = NIOLockedValueBox<[ObjectIdentifier: CaptureBox]>([:])

        fileprivate func notify(_ event: Event) {
            let boxes = activeCaptures.withLockedValue { Array($0.values) }
            for box in boxes {
                box.append(event)
            }
        }

        func startCapturing() -> CaptureToken {
            let box = CaptureBox()
            let token = CaptureToken(box: box, observer: self)
            activeCaptures.withLockedValue { dict in
                dict[ObjectIdentifier(token)] = box
            }
            return token
        }

        fileprivate func stop(_ token: CaptureToken) {
            activeCaptures.withLockedValue { dict in
                dict[ObjectIdentifier(token)] = nil
            }
        }
    }

    /// RAII handle returned by `startCapturing()`. Read `events` to
    /// snapshot captured events at any time. The capture stops when
    /// the token is deallocated.
    final class CaptureToken: @unchecked Sendable {
        private let box: CaptureBox
        private weak var observer: TestObserver?

        fileprivate init(box: CaptureBox, observer: TestObserver) {
            self.box = box
            self.observer = observer
        }

        deinit {
            observer?.stop(self)
        }

        var events: [Event] {
            box.snapshot()
        }

        /// Drop all events captured so far while keeping the capture
        /// active. Useful in test arrangements that want to focus on
        /// a specific phase.
        func reset() {
            box.reset()
        }
    }

    fileprivate final class CaptureBox: @unchecked Sendable {
        private let storage = NIOLockedValueBox<[Event]>([])

        func append(_ event: Event) {
            storage.withLockedValue { $0.append(event) }
        }

        func snapshot() -> [Event] {
            storage.withLockedValue { $0 }
        }

        func reset() {
            storage.withLockedValue { $0.removeAll() }
        }
    }
}

#endif
