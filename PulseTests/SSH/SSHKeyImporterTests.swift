//
//  SSHKeyImporterTests.swift
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
import XCTest
@testable import Pulse

final class SSHKeyImporterTests: XCTestCase {

    // MARK: - OpenSSH new-format

    func testOpenSSHEd25519Unencrypted() throws {
        let result = try SSHKeyImporter.validate(fixtureOpenSSHEd25519Unenc)
        XCTAssertEqual(result.pemKind, .opensshPrivate)
        XCTAssertEqual(result.algorithm, .ed25519)
        XCTAssertFalse(result.isEncrypted)
    }

    /// Encrypted OpenSSH new-format keys are rejected at the front door per
    /// the v1 import scope (bcrypt-pbkdf is the KDF we'd have to roll
    /// in-house against §10). The classifier reads cipher name first, so the
    /// algorithm-identification path is bypassed entirely.
    func testOpenSSHEd25519EncryptedIsRejected() {
        XCTAssertThrowsError(try SSHKeyImporter.validate(fixtureOpenSSHEd25519Enc)) { error in
            guard case SSHKeyImporter.ImporterError.encryptedPortableKeyNotSupportedInV1 = error else {
                return XCTFail("expected encryptedPortableKeyNotSupportedInV1, got \(error)")
            }
        }
    }

    func testOpenSSHEcdsaP256() throws {
        let result = try SSHKeyImporter.validate(fixtureOpenSSHEcdsaP256)
        XCTAssertEqual(result.pemKind, .opensshPrivate)
        XCTAssertEqual(result.algorithm, .ecdsaP256)
        XCTAssertFalse(result.isEncrypted)
    }

    // MARK: - Traditional and PKCS#8

    /// Traditional `BEGIN EC PRIVATE KEY` PEMs don't expose the curve in the armor,
    /// only in the SEC1 ASN.1 payload (which the importer doesn't decode). The
    /// classifier must surface `.ecdsaUnknownCurve` rather than incorrectly claiming
    /// P-256. Regression guard for the EC-curve-detection fix.
    func testTraditionalECPEMSurfacesUnknownCurve() throws {
        let result = try SSHKeyImporter.validate(fixtureTraditionalECDSAP256)
        XCTAssertEqual(result.pemKind, .ecPrivate)
        XCTAssertEqual(result.algorithm, .ecdsaUnknownCurve)
        XCTAssertFalse(result.isEncrypted)
    }

    // MARK: - v1 portable scope (ADR §1 amendment)

    /// RSA is rejected at the front door per the v1 import scope.
    /// `swift-nio-ssh` 0.13.0 (+ main) has no RSA private-key signing path;
    /// accepting RSA at import would create credentials that fail at first
    /// use. The error carries operator-facing remediation pointing at
    /// Ed25519 / ECDSA / Secure Enclave.
    func testRSATraditionalIsRejectedWithRemediation() {
        XCTAssertThrowsError(try SSHKeyImporter.validate(fixtureRSA1024PKCS1)) { error in
            guard case SSHKeyImporter.ImporterError.unsupportedAlgorithmInV1(let name, let remediation) = error else {
                return XCTFail("expected unsupportedAlgorithmInV1, got \(error)")
            }
            XCTAssertEqual(name, "RSA")
            XCTAssertTrue(remediation.contains("ssh-keygen"))
        }
    }

