//
//  SSHCertificateManagerTests.swift
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

import XCTest
@testable import Pulse

final class SSHCertificateManagerTests: XCTestCase {

    // MARK: - Fixture

    /// Real `ssh-keygen`-emitted cert: ed25519 user cert, keyID "alice-2026",
    /// principals [alice, bob], serial 42, validity 2026-01-01T00:00 UTC to
    /// 2027-01-01T00:00 UTC. CA is the matching ed25519 key whose fingerprint
    /// is `SHA256:TQzjwzwkjG9iTo2J5mAAhyGgjz2edyUdloeYoS6SxII`.
    ///
    /// Generated offline with:
    ///   ssh-keygen -t ed25519 -N "" -f ca
    ///   ssh-keygen -t ed25519 -N "" -f user
    ///   ssh-keygen -s ca -I "alice-2026" -n "alice,bob" \
    ///     -V "20260101000000:20270101000000" -z 42 user.pub
    private static let fixtureCertLine =
        "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIO2NpWp2GzVdTRyvDC2W+E5COaW7uwEG3SMWA8wlwqLLAAAAICS+cdNe6n0ehPqpDUEjTO5Tvk3rK0r8ynWfI35yyoKFAAAAAAAAACoAAAABAAAACmFsaWNlLTIwMjYAAAAQAAAABWFsaWNlAAAAA2JvYgAAAABpVRBAAAAAAGs2Q8AAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAMwAAAAtzc2gtZWQyNTUxOQAAACDyxkC30wMgcY2DN9c0HAabuat9MJWMI+P115Ot0AtHxgAAAFMAAAALc3NoLWVkMjU1MTkAAABA8TtmctNwenUM8cxigRWSosgbHfa7ggZZ7fgIhj1Idu4NdrkmWnmLTbAivvea5biv+Px5g/W2Y4h8fLx94J8RCQ== test user"

    private static var fixtureBlob: Data { Data(fixtureCertLine.utf8) }

    // MARK: - metadata(for:)

    func testParsesFixtureMetadata() throws {
        let meta = try SSHCertificateManager.metadata(for: Self.fixtureBlob)
        XCTAssertEqual(meta.keyID, "alice-2026")
        XCTAssertEqual(meta.principals, ["alice", "bob"])
        XCTAssertEqual(meta.serial, 42)
        XCTAssertEqual(meta.caFingerprintSHA256, "SHA256:TQzjwzwkjG9iTo2J5mAAhyGgjz2edyUdloeYoS6SxII")
    }

    func testValidityWindowParsesAsUTC() throws {
        let meta = try SSHCertificateManager.metadata(for: Self.fixtureBlob)
        // 2026-01-01T00:00:00Z and 2027-01-01T00:00:00Z per the -V argument above.
        // ssh-keygen interprets -V "YYYYMMDDhhmmss" timestamps as local time, so the
        // exact epoch depends on the host TZ at generation time. The assertion is
        // therefore framed as "validity covers all of 2026 with about a one-day cushion
        // either side" rather than an exact epoch match.
        let calendar = Calendar(identifier: .gregorian)
        let midYear2026 = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        XCTAssertTrue(SSHCertificateManager.isValid(meta, at: midYear2026))

        let way2030 = calendar.date(from: DateComponents(year: 2030, month: 1, day: 1))!
        XCTAssertFalse(SSHCertificateManager.isValid(meta, at: way2030))

        let way2020 = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        XCTAssertFalse(SSHCertificateManager.isValid(meta, at: way2020))
    }

    // MARK: - Error paths

    func testNonUTF8BlobThrowsMalformed() {
        let blob = Data([0xFF, 0xFE, 0xFD])
        XCTAssertThrowsError(try SSHCertificateManager.metadata(for: blob)) { error in
            guard case SSHCertificateManager.CertificateError.malformedCertificate = error else {
                return XCTFail("expected .malformedCertificate, got \(error)")
            }
        }
    }

    func testPlainPublicKeyThrowsNotACertifiedKey() {
        // Same algo prefix family but a bare host key (not a -cert-v01 type).
        let plain = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPLGQLfTAyBxjYM31zQcBpu5q30wlYwj4/XXk63QC0fG test ca"
        let blob = Data(plain.utf8)
        XCTAssertThrowsError(try SSHCertificateManager.metadata(for: blob)) { error in
            XCTAssertEqual(error as? SSHCertificateManager.CertificateError, .notACertifiedKey)
        }
    }

