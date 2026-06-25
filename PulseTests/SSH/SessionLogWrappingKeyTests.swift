//
//  SessionLogWrappingKeyTests.swift
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
import XCTest
@testable import Pulse

/// Covers the non-biometric paths through `SessionLogWrappingKey`:
/// lazy generation, idempotent re-load, public-key extraction, and the
/// `(service, account)` Keychain identity.
///
/// The biometric `unwrap(_:with:)` path — where
/// `sharedSecretFromKeyAgreement(with:)` against the SE-resident private
/// key triggers Touch ID — is covered by manual verification because
/// the prompt blocks unattended test runs. The unwrap *algebra* is
/// already pinned by `SessionLogRecordTests.testWrapUnwrapRoundTripWithSoftwareKey`,
/// which uses a software `P256.KeyAgreement.PrivateKey` running the
/// identical CryptoKit code path; this test file pins the SE
/// *lifecycle* (generation, persistence, public-key surface) and
/// confirms `SessionLogCrypto.wrap` can consume the SE-derived public
/// key without biometric.
final class SessionLogWrappingKeyTests: XCTestCase {

    // MARK: - Test lifecycle

    /// Always start with a clean state. The wrapping key is keyed by
    /// `(service: "<bundle-id>.ssh.logwrap", account: "log-wrapping")` —
    /// a single tuple per device. Tests that previously crashed
    /// mid-write would otherwise leave residue that the next test
    /// would either inherit (false positive) or refuse to overwrite
    /// (false negative).
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard SecureEnclave.isAvailable else { return }
        try SessionLogWrappingKey.__deleteForTests()
    }

    override func tearDownWithError() throws {
        if SecureEnclave.isAvailable {
            try SessionLogWrappingKey.__deleteForTests()
        }
        try super.tearDownWithError()
    }

    // MARK: - Lifecycle

    func testLoadOrCreateGeneratesKeyOnFreshInstall() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave not available on this test target")
        }
        XCTAssertFalse(
            SessionLogWrappingKey.__isResidentForTests(),
            "setUp must have left a clean state"
        )

        _ = try SessionLogWrappingKey.loadOrCreate()

        XCTAssertTrue(
            SessionLogWrappingKey.__isResidentForTests(),
            "loadOrCreate must persist a wrapping key to the Keychain"
        )
    }

    func testLoadOrCreateIsIdempotent() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave not available on this test target")
        }

        let first = try SessionLogWrappingKey.loadOrCreate()
        let second = try SessionLogWrappingKey.loadOrCreate()

        // Public-key equality through x963 byte comparison: if
        // loadOrCreate regenerated on the second call, the public keys
        // would differ (CryptoKit gives every SE keypair a unique
        // public half).
        XCTAssertEqual(
            first.publicKey.x963Representation,
            second.publicKey.x963Representation,
            "Two loadOrCreate calls must return the same SE-resident key"
        )
    }

    // MARK: - Integration with SessionLogCrypto.wrap

    func testWrapAcceptsSEDerivedPublicKey() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave not available on this test target")
        }

        // The whole point of the wrapping-key surface: `wrap` can
        // consume the SE-derived public key in the same shape it
        // consumes a software P-256 public key. The actual ECDH
        // happens inside CryptoKit either way; on the wrap side
        // there's no biometric prompt because the SE-side private key
        // doesn't enter the operation.
        let pub = try SessionLogWrappingKey.publicKey()
        let sessionKey = SymmetricKey(size: .bits256)
        let wrapped = try SessionLogCrypto.wrap(sessionKey: sessionKey, to: pub)

        // 65 bytes ephemeral pub + AES.GCM combined (12 nonce + 32 ct + 16 tag = 60).
        let encoded = wrapped.encode()
        XCTAssertEqual(wrapped.ephemeralPublicKeyX963.count, 65)
        XCTAssertEqual(wrapped.ephemeralPublicKeyX963.first, 0x04)
        XCTAssertEqual(encoded.count, 65 + 60)

        // Decode round-trip from the on-disk byte form.
        let decoded = try WrappedSessionKey.decode(encoded)
        XCTAssertEqual(decoded, wrapped)
    }

    // MARK: - Deletion

    func testDeleteIsIdempotent() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave not available on this test target")
        }
        // First delete: nothing resident (setUp wiped). Must not throw.
        XCTAssertNoThrow(try SessionLogWrappingKey.__deleteForTests())

        // Now generate and delete; second delete must also be a no-op.
        _ = try SessionLogWrappingKey.loadOrCreate()
        XCTAssertNoThrow(try SessionLogWrappingKey.__deleteForTests())
        XCTAssertNoThrow(try SessionLogWrappingKey.__deleteForTests())
        XCTAssertFalse(SessionLogWrappingKey.__isResidentForTests())
    }

    func testLoadOrCreateAfterDeleteGeneratesFreshKey() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave not available on this test target")
        }
        let first = try SessionLogWrappingKey.loadOrCreate()
        let firstPub = first.publicKey.x963Representation

        try SessionLogWrappingKey.__deleteForTests()

        let second = try SessionLogWrappingKey.loadOrCreate()
        let secondPub = second.publicKey.x963Representation

        XCTAssertNotEqual(
            firstPub,
            secondPub,
            "A wrapping key generated after delete must be a fresh key — same identity would imply the Keychain ignored the delete"
        )
    }
}