    // MARK: - Error paths

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try SSHKeyImporter.validate("   \n\t   ")) { error in
            guard let importerError = error as? SSHKeyImporter.ImporterError,
                  case .empty = importerError else {
                XCTFail("Expected ImporterError.empty, got \(error)")
                return
            }
        }
    }

    func testDSARejectedAsUnsupported() {
        XCTAssertThrowsError(try SSHKeyImporter.validate(fixtureDSA)) { error in
            guard let importerError = error as? SSHKeyImporter.ImporterError,
                  case .unsupportedKeyKind(let kind) = importerError,
                  kind == .dsaPrivate else {
                XCTFail("Expected unsupportedKeyKind(.dsaPrivate), got \(error)")
                return
            }
        }
    }

    /// CRLF line endings are common on Windows-originated PEMs and copy-pastes from
    /// some clients. The importer normalises to LF so downstream consumers see a
    /// canonical form.
    func testCRLFLineEndingsNormaliseCorrectly() throws {
        let crlf = fixtureOpenSSHEd25519Unenc.replacingOccurrences(of: "\n", with: "\r\n")
        let result = try SSHKeyImporter.validate(crlf)
        XCTAssertEqual(result.algorithm, .ed25519)
        XCTAssertTrue(result.normalisedPEM.contains("\n"))
        XCTAssertFalse(result.normalisedPEM.contains("\r\n"))
    }

    // MARK: - Public-key derivation

    /// OpenSSH new-format Ed25519: the public-key blob is already SSH
    /// wire-format inside the payload. Derivation extracts it byte-for-byte.
    /// Expected: 4-byte length prefix + "ssh-ed25519" (11) + 4-byte length +
    /// 32-byte point = 51 bytes.
    func testDerivePublicKeyFromOpenSSHEd25519() throws {
        let imported = try SSHKeyImporter.validate(fixtureOpenSSHEd25519Unenc)
        let publicKey = try SSHKeyImporter.derivePublicKey(from: imported)
        let prefix: [UInt8] = [
            0x00, 0x00, 0x00, 0x0B,
            0x73, 0x73, 0x68, 0x2D,
            0x65, 0x64, 0x32, 0x35, 0x35, 0x31, 0x39
        ]
        XCTAssertEqual(publicKey.prefix(prefix.count), Data(prefix))
        XCTAssertEqual(publicKey.count, 51)
    }

    /// Traditional EC PEMs need SEC1 decoding; not implemented in v1.
    /// Derivation raises notSupported so the credential creates with an empty
    /// public-key placeholder and the auth delegate backfills.
    func testDerivePublicKeyTraditionalECNotSupported() {
        guard let imported = try? SSHKeyImporter.validate(fixtureTraditionalECDSAP256) else {
            return XCTFail("fixture failed to validate")
        }
        XCTAssertThrowsError(try SSHKeyImporter.derivePublicKey(from: imported)) { error in
            guard case SSHKeyImporter.ImporterError.publicKeyDerivationNotSupported = error else {
                return XCTFail("expected publicKeyDerivationNotSupported, got \(error)")
            }
        }
    }

    // MARK: - OpenSSH new-format private-key decoder

    /// Round-trip contract: the seed the decoder extracts from an Ed25519
    /// OpenSSH new-format payload must derive the same public key the
    /// `derivePublicKey` helper extracts from the same payload's public blob.
    /// Two derivation paths through CryptoKit and through wire-format
    /// extraction land on byte-identical bytes for the same key.
    func testDecodeOpenSSHEd25519SeedRoundTripsToPublic() throws {
        let imported = try SSHKeyImporter.validate(fixtureOpenSSHEd25519Unenc)
        let decoded = try SSHKeyImporter.decodeOpenSSHPrivateKey(from: imported.normalisedPEM)
        guard case .ed25519(let seed) = decoded else {
            return XCTFail("expected .ed25519, got \(decoded)")
        }
        XCTAssertEqual(seed.count, 32)

        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let cryptoPub = key.publicKey.rawRepresentation
        let wirePub = try SSHKeyImporter.derivePublicKey(from: imported)
        // wirePub trailing 32 bytes are the public-key point.
        XCTAssertEqual(Data(wirePub.suffix(32)), cryptoPub)
    }

    /// Same contract for ECDSA P-256: the scalar the decoder extracts must
    /// produce a public key that matches the wire-format public blob.
    func testDecodeOpenSSHEcdsaP256ScalarRoundTripsToPublic() throws {
        let imported = try SSHKeyImporter.validate(fixtureOpenSSHEcdsaP256)
        let decoded = try SSHKeyImporter.decodeOpenSSHPrivateKey(from: imported.normalisedPEM)
        guard case .ecdsaP256(let scalar) = decoded else {
            return XCTFail("expected .ecdsaP256, got \(decoded)")
        }
        XCTAssertEqual(scalar.count, 32)

        let key = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        let cryptoPub = key.publicKey.x963Representation  // 65 bytes: 0x04 || X || Y
        let wirePub = try SSHKeyImporter.derivePublicKey(from: imported)
        XCTAssertEqual(Data(wirePub.suffix(65)), cryptoPub)
    }

    func testDecodeOpenSSHEcdsaP384ScalarRoundTripsToPublic() throws {
        let imported = try SSHKeyImporter.validate(fixtureOpenSSHEcdsaP384)
        let decoded = try SSHKeyImporter.decodeOpenSSHPrivateKey(from: imported.normalisedPEM)
        guard case .ecdsaP384(let scalar) = decoded else {
            return XCTFail("expected .ecdsaP384, got \(decoded)")
        }
        XCTAssertEqual(scalar.count, 48)

        let key = try P384.Signing.PrivateKey(rawRepresentation: scalar)
        let cryptoPub = key.publicKey.x963Representation  // 97 bytes: 0x04 || X || Y
        let wirePub = try SSHKeyImporter.derivePublicKey(from: imported)
        XCTAssertEqual(Data(wirePub.suffix(97)), cryptoPub)
    }

    func testDecodeOpenSSHEcdsaP521ScalarRoundTripsToPublic() throws {
        let imported = try SSHKeyImporter.validate(fixtureOpenSSHEcdsaP521)
        let decoded = try SSHKeyImporter.decodeOpenSSHPrivateKey(from: imported.normalisedPEM)
        guard case .ecdsaP521(let scalar) = decoded else {
            return XCTFail("expected .ecdsaP521, got \(decoded)")
        }
        XCTAssertEqual(scalar.count, 66)

        let key = try P521.Signing.PrivateKey(rawRepresentation: scalar)
        let cryptoPub = key.publicKey.x963Representation  // 133 bytes: 0x04 || X || Y
        let wirePub = try SSHKeyImporter.derivePublicKey(from: imported)
        XCTAssertEqual(Data(wirePub.suffix(133)), cryptoPub)
    }

    /// Encrypted OpenSSH new-format keys are rejected by the decoder via the
    /// `.encrypted` error before any private-section walk runs. (The
    /// importer's `validate` already rejects them at the front door; the
    /// decoder's own gate is belt-and-braces in case a caller bypasses
    /// `validate`.)
    func testDecodeOpenSSHEncryptedRejects() {
        XCTAssertThrowsError(try SSHKeyImporter.decodeOpenSSHPrivateKey(from: fixtureOpenSSHEd25519Enc)) { error in
            guard case SSHKeyImporter.OpenSSHDecodeError.encrypted = error else {
                return XCTFail("expected OpenSSHDecodeError.encrypted, got \(error)")
            }
        }
    }

    func testDecodeOpenSSHRejectsNonOpenSSHFormat() {
        XCTAssertThrowsError(try SSHKeyImporter.decodeOpenSSHPrivateKey(from: fixtureTraditionalECDSAP256)) { error in
            guard case SSHKeyImporter.OpenSSHDecodeError.notOpenSSHNewFormat = error else {
                return XCTFail("expected OpenSSHDecodeError.notOpenSSHNewFormat, got \(error)")
            }
        }
    }
}

