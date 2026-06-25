//
//  SecureEnclaveKeyManagerTests.swift
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
import Security
import XCTest
@testable import Pulse

/// Tests that exercise real Secure Enclave hardware. All cases skip if
/// `SecureEnclave.isAvailable` reports the SE missing (Intel Macs without T2,
/// some CI runners). On Apple Silicon they run unattended: generation and
/// public-key derivation don't require user presence, only signing does.
final class SecureEnclaveKeyManagerTests: XCTestCase {

    // MARK: - CryptoKit dataRepresentation contract

    /// The structural non-exportability claim in ADR 0001 §1: SE private keys
    /// cannot be extracted. Under the previous SecKey-based path this was verified by
    /// `SecKeyCopyExternalRepresentation` returning `nil` on the private half.
    /// Under the CryptoKit-based path (CryptoKit's
    /// `SecureEnclave.P256.Signing.PrivateKey`), the guarantee is stronger and
    /// compile-time: the type exposes no API that returns the raw private
    /// scalar. `dataRepresentation` is an SE-encrypted blob that only this
    /// device's SE can unwrap.
    ///
    /// This test pins the positive contract — the dataRepresentation
    /// round-trips byte-correctly and produces an equivalent key — replacing
    /// the negative "the API returns nil" assertion. The compile-time
    /// guarantee is implicit; you can't write a runtime test for an API that
    /// doesn't exist.
    func testDataRepresentationRoundTripPreservesPublicKey() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave not available on this test target")
        }

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny, .or, .devicePasscode],
            &accessError
        ) else {
            return XCTFail("SecAccessControlCreateWithFlags: \(String(describing: accessError?.takeRetainedValue()))")
        }

        let key1 = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let blob = key1.dataRepresentation
        let key2 = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)

        XCTAssertEqual(
            key1.publicKey.x963Representation,
            key2.publicKey.x963Representation,
            "dataRepresentation round-trip must preserve the public key"
        )

        // The blob must be substantially larger than a bare P-256 private
        // scalar (32 bytes). A weak structural check that the blob is the
        // SE-wrapped form rather than the unwrapped key material.
        XCTAssertGreaterThan(blob.count, 64, "dataRepresentation looks suspiciously small for an SE-wrapped key")
    }

    // MARK: - SecureEnclaveKeyManager end-to-end

    /// generateKey -> openSSHPublicKeyWireFormat round-trip via the Keychain.
    /// Verifies that the wire-format public key emitted at generation time
    /// matches what a fresh read returns. This is the contract the credential
    /// editor relies on for fingerprint display continuity.
    func testGenerateAndReadBackProducesIdenticalWireBytes() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave not available on this test target")
        }

        let credentialID = UUID()
        defer { try? SecureEnclaveKeyManager.deleteKey(for: credentialID) }

        let wireAtGeneration = try SecureEnclaveKeyManager.generateKey(
            for: credentialID,
            label: "Pulse test \(credentialID.uuidString.prefix(8))"
        )
        let wireFromKeychain = try SecureEnclaveKeyManager.openSSHPublicKeyWireFormat(for: credentialID)
        XCTAssertEqual(wireAtGeneration, wireFromKeychain)
        // RFC 5656 §3.1 fixed shape: 4 + 19 ("ecdsa-sha2-nistp256")
        //                          + 4 + 8  ("nistp256")
        //                          + 4 + 65 (SEC1 uncompressed point)
        //                          = 104 bytes total.
        XCTAssertEqual(wireAtGeneration.count, 104)
    }

    /// resident() enumeration must surface a freshly-generated credential's
    /// UUID. Failure here means a future "orphan detection" UI would miss
    /// real SE-resident credentials.
    func testResidentEnumerationIncludesFreshKey() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave not available on this test target")
        }

        let credentialID = UUID()
        defer { try? SecureEnclaveKeyManager.deleteKey(for: credentialID) }

        _ = try SecureEnclaveKeyManager.generateKey(for: credentialID, label: "Pulse test resident")
        XCTAssertTrue(
            SecureEnclaveKeyManager.resident().contains(credentialID),
            "resident() should list the freshly-generated credential"
        )
    }

    /// deleteKey is idempotent: deleting a key that doesn't exist must not
    /// throw. The credential-editor delete flow relies on this for retry
    /// safety (errSecItemNotFound is treated as success).
    func testDeleteIsIdempotent() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave not available on this test target")
        }

        let credentialID = UUID()
        // Never generated, never stored. Delete should still succeed.
        XCTAssertNoThrow(try SecureEnclaveKeyManager.deleteKey(for: credentialID))
        // Second delete is also a no-op.
        XCTAssertNoThrow(try SecureEnclaveKeyManager.deleteKey(for: credentialID))
    }
}
