//
//  CredentialAudit.swift
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

// MARK: - CredentialAudit

/// Typed emitter for the credential lifecycle audit surface defined in
/// ADR §7. Owns the whole `credential.*` namespace: create / import /
/// delete plus the per-credential recording toggle. Mirrors
/// `SessionRecordingAudit`'s shape (typed `Event`, single `emit`
/// chokepoint, DEBUG `TestObserver`) so the two audit surfaces stay
/// consistent while keeping every `credential.*` token in one greppable
/// place.
///
/// Why these events flow through a typed enum rather than free-text
/// `Logger.info` calls at the call sites:
///
/// - **The leading token is the SIEM contract.** ADR §7 names the event
///   by its first whitespace-delimited token. A free-text "Created SE
///   credential <uuid>" line does not match a rule keyed on
///   `credential.created`, so credential create / delete would be
///   invisible to the detection the contract promises. The typed event
///   fixes the token shape at compile time.
/// - **Field sets stay enforced.** `credentialID` and `tier` are part of
///   the case signature, so dropping one is a compile error at the call
///   site rather than a silently-narrowed dashboard downstream.
/// - **One name, one place.** Every `credential.*` token is defined here.
enum CredentialAudit {

    // MARK: - Event

    /// Every `credential.*` audit signal, in one place. Field sets match
    /// the ADR §7 "Audit events" table. The credential label is
    /// deliberately absent: the audit surface carries the stable
    /// `credentialID` and `tier`, not operator-entered free text.
    enum Event: Sendable, Equatable {

        // MARK: Lifecycle (category: ssh.credentials)

        /// A Secure Enclave credential was generated on this device.
        case created(credentialID: UUID, tier: SSHCredentialTier)

        /// A portable (PEM) credential was imported. Distinct from
        /// `created` because importing external key material is a
        /// separate security-relevant action from generating a
        /// non-exportable Secure Enclave key.
        case imported(credentialID: UUID, tier: SSHCredentialTier)

        /// A credential and its secret material were deleted.
        case deleted(credentialID: UUID, tier: SSHCredentialTier)

        // MARK: Recording toggle (category: ssh.credentials)

        case recordingEnabled(credentialID: UUID)
        case recordingDisabled(credentialID: UUID)
    }

    // MARK: - Emit

    private static let logger = Logger(subsystem: "pulse", category: "ssh.credentials")

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
        case let .created(credentialID, tier):
            logger.notice(
                "credential.created credentialID=\(credentialID.uuidString, privacy: .public) tier=\(tier.rawValue, privacy: .public)"
            )
        case let .imported(credentialID, tier):
            logger.notice(
                "credential.imported credentialID=\(credentialID.uuidString, privacy: .public) tier=\(tier.rawValue, privacy: .public)"
            )
        case let .deleted(credentialID, tier):
            logger.notice(
                "credential.deleted credentialID=\(credentialID.uuidString, privacy: .public) tier=\(tier.rawValue, privacy: .public)"
            )
        case let .recordingEnabled(credentialID):
            logger.notice(
                "credential.recording.enabled credentialID=\(credentialID.uuidString, privacy: .public)"
            )
        case let .recordingDisabled(credentialID):
            logger.notice(
                "credential.recording.disabled credentialID=\(credentialID.uuidString, privacy: .public)"
            )
        }
    }
}

// MARK: - Convenience emitters

extension CredentialAudit {

    static func created(credentialID: UUID, tier: SSHCredentialTier) {
        emit(.created(credentialID: credentialID, tier: tier))
    }

    static func imported(credentialID: UUID, tier: SSHCredentialTier) {
        emit(.imported(credentialID: credentialID, tier: tier))
    }

    static func deleted(credentialID: UUID, tier: SSHCredentialTier) {
        emit(.deleted(credentialID: credentialID, tier: tier))
    }

    static func recordingEnabled(credentialID: UUID) {
        emit(.recordingEnabled(credentialID: credentialID))
    }

    static func recordingDisabled(credentialID: UUID) {
        emit(.recordingDisabled(credentialID: credentialID))
    }
}

// MARK: - Test observer

#if DEBUG

extension CredentialAudit {

    /// Captures every emitted event for the lifetime of a
    /// `CaptureToken`, mirroring `SessionRecordingAudit.TestObserver`.
    /// Tests assert on the credential audit signal structurally rather
    /// than scraping `log show`. The token's `deinit` removes the
    /// observer so a leaked token from a misbehaving test doesn't keep
    /// capturing into the next test.
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
    /// snapshot captured events at any time. Capture stops when the token
    /// is deallocated.
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
        /// active. Useful in test arrangements that focus on one phase.
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