// MARK: - Fixtures
//
// Generated once with ssh-keygen / openssl, then deliberately corrupted at the tail
// of each PEM body so the keys are structurally valid (the importer's classifier
// exercises against real OpenSSH armor) but cryptographically invalid (the keys
// cannot be used to authenticate against anything). This keeps real key material
// out of the repository while preserving the test surface.
//
// The corruption is applied to the trailing 4 base64 characters of each body. The
// classifier reads from the start of the OpenSSH new-format payload (cipher name,
// kdf name, public-blob algorithm identifier) and never touches the tail; the
// traditional / PKCS#8 / DSA paths don't decode the body at all.

private let fixtureOpenSSHEd25519Unenc = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCj/9wicULN0JBMfFGX5JlXpYlwsqF7y+JywL7kAyK4FAAAAJAzScE0M0nB
NAAAAAtzc2gtZWQyNTUxOQAAACCj/9wicULN0JBMfFGX5JlXpYlwsqF7y+JywL7kAyK4FA
AAAEBMtaTqL5dFDf7h6/SNwakBKGHKy0yIzadn6f3s1PkAZ6P/3CJxQs3QkEx8UZfkmVel
iXCyoXvL4nLAvuQDIrgUAAAACnRlc3RAcHVsc2UBZZZZ=
-----END OPENSSH PRIVATE KEY-----
"""

private let fixtureOpenSSHEd25519Enc = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABB5UA2Ci/
xisWCsPOpWJcxQAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIB8Ar01xYMyAd8dZ
ivGDhcpQRUKCB82V1S5uDXUiN75RAAAAkAvUI665nA4WzOHxXr5EeGoRYm9mEIoSjSPyKO
P8ytY4+v6ErSyhg2tsdPiZhO/I2MNOanTIE9kTsnS+hS4E2b4W2n1vFpOkYbyvKyKC3bmG
3uVX2Z9Vh19I4q3N/4SXhvkjpztSUtrjHRtLWH3fxrDSn/M7s5jFXhZ+iIEPd+CH4AMEDt
LzG+AZQBo4ZzZZZZ==
-----END OPENSSH PRIVATE KEY-----
"""

