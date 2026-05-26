//
//  SSHHostKeyDelegateTests.swift
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
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest
@testable import Pulse

final class SSHHostKeyDelegateTests: XCTestCase {

    // MARK: - Fixtures

    /// Real ed25519 host key in OpenSSH textual form (same key used to sign the
    /// SSHCertificateManagerTests fixture cert). Its SHA-256 fingerprint
    /// matches `ssh-keygen -l -E sha256`.
    private static let ed25519HostKeyLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPLGQLfTAyBxjYM31zQcBpu5q30wlYwj4/XXk63QC0fG test"
    private static let ed25519HostKeyFingerprint =
        "SHA256:TQzjwzwkjG9iTo2J5mAAhyGgjz2edyUdloeYoS6SxII"

    private static func makeHostKey() throws -> NIOSSHPublicKey {
        try NIOSSHPublicKey(openSSHPublicKey: ed25519HostKeyLine)
    }

    // MARK: - In-memory store

    /// Lightweight `KnownHostStore` mock that lives entirely in memory. Tests
    /// exercise the delegate's decision flow against this without spinning up
    /// a `ModelContainer`. The mock records every write so tests can assert
    /// TOFU side-effects.
    actor InMemoryKnownHostStore: KnownHostStore {
        private var rows: [String: HostTrust] = [:]
        private(set) var pinWrites: [(host: String, port: Int, fingerprint: String, algorithm: String)] = []
        private(set) var touchCount: Int = 0
        private var failNext: Error?

        private func key(_ host: String, _ port: Int) -> String { "\(host):\(port)" }

        func preload(host: String, port: Int, trust: HostTrust) {
            rows[key(host, port)] = trust
        }

        func failNextCall(_ error: Error) { failNext = error }

        func trust(forHost host: String, port: Int) async throws -> HostTrust? {
            if let err = failNext { failNext = nil; throw err }
            return rows[key(host, port)]
        }

        func recordPinned(host: String, port: Int, fingerprintSHA256: String, algorithm: String) async throws {
            if let err = failNext { failNext = nil; throw err }
            pinWrites.append((host, port, fingerprintSHA256, algorithm))
            rows[key(host, port)] = .pinned(fingerprintSHA256: fingerprintSHA256, algorithm: algorithm)
        }

        func touchLastVerified(forHost host: String, port: Int) async throws {
            if let err = failNext { failNext = nil; throw err }
            touchCount += 1
        }
    }

    // MARK: - Pure decision (TOFU + pinned)

    func testEvaluateNoStoredRowReturnsPinAndAccept() throws {
        let hostKey = try Self.makeHostKey()
        let decision = SSHHostKeyDelegate.evaluate(
            recordedTrust: nil,
            hostKey: hostKey,
            presentedFingerprint: Self.ed25519HostKeyFingerprint,
            presentedAlgorithm: "ssh-ed25519",
            host: "10.0.0.1",
            at: .now
        )
        XCTAssertEqual(decision, .pinAndAccept)
    }

    func testEvaluatePinnedMatchReturnsAcceptKnown() throws {
        let hostKey = try Self.makeHostKey()
        let trust = HostTrust.pinned(
            fingerprintSHA256: Self.ed25519HostKeyFingerprint,
            algorithm: "ssh-ed25519"
        )
        let decision = SSHHostKeyDelegate.evaluate(
            recordedTrust: trust,
            hostKey: hostKey,
            presentedFingerprint: Self.ed25519HostKeyFingerprint,
            presentedAlgorithm: "ssh-ed25519",
            host: "10.0.0.1",
            at: .now
        )
        XCTAssertEqual(decision, .acceptKnownPinned)
    }

    func testEvaluatePinnedMismatchReturnsRejectMismatch() throws {
        let hostKey = try Self.makeHostKey()
        let stored = HostTrust.pinned(
            fingerprintSHA256: "SHA256:someotherfingerprintnotthecurrentone",
            algorithm: "ssh-ed25519"
        )
        let decision = SSHHostKeyDelegate.evaluate(
            recordedTrust: stored,
            hostKey: hostKey,
            presentedFingerprint: Self.ed25519HostKeyFingerprint,
            presentedAlgorithm: "ssh-ed25519",
            host: "10.0.0.1",
            at: .now
        )
        guard case .rejectMismatch(let recorded) = decision else {
            return XCTFail("expected rejectMismatch, got \(decision)")
        }
        XCTAssertEqual(recorded, "SHA256:someotherfingerprintnotthecurrentone")
    }

