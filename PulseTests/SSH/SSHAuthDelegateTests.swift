//
//  SSHAuthDelegateTests.swift
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

import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest
@testable import Pulse

final class SSHAuthDelegateTests: XCTestCase {

    // MARK: - Fixtures

    /// Cert fixture from SSHCertificateManagerTests (re-used so the validity
    /// window, principals, and CA fingerprint match a single set of expected
    /// values across the SSH test suite).
    private static let certLine =
        "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIO2NpWp2GzVdTRyvDC2W+E5COaW7uwEG3SMWA8wlwqLLAAAAICS+cdNe6n0ehPqpDUEjTO5Tvk3rK0r8ynWfI35yyoKFAAAAAAAAACoAAAABAAAACmFsaWNlLTIwMjYAAAAQAAAABWFsaWNlAAAAA2JvYgAAAABpVRBAAAAAAGs2Q8AAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAMwAAAAtzc2gtZWQyNTUxOQAAACDyxkC30wMgcY2DN9c0HAabuat9MJWMI+P115Ot0AtHxgAAAFMAAAALc3NoLWVkMjU1MTkAAABA8TtmctNwenUM8cxigRWSosgbHfa7ggZZ7fgIhj1Idu4NdrkmWnmLTbAivvea5biv+Px5g/W2Y4h8fLx94J8RCQ== test user"

    /// Inside the fixture cert's validity window (2026-01-01..2027-01-01 UTC).
    private static let withinValidityWindow = Date(timeIntervalSince1970: 1782_000_000) // ~mid-2026

    /// After the fixture cert's validBefore.
    private static let afterValidityWindow = Date(timeIntervalSince1970: 1893_456_000) // ~2030

    private static let certBlob = Data(certLine.utf8)

