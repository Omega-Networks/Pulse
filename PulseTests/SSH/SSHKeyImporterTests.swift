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

    func testOpenSSHEd25519Encrypted() throws {
        let result = try SSHKeyImporter.validate(fixtureOpenSSHEd25519Enc)
        XCTAssertEqual(result.pemKind, .opensshPrivate)
        XCTAssertEqual(result.algorithm, .ed25519)
        XCTAssertTrue(result.isEncrypted)
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

    func testTraditionalRSAEncryptedDetectsProcType() throws {
        let result = try SSHKeyImporter.validate(fixtureTraditionalRSAEncrypted)
        XCTAssertEqual(result.pemKind, .rsaPrivate)
        XCTAssertEqual(result.algorithm, .rsa)
        XCTAssertTrue(result.isEncrypted)
    }

    func testPKCS8RSAUnencrypted() throws {
        let result = try SSHKeyImporter.validate(fixturePKCS8RSA)
        XCTAssertEqual(result.pemKind, .pkcs8)
        XCTAssertFalse(result.isEncrypted)
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
}

// MARK: - Fixtures
//
// Real ssh-keygen / openssl output, generated once and pasted here. None of these
// keys are used anywhere outside this test file; they exist to exercise PEM-armor
// detection, payload base64 decoding, and OpenSSH inner-blob inspection.

private let fixtureOpenSSHEd25519Unenc = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCj/9wicULN0JBMfFGX5JlXpYlwsqF7y+JywL7kAyK4FAAAAJAzScE0M0nB
NAAAAAtzc2gtZWQyNTUxOQAAACCj/9wicULN0JBMfFGX5JlXpYlwsqF7y+JywL7kAyK4FA
AAAEBMtaTqL5dFDf7h6/SNwakBKGHKy0yIzadn6f3s1PkAZ6P/3CJxQs3QkEx8UZfkmVel
iXCyoXvL4nLAvuQDIrgUAAAACnRlc3RAcHVsc2UBAgM=
-----END OPENSSH PRIVATE KEY-----
"""

private let fixtureOpenSSHEd25519Enc = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABB5UA2Ci/
xisWCsPOpWJcxQAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIB8Ar01xYMyAd8dZ
ivGDhcpQRUKCB82V1S5uDXUiN75RAAAAkAvUI665nA4WzOHxXr5EeGoRYm9mEIoSjSPyKO
P8ytY4+v6ErSyhg2tsdPiZhO/I2MNOanTIE9kTsnS+hS4E2b4W2n1vFpOkYbyvKyKC3bmG
3uVX2Z9Vh19I4q3N/4SXhvkjpztSUtrjHRtLWH3fxrDSn/M7s5jFXhZ+iIEPd+CH4AMEDt
LzG+AZQBo4ZzsicQ==
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
AgMEBQ==
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
Nu4Ei3Drk1TyiC824wTcW0qhd6fM0hg9+ydajg==
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
JYlazaIpvI34Mz+UTpMITmw7y3LG62Ncfh35R8Po4Hfm83B2dtRBwLXJJfjQVw8O
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
7pjQaN9D9I/9kmh51zay4udZBA==
-----END PRIVATE KEY-----
"""

/// Synthetic structurally-valid DSA armor. The importer rejects the kind without
/// looking at the body, so a placeholder base64 is sufficient.
private let fixtureDSA = """
-----BEGIN DSA PRIVATE KEY-----
MIIBuwIBAAKBgQD9f1OBHXUSKVLfSpwu7OTn9hG3UjzvRADDHj+AtlEmaUVdQCJR
+1k9jVj6v8X1ujD2y5tVbNeBO4AdNG/yZmC3a5lQpaSfn+gEexAiwk+7qdf+t8Yb
-----END DSA PRIVATE KEY-----
"""