    func testEvaluateExplicitlyDistrustedRejects() throws {
        let hostKey = try Self.makeHostKey()
        let trust = HostTrust.explicitlyDistrusted(
            reason: "rotated unexpectedly 2026-02; pending investigation",
            recordedAt: .now
        )
        let decision = SSHHostKeyDelegate.evaluate(
            recordedTrust: trust,
            hostKey: hostKey,
            presentedFingerprint: Self.ed25519HostKeyFingerprint,
            presentedAlgorithm: "ssh-ed25519",
            host: "10.0.0.1",
            at: .now
        )
        guard case .rejectDistrusted(let reason) = decision else {
            return XCTFail("expected rejectDistrusted, got \(decision)")
        }
        XCTAssertTrue(reason.contains("rotated"))
    }

    // MARK: - trustedCA evaluation

    /// trustedCA rows demand a NIOSSHCertifiedPublicKey, not a bare host key.
    /// A server presenting a plain key against a trustedCA row is rejected.
    func testEvaluateTrustedCARejectsPlainKey() throws {
        let hostKey = try Self.makeHostKey()
        let trust = HostTrust.trustedCA(
            caFingerprintSHA256: "SHA256:somecafingerprint",
            principalPattern: "*"
        )
        let decision = SSHHostKeyDelegate.evaluate(
            recordedTrust: trust,
            hostKey: hostKey,
            presentedFingerprint: Self.ed25519HostKeyFingerprint,
            presentedAlgorithm: "ssh-ed25519",
            host: "host.example",
            at: .now
        )
        guard case .rejectCA(let reason) = decision else {
            return XCTFail("expected rejectCA, got \(decision)")
        }
        XCTAssertTrue(reason.contains("plain public key"))
    }

    // MARK: - trustedCA happy path

    /// Cert fixture matching the validity window 2026-01-01..2027-01-01 UTC
    /// (same as SSHCertificateManagerTests). The CA fingerprint matches the
    /// signing key whose textual form is the bare ed25519 line used as the
    /// host key elsewhere in this file.
    private static let trustedCACertLine =
        "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIO2NpWp2GzVdTRyvDC2W+E5COaW7uwEG3SMWA8wlwqLLAAAAICS+cdNe6n0ehPqpDUEjTO5Tvk3rK0r8ynWfI35yyoKFAAAAAAAAACoAAAABAAAACmFsaWNlLTIwMjYAAAAQAAAABWFsaWNlAAAAA2JvYgAAAABpVRBAAAAAAGs2Q8AAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAMwAAAAtzc2gtZWQyNTUxOQAAACDyxkC30wMgcY2DN9c0HAabuat9MJWMI+P115Ot0AtHxgAAAFMAAAALc3NoLWVkMjU1MTkAAABA8TtmctNwenUM8cxigRWSosgbHfa7ggZZ7fgIhj1Idu4NdrkmWnmLTbAivvea5biv+Px5g/W2Y4h8fLx94J8RCQ== test user"

    /// Trusted-CA happy path: presented cert is signed by the stored CA
    /// fingerprint, current time is inside the validity window, and the
    /// requested host matches one of the cert's validPrincipals. The
    /// evaluator returns `.acceptCA` (cert validates, fingerprint matches,
    /// principals cover host).
    func testEvaluateTrustedCAAcceptsValidCertWithMatchingPrincipal() throws {
        let certKey = try NIOSSHPublicKey(openSSHPublicKey: Self.trustedCACertLine)
        let stored = HostTrust.trustedCA(
            caFingerprintSHA256: Self.ed25519HostKeyFingerprint,
            principalPattern: "alice"
        )
        // 2026-05-25 UTC falls within the 2026-01-01..2027-01-01 window.
        let inside = Date(timeIntervalSince1970: 1782_000_000)

        let decision = SSHHostKeyDelegate.evaluate(
            recordedTrust: stored,
            hostKey: certKey,
            presentedFingerprint: "SHA256:irrelevant-for-CA-path",
            presentedAlgorithm: "ssh-ed25519-cert-v01@openssh.com",
            host: "alice",
            at: inside
        )

        guard case .acceptCA(let ca, let pattern) = decision else {
            return XCTFail("expected acceptCA, got \(decision)")
        }
        XCTAssertEqual(ca, Self.ed25519HostKeyFingerprint)
        XCTAssertEqual(pattern, "alice")
    }