    /// Real Ed25519 OpenSSH new-format key from the importer-tests fixture set.
    /// Used to drive the portable-tier path through `buildPortablePrivateKey`.
    private static let ed25519PortablePEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACCj/9wicULN0JBMfFGX5JlXpYlwsqF7y+JywL7kAyK4FAAAAJAzScE0M0nB
    NAAAAAtzc2gtZWQyNTUxOQAAACCj/9wicULN0JBMfFGX5JlXpYlwsqF7y+JywL7kAyK4FA
    AAAEBMtaTqL5dFDf7h6/SNwakBKGHKy0yIzadn6f3s1PkAZ6P/3CJxQs3QkEx8UZfkmVel
    iXCyoXvL4nLAvuQDIrgUAAAACnRlc3RAcHVsc2UBZZZZ=
    -----END OPENSSH PRIVATE KEY-----
    """

    /// In-process P-256 traditional PEM. Generated fresh per test (one keypair
    /// per call) so the test doesn't depend on a corrupted-tail fixture that
    /// CryptoKit's pemRepresentation init would reject.
    private func freshP256PEM() -> String {
        P256.Signing.PrivateKey().pemRepresentation
    }

    private func freshP384PEM() -> String {
        P384.Signing.PrivateKey().pemRepresentation
    }

    private func freshP521PEM() -> String {
        P521.Signing.PrivateKey().pemRepresentation
    }

    // MARK: - Portable private-key builder

    func testBuildPortablePrivateKey_Ed25519_OpenSSHNewFormat() throws {
        let key = try SSHAuthDelegate.buildPortablePrivateKey(fromPEM: Self.ed25519PortablePEM)
        let pubText = String(openSSHPublicKey: key.publicKey)
        XCTAssertTrue(pubText.hasPrefix("ssh-ed25519 "))
    }

    func testBuildPortablePrivateKey_P256_TraditionalPEMInit() throws {
        let pem = freshP256PEM()
        let key = try SSHAuthDelegate.buildPortablePrivateKey(fromPEM: pem)
        let pubText = String(openSSHPublicKey: key.publicKey)
        XCTAssertTrue(pubText.hasPrefix("ecdsa-sha2-nistp256 "))
    }

    func testBuildPortablePrivateKey_P384_TraditionalPEMInit() throws {
        let pem = freshP384PEM()
        let key = try SSHAuthDelegate.buildPortablePrivateKey(fromPEM: pem)
        let pubText = String(openSSHPublicKey: key.publicKey)
        XCTAssertTrue(pubText.hasPrefix("ecdsa-sha2-nistp384 "))
    }

    func testBuildPortablePrivateKey_P521_TraditionalPEMInit() throws {
        let pem = freshP521PEM()
        let key = try SSHAuthDelegate.buildPortablePrivateKey(fromPEM: pem)
        let pubText = String(openSSHPublicKey: key.publicKey)
        XCTAssertTrue(pubText.hasPrefix("ecdsa-sha2-nistp521 "))
    }

    func testBuildPortablePrivateKey_NonPEMInput_Throws() {
        XCTAssertThrowsError(
            try SSHAuthDelegate.buildPortablePrivateKey(fromPEM: "not a pem")
        ) { error in
            guard case SSHAuthDelegateError.unsupportedPortableKeyFormat = error else {
                return XCTFail("expected unsupportedPortableKeyFormat, got \(error)")
            }
        }
    }

    // MARK: - Offer flow (portable, no cert)

    private func makeDelegate(
        certificateBlob: Data? = nil,
        now: Date = SSHAuthDelegateTests.withinValidityWindow
    ) -> SSHAuthDelegate {
        SSHAuthDelegate(
            username: "alice",
            host: "10.0.0.1",
            port: 22,
            credentialID: UUID(),
            tier: .portable,
            certificateBlob: certificateBlob,
            pemProvider: { Data(Self.ed25519PortablePEM.utf8) },
            now: { now }
        )
    }

    func testFirstOfferIsBareKeyWhenNoCert() async throws {
        let delegate = makeDelegate(certificateBlob: nil)
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(
            availableMethods: .publicKey,
            nextChallengePromise: promise
        )
        let offer = try await promise.futureResult.get()

        guard let offer else {
            return XCTFail("expected an offer on first call")
        }
        guard case .privateKey(let privateKeyOffer) = offer.offer else {
            return XCTFail("expected .privateKey offer, got \(offer.offer)")
        }
        // No cert: the public key in the offer is the bare Ed25519 key.
        let pubText = String(openSSHPublicKey: privateKeyOffer.publicKey)
        XCTAssertTrue(pubText.hasPrefix("ssh-ed25519 "))
        XCTAssertFalse(delegate.didOfferCertificate)
    }

    func testSecondOfferIsNilWhenStartedWithBareKey() async throws {
        let delegate = makeDelegate(certificateBlob: nil)
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        // First call: returns bare key (consumed).
        let p1 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: p1)
        _ = try await p1.futureResult.get()

        // Second call: out of offers, returns nil (auth.failure emission).
        let p2 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: p2)
        let offer = try await p2.futureResult.get()
        XCTAssertNil(offer)
    }

    // MARK: - Offer flow (portable, with cert)

    func testFirstOfferPresentsCertWhenValid() async throws {
        let delegate = makeDelegate(certificateBlob: Self.certBlob)
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: promise)
        let offer = try await promise.futureResult.get()

        guard let offer, case .privateKey(let privateKeyOffer) = offer.offer else {
            return XCTFail("expected .privateKey offer")
        }
        // When a cert is presented, the offer's publicKey is the cert (wrapped
        // back into a NIOSSHPublicKey) — its prefix is the cert algorithm
        // identifier, not the bare key's.
        let pubText = String(openSSHPublicKey: privateKeyOffer.publicKey)
        XCTAssertTrue(pubText.hasPrefix("ssh-ed25519-cert-v01@openssh.com "))
        XCTAssertTrue(delegate.didOfferCertificate)
    }

    func testCertExpiredFallsBackToBareKey() async throws {
        let delegate = makeDelegate(
            certificateBlob: Self.certBlob,
            now: Self.afterValidityWindow
        )
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: promise)
        let offer = try await promise.futureResult.get()

        guard let offer, case .privateKey(let privateKeyOffer) = offer.offer else {
            return XCTFail("expected .privateKey offer")
        }
        // Expired cert: delegate falls back to the bare key. The offer's
        // public key is the bare Ed25519, not the cert.
        let pubText = String(openSSHPublicKey: privateKeyOffer.publicKey)
        XCTAssertTrue(pubText.hasPrefix("ssh-ed25519 "))
        XCTAssertFalse(pubText.hasPrefix("ssh-ed25519-cert-v01"))
        XCTAssertFalse(delegate.didOfferCertificate)
    }

    func testSecondOfferIsBareKeyAfterCertOfferedFirst() async throws {
        let delegate = makeDelegate(certificateBlob: Self.certBlob)
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        // First call: cert.
        let p1 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: p1)
        _ = try await p1.futureResult.get()
        XCTAssertTrue(delegate.didOfferCertificate)

        // Second call: bare key (cert.rejected emission).
        let p2 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: p2)
        let offer = try await p2.futureResult.get()
        guard let offer, case .privateKey(let privateKeyOffer) = offer.offer else {
            return XCTFail("expected .privateKey offer on second call")
        }
        let pubText = String(openSSHPublicKey: privateKeyOffer.publicKey)
        XCTAssertTrue(pubText.hasPrefix("ssh-ed25519 "))
        XCTAssertFalse(pubText.hasPrefix("ssh-ed25519-cert-v01"))
    }

    func testThirdOfferIsNilAfterCertAndBareBothExhausted() async throws {
        let delegate = makeDelegate(certificateBlob: Self.certBlob)
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let p1 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: p1)
        _ = try await p1.futureResult.get()

        let p2 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: p2)
        _ = try await p2.futureResult.get()

        let p3 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: p3)
        let offer = try await p3.futureResult.get()
        XCTAssertNil(offer)
    }

    // MARK: - Portable PEM unavailable

    func testPortableCredentialWithMissingPEMFails() async throws {
        let delegate = SSHAuthDelegate(
            username: "alice",
            host: "10.0.0.1",
            port: 22,
            credentialID: UUID(),
            tier: .portable,
            certificateBlob: nil,
            pemProvider: { nil },  // PEM not available
            now: { .now }
        )
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: promise)
        do {
            _ = try await promise.futureResult.get()
            XCTFail("expected portablePEMUnavailable")
        } catch let error as SSHAuthDelegateError {
            guard case .portablePEMUnavailable = error else {
                return XCTFail("expected portablePEMUnavailable, got \(error)")
            }
        }
    }

    /// One-shot latch contract: once a key-load failure has fired
    /// `auth.failure`, subsequent `nextAuthenticationType` callbacks return
    /// `nil` immediately without re-emitting. NIOSSH retries
    /// `nextAuthenticationType` after a rejected offer; without the latch,
    /// a portable-PEM-unavailable failure on attempt 1 would re-throw on
    /// attempt 2 and double-log the same failure under the operator's
    /// single connection attempt.
    ///
    /// Direct log-emission counting is awkward without an `OSLog` mock;
    /// the structural check here is the promise-resolution shape:
    /// attempt 1 fails with `portablePEMUnavailable`, attempt 2 succeeds
    /// with a `nil` offer (the latched short-circuit, no throw). Manual
    /// `log show` verification covers the "no second emission" claim.
    func testLoadFailureLatchesAfterFirstAttempt() async throws {
        let delegate = SSHAuthDelegate(
            username: "alice",
            host: "10.0.0.1",
            port: 22,
            credentialID: UUID(),
            tier: .portable,
            certificateBlob: nil,
            pemProvider: { nil },
            now: { .now }
        )
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        // Attempt 1: pemProvider returns nil → loadPrivateKey throws →
        // computeNextOffer rethrows → catch latches _loadFailed and fails
        // the promise with portablePEMUnavailable.
        let p1 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: p1)
        do {
            _ = try await p1.futureResult.get()
            return XCTFail("attempt 1 should have thrown portablePEMUnavailable")
        } catch let error as SSHAuthDelegateError {
            guard case .portablePEMUnavailable = error else {
                return XCTFail("expected portablePEMUnavailable on attempt 1, got \(error)")
            }
        }

        // Attempt 2: the latch fires; computeNextOffer returns nil without
        // calling loadPrivateKey again, so the promise resolves to nil-
        // success rather than failing again.
        let p2 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: p2)
        let secondOffer = try await p2.futureResult.get()
        XCTAssertNil(secondOffer, "second callback should short-circuit to nil under the latch")
    }
}
