//
//  SessionLogRecordTests.swift
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

/// Disk-free coverage for `SessionLogCrypto` — the pure-function tier of
/// the Slice 4 recording stack. Exercises envelope round-trip, the
/// per-record AES.GCM seal/open contract, the hash-chain validator
/// (including tamper detection at single-byte resolution), and the
/// session-key wrap/unwrap path using software P-256 keys as the test
/// seam. The SE side of unwrap shares the same algebra (the API surface
/// differs only in which type signs the ECDH); biometric integration is
/// covered by manual verification.
final class SessionLogRecordTests: XCTestCase {

    // MARK: Per-record seal/open

    func testSealAndOpenRoundTripPreservesEveryField() throws {
        let key = SymmetricKey(size: .bits256)
        let original = SessionLogRecord(
            seq: 7,
            ts: "2026-05-26T03:41:12.184Z",
            dir: .out,
            prev: String(repeating: "00", count: 32),
            bytes: Data("interactive shell input\n".utf8).base64EncodedString()
        )
        let sealed = try SessionLogCrypto.seal(record: original, using: key)
        let recovered = try SessionLogCrypto.open(encrypted: sealed, using: key)
        XCTAssertEqual(recovered, original)
    }

    func testSealProducesFreshNoncePerCall() throws {
        // Same input record + same key + two seal calls -> two different
        // SealedBox.combined byte sequences (the nonce is freshly random
        // each time, which the chain hash depends on for uniqueness).
        let key = SymmetricKey(size: .bits256)
        let record = SessionLogRecord(
            seq: 0,
            ts: "2026-05-26T03:41:12.184Z",
            dir: .in,
            prev: "",
            bytes: Data("x".utf8).base64EncodedString()
        )
        let a = try SessionLogCrypto.seal(record: record, using: key)
        let b = try SessionLogCrypto.seal(record: record, using: key)
        XCTAssertNotEqual(a.sealedCombined, b.sealedCombined, "Each seal must produce a fresh nonce")
    }

    func testOpenWithWrongKeyFailsAsAuthenticationFailure() throws {
        let goodKey = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        let record = SessionLogRecord(
            seq: 0,
            ts: "2026-05-26T03:41:12.184Z",
            dir: .in,
            prev: "",
            bytes: ""
        )
        let sealed = try SessionLogCrypto.seal(record: record, using: goodKey)
        XCTAssertThrowsError(try SessionLogCrypto.open(encrypted: sealed, using: wrongKey)) { error in
            XCTAssertEqual(error as? SessionLogCryptoError, .openAuthenticationFailed)
        }
    }

    // MARK: Chain validation — clean

    func testValidateChainAcceptsCleanChain() throws {
        let key = SymmetricKey(size: .bits256)
        // Empty arrangement first: zero-record chain is the boundary
        // case that drives the `.valid(0, "")` return.
        XCTAssertEqual(
            SessionLogCrypto.validateChain(records: [], using: key),
            .valid(recordCount: 0, chainHeadHash: "")
        )

        let records = try makeChain(of: 5, key: key)
        let result = SessionLogCrypto.validateChain(records: records, using: key)
        guard case .valid(let count, let head) = result else {
            return XCTFail("Expected .valid, got \(result)")
        }
        XCTAssertEqual(count, 5)
        XCTAssertEqual(head, SessionLogCrypto.chainHash(of: records.last!))
    }

    // MARK: Chain validation — tamper detection

    func testValidateChainDetectsSingleByteTamperAsAuthenticationFailure() throws {
        let key = SymmetricKey(size: .bits256)
        var records = try makeChain(of: 4, key: key)

        // Flip the last byte of record index 2. AES.GCM's authentication
        // tag covers every ciphertext byte, so any flip triggers a tag
        // mismatch.
        var tampered = records[2]
        let last = tampered.endIndex - 1
        tampered[last] ^= 0x01
        records[2] = tampered

        let result = SessionLogCrypto.validateChain(records: records, using: key)
        XCTAssertEqual(
            result,
            .brokenAt(seq: 2, reason: .ciphertextAuthenticationFailed)
        )
    }

    func testValidateChainDetectsReorderingAsPrevHashMismatch() throws {
        let key = SymmetricKey(size: .bits256)
        var records = try makeChain(of: 4, key: key)
        records.swapAt(1, 2)
        let result = SessionLogCrypto.validateChain(records: records, using: key)
        // After swap, the record at index 1 used to be at index 2 and
        // expected the original index-1 hash as its prev. Now the actual
        // previous record at on-disk index 0 produces a different hash.
        // The record also still claims seq=2, so seqOutOfSequence fires
        // before prevHashMismatch can be evaluated.
        guard case .brokenAt(_, let reason) = result else {
            return XCTFail("Expected .brokenAt, got \(result)")
        }
        XCTAssertTrue(
            reason == .prevHashMismatch || reason == .seqOutOfSequence,
            "Reordering must surface as a chain break; saw \(reason)"
        )
    }