    /// Same cert, after expiry: rejected with a clear reason.
    func testEvaluateTrustedCARejectsExpiredCert() throws {
        let certKey = try NIOSSHPublicKey(openSSHPublicKey: Self.trustedCACertLine)
        let stored = HostTrust.trustedCA(
            caFingerprintSHA256: Self.ed25519HostKeyFingerprint,
            principalPattern: "alice"
        )
        let after = Date(timeIntervalSince1970: 1893_456_000) // ~2030

        let decision = SSHHostKeyDelegate.evaluate(
            recordedTrust: stored,
            hostKey: certKey,
            presentedFingerprint: "SHA256:irrelevant",
            presentedAlgorithm: "ssh-ed25519-cert-v01@openssh.com",
            host: "alice",
            at: after
        )

        guard case .rejectCA(let reason) = decision else {
            return XCTFail("expected rejectCA, got \(decision)")
        }
        XCTAssertTrue(reason.contains("validity"))
    }

    // MARK: - Delegate integration via EmbeddedEventLoop

    /// TOFU happy path: no row stored, delegate succeeds the promise and
    /// writes a `.pinned` row carrying the presented fingerprint and the
    /// algorithm name extracted from the OpenSSH textual form.
    func testValidateHostKeyTOFUWritesPinnedRow() async throws {
        let store = InMemoryKnownHostStore()
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let delegate = SSHHostKeyDelegate(host: "10.0.0.7", port: 22, store: store)
        let promise = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: try Self.makeHostKey(), validationCompletePromise: promise)

        try await promise.futureResult.get()
        let writes = await store.pinWrites
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.host, "10.0.0.7")
        XCTAssertEqual(writes.first?.port, 22)
        XCTAssertEqual(writes.first?.fingerprint, Self.ed25519HostKeyFingerprint)
        XCTAssertEqual(writes.first?.algorithm, "ssh-ed25519")
    }

    /// Mismatch path: the stored fingerprint differs from the presented key.
    /// The delegate fails the promise with `.fingerprintMismatch` and does NOT
    /// write a new pin (no UI acceptance sheet in the current build).
    func testValidateHostKeyMismatchRejects() async throws {
        let store = InMemoryKnownHostStore()
        await store.preload(
            host: "10.0.0.7",
            port: 22,
            trust: .pinned(
                fingerprintSHA256: "SHA256:somestoredfingerprintnotmatching",
                algorithm: "ssh-ed25519"
            )
        )
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let delegate = SSHHostKeyDelegate(host: "10.0.0.7", port: 22, store: store)
        let promise = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: try Self.makeHostKey(), validationCompletePromise: promise)

        do {
            try await promise.futureResult.get()
            XCTFail("expected promise to fail with fingerprintMismatch")
        } catch let error as SSHHostKeyError {
            guard case .fingerprintMismatch(let recorded, let presented) = error else {
                return XCTFail("expected fingerprintMismatch, got \(error)")
            }
            XCTAssertEqual(recorded, "SHA256:somestoredfingerprintnotmatching")
            XCTAssertEqual(presented, Self.ed25519HostKeyFingerprint)
        }
        let writes = await store.pinWrites
        XCTAssertEqual(writes.count, 0, "mismatch path must not pin a new row")
    }

    /// Known-and-matching pin: the delegate succeeds the promise and touches
    /// `lastVerifiedAt` exactly once. No new pin write.
    func testValidateHostKeyKnownPinTouchesLastVerified() async throws {
        let store = InMemoryKnownHostStore()
        await store.preload(
            host: "10.0.0.7",
            port: 22,
            trust: .pinned(
                fingerprintSHA256: Self.ed25519HostKeyFingerprint,
                algorithm: "ssh-ed25519"
            )
        )
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let delegate = SSHHostKeyDelegate(host: "10.0.0.7", port: 22, store: store)
        let promise = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: try Self.makeHostKey(), validationCompletePromise: promise)

        try await promise.futureResult.get()
        let writes = await store.pinWrites
        let touches = await store.touchCount
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(touches, 1)
    }
}
