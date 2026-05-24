//
//  OpenSSHWireFormatTests.swift
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

/// Reference-vector tests for `SecureEnclaveKeyManager.openSSHWireFormat(secp256r1Point:)`.
///
/// Uses `CryptoKit.P256.Signing.PrivateKey` to generate a known public key and
/// asserts the encoder produces RFC 5656 §3.1 framing byte-for-byte. Avoids any
/// Keychain or Secure Enclave interaction so the tests run on any host.
final class OpenSSHWireFormatTests: XCTestCase {

    /// `ecdsa-sha2-nistp256` is 19 bytes, `nistp256` is 8 bytes, the SEC1 point is
    /// 65 bytes. Three uint32 length prefixes (4 bytes each) bring the total to
    /// `4 + 19 + 4 + 8 + 4 + 65 = 104`.
    private static let expectedWireLength = 104

    /// Hand-validates the framing layout: each string field is preceded by a
    /// big-endian `uint32` length, then the payload. The point payload starts with
    /// the SEC1 uncompressed indicator `0x04`.
    func testWireFormatLayoutMatchesRFC5656() throws {
        let key = P256.Signing.PrivateKey()
        let point = key.publicKey.x963Representation
        XCTAssertEqual(point.count, 65, "CryptoKit P-256 public key must serialise as 65 bytes (SEC1 uncompressed)")

        let wire = try SecureEnclaveKeyManager.openSSHWireFormat(secp256r1Point: point)
        XCTAssertEqual(wire.count, Self.expectedWireLength)

        // Field 1: length-prefixed "ecdsa-sha2-nistp256" (19 bytes -> 0x00000013).
        XCTAssertEqual(wire[0..<4], Data([0x00, 0x00, 0x00, 0x13]))
        XCTAssertEqual(String(data: wire[4..<23], encoding: .ascii), "ecdsa-sha2-nistp256")

        // Field 2: length-prefixed "nistp256" (8 bytes -> 0x00000008).
        XCTAssertEqual(wire[23..<27], Data([0x00, 0x00, 0x00, 0x08]))
        XCTAssertEqual(String(data: wire[27..<35], encoding: .ascii), "nistp256")

        // Field 3: length-prefixed 65-byte point (0x00000041). First byte is 0x04
        // (SEC1 uncompressed); the rest is the verbatim X || Y from CryptoKit.
        XCTAssertEqual(wire[35..<39], Data([0x00, 0x00, 0x00, 0x41]))
        XCTAssertEqual(wire[39], 0x04)
        XCTAssertEqual(Data(wire[39..<104]), point)
    }

    /// SEC1 compressed encodings (`0x02` even-y, `0x03` odd-y) are valid public-key
    /// representations elsewhere but not what OpenSSH `ecdsa-sha2-nistp256` expects.
    /// The encoder must refuse them rather than silently emit an invalid line.
    func testWireFormatRejectsCompressedPoint() {
        var compressed = Data([0x02])
        compressed.append(Data(repeating: 0xAB, count: 32))   // X coordinate only
        XCTAssertThrowsError(try SecureEnclaveKeyManager.openSSHWireFormat(secp256r1Point: compressed))
    }

    /// Length 64 is a common off-by-one (uncompressed point sans the leading 0x04
    /// prefix). The encoder must reject anything that isn't a full 65-byte SEC1
    /// uncompressed point.
    func testWireFormatRejectsTruncatedPoint() {
        let truncated = Data(repeating: 0x04, count: 64)
        XCTAssertThrowsError(try SecureEnclaveKeyManager.openSSHWireFormat(secp256r1Point: truncated))
    }
}