private let fixtureOpenSSHEcdsaP256 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQS/WVnJFAwl+PWomsxDZHPfHBIsAo9n
dSo5LgNq+30r0bDzAtGNpx1u4Lil5J82J++5oBVAxWInWhozyU6eN16vAAAAqIUAXI2FAF
yNAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBL9ZWckUDCX49aia
zENkc98cEiwCj2d1KjkuA2r7fSvRsPMC0Y2nHW7guKXknzYn77mgFUDFYidaGjPJTp43Xq
8AAAAhAJGuPur3abkiQ9DMnP/NK6BGAo8bsUQzmxsP/6gdAOqrAAAACnRlc3RAcHVsc2UB
ZZZZBQ==
-----END OPENSSH PRIVATE KEY-----
"""

private let fixtureTraditionalECDSAP256 = """
-----BEGIN EC PRIVATE KEY-----
MIIBaAIBAQQgyDgt3qcSq8ACjHbK07KPvXWyrsUkpxeLMGEGWz95sb2ggfowgfcC
AQEwLAYHKoZIzj0BAQIhAP////8AAAABAAAAAAAAAAAAAAAA////////////////
MFsEIP////8AAAABAAAAAAAAAAAAAAAA///////////////8BCBaxjXYqjqT57Pr
vVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMVAMSdNgiG5wSTamZ44ROdJreBn36QBEEE
axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54W
K84zV2sxXs7LtkBoN79R9QIhAP////8AAAAA//////////+85vqtpxeehPO5ysL8
YyVRAgEBoUQDQgAEXXj0SkKi2hqVcwSaU4FqKkiCfgRD/ubfE4Mnp1z0Dlqhu98t
Nu4Ei3Drk1TyiC824wTcW0qhd6fM0hg9+yZZZZ==
-----END EC PRIVATE KEY-----
"""

/// Synthetic structurally-valid DSA armor. The importer rejects the kind without
/// looking at the body, so a placeholder base64 is sufficient.
private let fixtureDSA = """
-----BEGIN DSA PRIVATE KEY-----
MIIBuwIBAAKBgQD9f1OBHXUSKVLfSpwu7OTn9hG3UjzvRADDHj+AtlEmaUVdQCJR
+1k9jVj6v8X1ujD2y5tVbNeBO4AdNG/yZmC3a5lQpaSfn+gEexAiwk+7qdf+ZZZZ
-----END DSA PRIVATE KEY-----
"""

// MARK: - RSA modulus enforcement fixtures
//
// Generated with `ssh-keygen -t rsa -b <bits>` (OpenSSH new-format and traditional
// PKCS#1) and `openssl pkey -in ... -outform PEM` (PKCS#8), then tail-mangled per
// the convention above. The modulus lives at the start of each payload, well
// before the corrupted tail, so the importer's modulus-length check still works
// against the structurally-valid prefix.

private let fixtureRSA1024PKCS1 = """
-----BEGIN RSA PRIVATE KEY-----
MIICXQIBAAKBgQDX5Yrc4hok8i8ue/J5ME1S7tgsaVlKcJkZW0NAD8iLReGazEiB
C4tcJWYj1ajpDvZBX7N7JyXfK8G5zT9/u6tM+YISW43bb+UgK4JzOS99uOlcNQgs
zIricPLUF80ID2SBYUBM1j/BThzsp7tOVrIJnOIqQFyH8kBF43ARXm+ESwIDAQAB
AoGBANP+MTxzR/i/VlTuoEkfhM3KeboiN+tAZRTg6EgfN2yKUd0OeqM8EruIfaLy
ScmPR38p2bMz3Zwl+zPWtmNWg/xinamhiZEEr+vrDUAMDhPJ310nmzLQXbranDw7
kZrm9ZgT91Nq6kxrGARlbaBSr4P6IeENGqRdeafLWzeOx8wBAkEA/LICVSTfs3iY
7dD/8/6RUPYWx6u5hbNgyO9tGZJVJ6YXiOSF+9VR5sjI3TOff+v3Djnx1SHIgXfD
YkHm3AyOWwJBANq4VgsLN4KgRfTHDA6F9du3iiQxsyKfcyyx94LSGKW8opU1z+Hv
f3xQxLVTmC2oER5a9/IOofA34E3+asGHpNECQATvdRw0nCnlMRdz/YvGbRAnvkoo
EHeMCVfjVT4qnX8ov0ztKbDBedgIE+Q+Hd9hvHGKsC55enEM5cQFhXzGwgECQBA8
eN6vAXrn7OmD0ShO13ZtBIs1SUf7sDAUMfx7HitHeoY7DWiHP955nHCdeQGCpWqs
dBV68piDfVos1b3yFNECQQCwnziALuj91McbWch4EJn29FQb7dAKxlherbrzGsbi
ayEJh1t8F/nD49kGMZBlEG1Vk/p7Xlzx4jy22ZovZZZZ
-----END RSA PRIVATE KEY-----
"""

private let fixtureOpenSSHEcdsaP384 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQSVOfuwtshOnuU6SXSzEpFeaHn0+cil
q33EAN4ZIh0P47LWAScm0ZPk2vFcaA1fw/5k5CNi4H+RsLLKNNkP1ar/Er+mG7X/boHydj
4ldMHLg5FLqVTjM8Rf/++DJYIGk6AAAADwMCOwJjAjsCYAAAATZWNkc2Etc2hhMi1uaXN0
cDM4NAAAAAhuaXN0cDM4NAAAAGEElTn7sLbITp7lOkl0sxKRXmh59PnIpat9xADeGSIdD+
Oy1gEnJtGT5NrxXGgNX8P+ZOQjYuB/kbCyyjTZD9Wq/xK/phu1/26B8nY+JXTBy4ORS6lU
4zPEX//vgyWCBpOgAAAAMEg8McJ1GwQHEigdTx+D2oyOSMnSZSvaxOoeLvK0SasZ1Nut/Y
rk92ZUhrUlKigxEwAAACFidXR0ZXJ5YWxwYWNhQE1hY0Jvb2stUHJvLTQubG9jYWwBAgME
ZZZZ
-----END OPENSSH PRIVATE KEY-----
"""

