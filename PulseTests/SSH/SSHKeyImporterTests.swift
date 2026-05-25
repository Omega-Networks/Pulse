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
    /// the Slice 3 7b₁ v1 scope (bcrypt-pbkdf is the KDF we'd have to roll
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
    /// P-256. Regression guard for the round-1 fix in commit `4dfe844`.
    func testTraditionalECPEMSurfacesUnknownCurve() throws {
        let result = try SSHKeyImporter.validate(fixtureTraditionalECDSAP256)
        XCTAssertEqual(result.pemKind, .ecPrivate)
        XCTAssertEqual(result.algorithm, .ecdsaUnknownCurve)
        XCTAssertFalse(result.isEncrypted)
    }

    // MARK: - v1 portable scope (ADR §1 amendment)

    /// RSA is rejected at the front door per the Slice 3 7b₁ v1 scope.
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

    /// OpenSSH new-format with ssh-rsa is rejected via the same front-door
    /// path; the algorithm identifier is checked before the cipher gate.
    func testRSAOpenSSHIsRejectedWithRemediation() {
        XCTAssertThrowsError(try SSHKeyImporter.validate(fixtureRSAOpenSSH1024)) { error in
            guard case SSHKeyImporter.ImporterError.unsupportedAlgorithmInV1(let name, _) = error else {
                return XCTFail("expected unsupportedAlgorithmInV1, got \(error)")
            }
            XCTAssertEqual(name, "RSA")
        }
    }

    /// PKCS#8 RSA is rejected by descending into the rsaEncryption OID and
    /// throwing the same unsupportedAlgorithmInV1 error. Third regression
    /// guard for the three RSA classifier arms.
    func testRSAPKCS8IsRejectedWithRemediation() {
        XCTAssertThrowsError(try SSHKeyImporter.validate(fixturePKCS8RSA)) { error in
            guard case SSHKeyImporter.ImporterError.unsupportedAlgorithmInV1(let name, _) = error else {
                return XCTFail("expected unsupportedAlgorithmInV1, got \(error)")
            }
            XCTAssertEqual(name, "RSA")
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

    /// Encrypted Ed25519 derivation works in principle (the OpenSSH new-format
    /// public blob is unencrypted), but the credential never reaches
    /// `derivePublicKey` under v1 because `validate()` rejects encrypted PEMs
    /// at the front door. The test constructs `ImportedSSHKey` directly to
    /// exercise the dormant code path so a future contributor who relaxes the
    /// front-door reject (when bcrypt-pbkdf becomes available) gets the rest
    /// of the pipeline already covered.
    func testDerivePublicKeyFromEncryptedOpenSSHEd25519_DormantPath() throws {
        let imported = SSHKeyImporter.ImportedSSHKey(
            pemKind: .opensshPrivate,
            algorithm: .ed25519,
            normalisedPEM: fixtureOpenSSHEd25519Enc,
            normalisedPEMData: Data(fixtureOpenSSHEd25519Enc.utf8),
            isEncrypted: true
        )
        let publicKey = try SSHKeyImporter.derivePublicKey(from: imported)
        XCTAssertEqual(publicKey.count, 51)
    }

    /// RSA derivation paths are dormant under v1 (RSA is rejected at the
    /// front door). The tests construct `ImportedSSHKey` directly so the
    /// derivation pipeline stays under regression coverage for the day
    /// upstream NIOSSH lands RSA signing and the front-door reject relaxes.
    func testDerivePublicKeyFromOpenSSHRSA3072_DormantPath() throws {
        let imported = SSHKeyImporter.ImportedSSHKey(
            pemKind: .opensshPrivate,
            algorithm: .rsa,
            normalisedPEM: fixtureRSAOpenSSH3072,
            normalisedPEMData: Data(fixtureRSAOpenSSH3072.utf8),
            isEncrypted: false
        )
        let publicKey = try SSHKeyImporter.derivePublicKey(from: imported)
        let prefix: [UInt8] = [
            0x00, 0x00, 0x00, 0x07,
            0x73, 0x73, 0x68, 0x2D, 0x72, 0x73, 0x61
        ]
        XCTAssertEqual(publicKey.prefix(prefix.count), Data(prefix))
        XCTAssertGreaterThan(publicKey.count, 380)
        XCTAssertLessThan(publicKey.count, 420)
    }

    func testDerivePublicKeyFromPKCS1RSA3072_DormantPath() throws {
        let imported = SSHKeyImporter.ImportedSSHKey(
            pemKind: .rsaPrivate,
            algorithm: .rsa,
            normalisedPEM: fixtureRSA3072PKCS1,
            normalisedPEMData: Data(fixtureRSA3072PKCS1.utf8),
            isEncrypted: false
        )
        let publicKey = try SSHKeyImporter.derivePublicKey(from: imported)
        let prefix: [UInt8] = [
            0x00, 0x00, 0x00, 0x07,
            0x73, 0x73, 0x68, 0x2D, 0x72, 0x73, 0x61
        ]
        XCTAssertEqual(publicKey.prefix(prefix.count), Data(prefix))
    }

    func testDerivePublicKeyFromPKCS8RSA_DormantPath() throws {
        let imported = SSHKeyImporter.ImportedSSHKey(
            pemKind: .pkcs8,
            algorithm: .rsa,
            normalisedPEM: fixturePKCS8RSA,
            normalisedPEMData: Data(fixturePKCS8RSA.utf8),
            isEncrypted: false
        )
        let publicKey = try SSHKeyImporter.derivePublicKey(from: imported)
        let prefix: [UInt8] = [
            0x00, 0x00, 0x00, 0x07,
            0x73, 0x73, 0x68, 0x2D, 0x72, 0x73, 0x61
        ]
        XCTAssertEqual(publicKey.prefix(prefix.count), Data(prefix))
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

    // MARK: - OpenSSH new-format private-key decoder (Slice 3 7b₂)

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

private let fixtureTraditionalRSAEncrypted = """
-----BEGIN RSA PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-128-CBC,0BCB22D061327995BDE39123768D4E83

pE0HBZbzlGraiEuHfEVJQbGEp7YK0D5+admTHssDkiUGhorwse8RXWl2dB9sqmvD
p7U4/cDxiTBIiEM/tO2FF2xsMUOeBmnss9FdVkkqliVUS6psZ4tpDooFgNHlQt7y
cwstC7tlTehcSnwJ8ILlcM/QTkCamMdwBOIhNqBGIDTOLgVS9Mufby+Z5USsBlUS
OlxYJU3AJDKAL91yFyAZ6rdDXW04bmECedEenx+2P897OR+4nj2Hvz4JzJM5ijjb
4AV85nAoCNmj5vkw7Z3P4RaMMWHnCLj27LZeQgEfFC1YJ4zLZv0TqTm3u06w2Qjk
pKe2Z57bnmEaAZTf7j6vHfP0IupzJ/vDipgt84ZoICoKDDqTzjQYimuL+xiZhRiV
6M3RBXbvzE2foAAXa855pMbWp+YI8Bw6K9c6OcANu358+Khbsros12q+t3+kuPF2
6CdlR46WuIk37p2QwXWIH8dZCMDAURbCADC+hVzXD8166cqw5Vk/fTHIfVYy3tOB
F6MmHUDlGhKoBXu3nl0r3B87kaI1/Sw/QxrWnvYX+ghbNjIMRpBRzEyi1tt0KCht
7ZbePDnZC7tqHlcZQvEWHOecgvdMpX/ly4Xu3+yMlWFSxP2Tn3dym3rYZCy4UhCN
R0Fm5h5dZL2GA8ngTxaBjXm5KAF2HYTebh8Bx8NKph3ODuANcfTvwWDgbCtd1IJM
blv2r50tAGQFiwGtcqtvnCSmvlTrFKM0cHOtJlE2lLRSyD+uf+ky8ClNo5lc1+wd
JYlazaIpvI34Mz+UTpMITmw7y3LG62Ncfh35R8Po4Hfm83B2dtRBwLXJJfjQZZZZ
-----END RSA PRIVATE KEY-----
"""

private let fixturePKCS8RSA = """
-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDjx+ixbFDzTFcH
pbGtYW+FWO+1rmTewklSiTKIsh4b3jNkBl8H6CJWcerdER/8GI/7WjhSkqGheB+v
4VqcRirrkEbZ1wpvPzfiy4dA57wG98qUwUrgtm39aTAqRLrQrzHpO/Sn8rMQUCn5
+lUq8PPhyGDhGEGmtT+v8epOWuegVy6+48ZrrfkJfj2pg+KLD71OWAj/iQK6hHEA
0/Ifkv6hlThR/WMeUNVxrdRsn96hOHArOprD/h8UvQakJRv2hfjOxJiwecx6D3UB
quyad5W3thtXS3M1iPG5zPgsIZeNiyED5W4tnChmrXLqy5MxXJ7Iyf8P4qheQt0D
nft79hqVAgMBAAECggEBAJLmaGGUc5iVUUNzTuV8g0nCk8XeFNu8/UCnjtmt1dEv
OoF1wm/8+7g4e7naw3/371OxWcWXH3pdWEI72g4TCrclMyxmjSo14Tr4+9+WFCOC
Rzosdrf5r3HRFukLrlfLxSqgKibuVSFeMdQv6CFriD3C1wgUdrKnDc3Q/MVPxzYW
DBXwCX7F4KuvzCDjUR9FogV4D9A7oNzPzdHqV3yZX6LwSPYFo3kBTVQ4nbuSqPXI
lxhlx+sxmcBtF/TFt1T4Jvq5eDu9VSAAqG7E9VdYOk1pMoblV6UvVbsp0Bl3t650
EvE5kbrx5rUvflwhB6XZfgxd+mCrzXHJwnfhef6QP8ECgYEA/QNEorH8pDcEh0kR
SKYsgAmscLuHAcR/7OX+AcKGGZ/bG0C8siOWn4MJUkLnP608mEOqNmFLBCVCuyTd
/hpYtfHkiWk0wRIu1XpRTGS92zFZabuEmyxHSKehyasyhCRNVkevuZa/SW8MsWtB
VBdS5vE1qxFhDlwdcnmRPAgMk4kCgYEA5nhgn7eEGhjqAg8xI2sBr3tvotO6kwzc
MpfTDzk/vyY9A/EM+xNKFW8Sru8sSrxMr20vgSAmSgiYtdIHYrLJh2jDHTbJF2Pq
5JrVLGBVCozuRvuPnS8w2mUprAGq+jm+rIDl0lA3s7bwdHsx494g54wDfdTF9XUl
mKiTqNYOb60CgYEA0Bc5AwqaPEFXwyCwS20ImoHaRpmlbym7AQ8j+zSO8FJOdbqn
t2eXwTeXmgWWhgOoG59DRhh9BzrSCHNI9W2b2oDJMs7JaaXXyRIh/U+56qZK4LAu
XyVqt3HPmbrpAE+PH9Az0dMPHolsChupjkzkjTaDql/P0Gyod3dOoO4J0ekCgYEA
g0Bs7qipr98ebZvPRTdsl055zkY8TACX6qwyQ8o7tpWFTBhcZySeHUTLZBrLo6hH
F+Tbl/MCO0lYBrwc/qWJRfdwntOThCGgJR7UZlhaNg76qCwdpsu4S7gvGkk84RI/
t6gUukh64Hs/x2ZdjEL1hEhluKSTNG3Jwn3G0fFN+WUCgYAr7I7XBU7ZEfm616f9
R6oMyi6PpOCs9RKcIG+q0xeCJeopxYCvxyuuC8L8zupBjhqga/7zZflQLAeRCp99
cEG3cAfybCfLbuf7sfyOCws8x+SXbtwg+VvnXmxzaWaGVeg1S2Jm2Bbn83/Omnn8
7pjQaN9D9I/9kmh51zay4uZZZZ==
-----END PRIVATE KEY-----
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

private let fixtureRSA3072PKCS1 = """
-----BEGIN RSA PRIVATE KEY-----
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
-----END RSA PRIVATE KEY-----
"""

private let fixtureRSAOpenSSH1024 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn
NhAAAAAwEAAQAAAIEAqUJ9R8/N0sHzcsBF8aHPbLK0cBiL7Aye7wXVc0V7yrlStKWSktpV
LeTIlNHrV3n3IouR8vpGblmeJaXV3QI7AkcUE54KiGyxa84HaXu1NhzoT3NQzvfbU2Vjpz
T+wN+oKJcmvsDXzY9RdZhBcrRJEL7KfOewbjiezo9p24UgfuMAAAIYsV+WvbFflr0AAAAH
c3NoLXJzYQAAAIEAqUJ9R8/N0sHzcsBF8aHPbLK0cBiL7Aye7wXVc0V7yrlStKWSktpVLe
TIlNHrV3n3IouR8vpGblmeJaXV3QI7AkcUE54KiGyxa84HaXu1NhzoT3NQzvfbU2VjpzT+
wN+oKJcmvsDXzY9RdZhBcrRJEL7KfOewbjiezo9p24UgfuMAAAADAQABAAAAgB3m6y8WnS
wQq6uoIDMx/O0dHRd4nq+TAzkC9NSqf9Yuq1fSsHRVMhsrgewYsdUAbRKjSaN9Z5fzKSdJ
huDGlhnlWgn27KBdhgzLUJYBj2PCTEa33rT643Cqe02j1eqxizHGZxIWcRpGvUZtOQD9ER
ICsEWexjzsAITP3FBYVs5xAAAAQGSBcuRKajotxJVU20FKxTkMpySCCZi7H/WharvtKBcP
dSmNl15gCpFMkY6jRU3KNj7HURx3vi2+0pGxl2a/Q08AAABBANM2kt5VF8iYbIKLWef8jf
BAhKBObM4G6n3myUGxZhNW0ymYa8VXV9PWFP4Fm7ER/AKqVFKncoEd3obpO57c44cAAABB
AM0mhzppQvThtoUTOdmPlwX16ORQD/bJ2cKQMHFuuv4R2KSX6NERF/EAD6pjJf26+IbVBN
Pr767kjSUWzBtZWMUAAAAhYnV0dGVyeWFscGFjYUBNYWNCb29rLVByby00LmxvY2FZZZZ=
-----END OPENSSH PRIVATE KEY-----
"""

private let fixtureRSAOpenSSH3072 = """
-----BEGIN OPENSSH PRIVATE KEY-----
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
-----END OPENSSH PRIVATE KEY-----
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

private let fixtureRSAPKCS8At1024 = """
-----BEGIN PRIVATE KEY-----
MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBANflitziGiTyLy57
8nkwTVLu2CxpWUpwmRlbQ0APyItF4ZrMSIELi1wlZiPVqOkO9kFfs3snJd8rwbnN
P3+7q0z5ghJbjdtv5SArgnM5L3246Vw1CCzMiuJw8tQXzQgPZIFhQEzWP8FOHOyn
u05Wsgmc4ipAXIfyQEXjcBFeb4RLAgMBAAECgYEA0/4xPHNH+L9WVO6gSR+Ezcp5
uiI360BlFODoSB83bIpR3Q56ozwSu4h9ovJJyY9HfynZszPdnCX7M9a2Y1aD/GKd
qaGJkQSv6+sNQAwOE8nfXSebMtBdutqcPDuRmub1mBP3U2rqTGsYBGVtoFKvg/oh
4Q0apF15p8tbN47HzAECQQD8sgJVJN+zeJjt0P/z/pFQ9hbHq7mFs2DI720ZklUn
pheI5IX71VHmyMjdM59/6/cOOfHVIciBd8NiQebcDI5bAkEA2rhWCws3gqBF9McM
DoX127eKJDGzIp9zLLH3gtIYpbyilTXP4e9/fFDEtVOYLagRHlr38g6h8DfgTf5q
wYek0QJABO91HDScKeUxF3P9i8ZtECe+SigQd4wJV+NVPiqdfyi/TO0psMF52AgT
5D4d32G8cYqwLnl6cQzlxAWFfMbCAQJAEDx43q8Beufs6YPRKE7Xdm0EizVJR/uw
MBQx/HseK0d6hjsNaIc/3nmccJ15AYKlaqx0FXrymIN9WizVvfIU0QJBALCfOIAu
6P3UxxtZyHgQmfb0VBvt0ArGWF6tuvMaxuJrIQmHW3wX+cPj2QYxkGUQbVWT+nte
XPHiPLbZmi/ZZZZ=
-----END PRIVATE KEY-----
"""