    func testValidateChainDetectsDeletionAsSeqOutOfSequence() throws {
        let key = SymmetricKey(size: .bits256)
        var records = try makeChain(of: 4, key: key)
        // Remove the middle record. The next surviving record still
        // claims seq=2 but is now at on-disk index 1, where we expect
        // seq=1.
        records.remove(at: 1)
        let result = SessionLogCrypto.validateChain(records: records, using: key)
        guard case .brokenAt(_, let reason) = result else {
            return XCTFail("Expected .brokenAt, got \(result)")
        }
        XCTAssertEqual(reason, .seqOutOfSequence)
    }

    // MARK: Wrap / unwrap

    func testWrapUnwrapRoundTripWithSoftwareKey() throws {
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        let sessionKey = SymmetricKey(size: .bits256)

        let wrapped = try SessionLogCrypto.wrap(
            sessionKey: sessionKey,
            to: wrappingPriv.publicKey
        )

        // Wire-format sanity: 65-byte ephemeral SEC1 prefix.
        XCTAssertEqual(wrapped.ephemeralPublicKeyX963.count, 65)
        XCTAssertEqual(wrapped.ephemeralPublicKeyX963.first, 0x04)

        let recovered = try SessionLogCrypto.unwrap(wrapped, with: wrappingPriv)
        XCTAssertEqual(
            recovered.withUnsafeBytes { Data($0) },
            sessionKey.withUnsafeBytes { Data($0) }
        )
    }

    func testWrapUnwrapEncodeDecodeRoundTrip() throws {
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        let sessionKey = SymmetricKey(size: .bits256)

        let wrapped = try SessionLogCrypto.wrap(
            sessionKey: sessionKey,
            to: wrappingPriv.publicKey
        )
        let encoded = wrapped.encode()

        // Should be at least 65 (ephemeral) + 16 (AES.GCM tag) + 12
        // (nonce) + 32 (sealed session key) = 125 bytes; the actual
        // length is fixed by CryptoKit's SealedBox.combined layout.
        XCTAssertGreaterThanOrEqual(encoded.count, 65 + 12 + 32 + 16)

        let decoded = try WrappedSessionKey.decode(encoded)
        XCTAssertEqual(decoded, wrapped)

        let recovered = try SessionLogCrypto.unwrap(decoded, with: wrappingPriv)
        XCTAssertEqual(
            recovered.withUnsafeBytes { Data($0) },
            sessionKey.withUnsafeBytes { Data($0) }
        )
    }

    func testUnwrapWithWrongPrivateKeyFailsAsAuthenticationFailure() throws {
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        let otherPriv = P256.KeyAgreement.PrivateKey()
        let sessionKey = SymmetricKey(size: .bits256)
        let wrapped = try SessionLogCrypto.wrap(
            sessionKey: sessionKey,
            to: wrappingPriv.publicKey
        )
        XCTAssertThrowsError(try SessionLogCrypto.unwrap(wrapped, with: otherPriv)) { error in
            XCTAssertEqual(error as? SessionLogCryptoError, .openAuthenticationFailed)
        }
    }

    func testWrappedSessionKeyDecodeRejectsShortBlob() {
        let tooShort = Data(repeating: 0x04, count: 64)
        XCTAssertThrowsError(try WrappedSessionKey.decode(tooShort)) { error in
            XCTAssertEqual(error as? SessionLogCryptoError, .wrappedKeyMalformed)
        }
    }

    func testWrappedSessionKeyDecodeRejectsInvalidSEC1Indicator() {
        // 65 bytes that don't start with the SEC1 uncompressed indicator
        // (0x04) — would otherwise pass into the ECDH path and produce a
        // confusing error.
        let bad = Data([0x02]) + Data(repeating: 0x00, count: 64) + Data(repeating: 0xff, count: 32)
        XCTAssertThrowsError(try WrappedSessionKey.decode(bad)) { error in
            XCTAssertEqual(error as? SessionLogCryptoError, .wrappedKeyMalformed)
        }
    }

    // MARK: Helpers

    /// Build `count` records sealed under `key`, with a correct hash
    /// chain. The bytes payload is unique per record so the SealedBox
    /// nonces produce distinct hashes (which they would anyway, but it
    /// makes test failures easier to read).
    private func makeChain(of count: Int, key: SymmetricKey) throws -> [Data] {
        var combined: [Data] = []
        var previousHash = ""
        for i in 0..<count {
            let record = SessionLogRecord(
                seq: UInt64(i),
                ts: "2026-05-26T03:41:12.\(String(format: "%03d", i))Z",
                dir: i % 2 == 0 ? .in : .out,
                prev: previousHash,
                bytes: Data("payload-\(i)".utf8).base64EncodedString()
            )
            let sealed = try SessionLogCrypto.seal(record: record, using: key)
            combined.append(sealed.sealedCombined)
            previousHash = SessionLogCrypto.chainHash(of: sealed.sealedCombined)
        }
        return combined
    }
}