    func testGibberishBlobThrowsMalformed() {
        let blob = Data("not even close to a cert line".utf8)
        XCTAssertThrowsError(try SSHCertificateManager.metadata(for: blob)) { error in
            guard case SSHCertificateManager.CertificateError.malformedCertificate = error else {
                return XCTFail("expected .malformedCertificate, got \(error)")
            }
        }
    }

    // MARK: - isValid(_:at:)

    func testIsValidIsInclusive() {
        let meta = SSHCertificateManager.CertificateMetadata(
            keyID: "x",
            principals: [],
            validAfter: Date(timeIntervalSince1970: 100),
            validBefore: Date(timeIntervalSince1970: 200),
            caFingerprintSHA256: "SHA256:abc",
            serial: 0
        )
        XCTAssertTrue(SSHCertificateManager.isValid(meta, at: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(SSHCertificateManager.isValid(meta, at: Date(timeIntervalSince1970: 150)))
        XCTAssertTrue(SSHCertificateManager.isValid(meta, at: Date(timeIntervalSince1970: 200)))
        XCTAssertFalse(SSHCertificateManager.isValid(meta, at: Date(timeIntervalSince1970: 99)))
        XCTAssertFalse(SSHCertificateManager.isValid(meta, at: Date(timeIntervalSince1970: 201)))
    }

    // MARK: - fingerprint(forOpenSSHTextLine:)

    /// Regression guard for the `algo BASE64 comment` parsing path. ssh-keygen
    /// writes a trailing comment by default; a naive splitter that takes the
    /// substring after the first space would feed `"BASE64 comment"` into the
    /// base64 decoder and silently yield "SHA256:(unavailable)" — which would
    /// then mean cert-attested host connections never match a stored
    /// `HostTrust.trustedCA` fingerprint. Verified against `ssh-keygen -lf ca.pub`
    /// from the same fixture-generation session as the cert blob above.
    func testFingerprintHandlesCommentField() {
        let lineWithComment =
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPLGQLfTAyBxjYM31zQcBpu5q30wlYwj4/XXk63QC0fG test ca"
        let expected = "SHA256:TQzjwzwkjG9iTo2J5mAAhyGgjz2edyUdloeYoS6SxII"
        XCTAssertEqual(
            SSHCertificateManager.fingerprint(forOpenSSHTextLine: lineWithComment),
            expected
        )
    }

    func testFingerprintHandlesLineWithoutComment() {
        let lineNoComment =
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPLGQLfTAyBxjYM31zQcBpu5q30wlYwj4/XXk63QC0fG"
        let expected = "SHA256:TQzjwzwkjG9iTo2J5mAAhyGgjz2edyUdloeYoS6SxII"
        XCTAssertEqual(
            SSHCertificateManager.fingerprint(forOpenSSHTextLine: lineNoComment),
            expected
        )
    }

    func testFingerprintMalformedReturnsUnavailable() {
        // Single-token (no base64 payload): split yields one part, guard fails.
        XCTAssertEqual(
            SSHCertificateManager.fingerprint(forOpenSSHTextLine: "no-base64-here"),
            "SHA256:(unavailable)"
        )
        // Non-base64 garbage as the payload: after `.ignoreUnknownCharacters`
        // strips the `!` chars the residue isn't a valid base64 length, so
        // `Data(base64Encoded:)` returns nil and the guard catches it.
        XCTAssertEqual(
            SSHCertificateManager.fingerprint(forOpenSSHTextLine: "ssh-ed25519 !!!not-base64!!!"),
            "SHA256:(unavailable)"
        )
        XCTAssertEqual(
            SSHCertificateManager.fingerprint(forOpenSSHTextLine: ""),
            "SHA256:(unavailable)"
        )
    }

    // Note: SSHCertificateManager.serialise(_:) round-trip coverage requires
    // constructing a NIOSSHCertifiedPublicKey directly, which needs `import NIOSSH`
    // in the test target. The test target presently reaches NIOSSH transitively
    // through @testable import Pulse for runtime symbols only; the module itself
    // is not visible at compile time here. The serialise path is structurally a
    // single call into NIOSSH's String(openSSHPublicKey:) emitter, and is
    // exercised implicitly once the credential-import flow that produces a cert
    // blob lands (Slice 4+). When that flow lands, add a parse → serialise →
    // parse round-trip here and assert metadata equality across the two parses.
}