private let fixtureOpenSSHEcdsaP521 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQBvVLBY3Ed0QUzY4Gwwaj7p+AyyTsa
YNHi7G2HfRvQHMAu4egbRaOqpf0w2lTe1sA8kMOHGnJhTygniVH7WZygnykBmLAZnBMUYQ
UpW7S0a+cBN8JX9/FiNfVrkJDlIvUIG/lUPRrDNQKXFCAX8tMvZxJ7+J4vHAHaevVoxvQO
wHPSgtYAAAEgp9cd06fXHdMAAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
AAAIUEAb1SwWNxHdEFM2OBsMGo+6fgMsk7GmDR4uxth30b0BzALuHoG0WjqqX9MNpU3tbA
PJDDhxpyYU8oJ4lR+1mcoJ8pAZiwGZwTFGEFKVu0tGvnATfCV/fxYjX1a5CQ5SL1CBv5VD
0awzUClxQgF/LTL2cSe/ieLxwB2nr1aMb0DsBz0oLWAAAAQgDRSwaJioVvfhWP6r6GBevS
WDhpQHVwqJLMx7Qqd6VgJPn03FIWLODsowcZxYYEoLpbkDIvk8ZG4Bh+d8ZvAfItHgAAAC
FidXR0ZXJ5YWxwYWNhQE1hY0Jvb2stUHJvLTQubG9jZZZZ
-----END OPENSSH PRIVATE KEY-----
"""

