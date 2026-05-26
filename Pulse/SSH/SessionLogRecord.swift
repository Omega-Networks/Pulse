//
//  SessionLogRecord.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Pulse
//  The Platform for Unified Leadership in Smart Environments.
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

// MARK: - SessionLogRecord

/// Plaintext envelope sealed into a single line of a `.pulselog` file.
///
/// The envelope is `Codable` for ergonomics but the chain-hash discipline
/// is structural: `prev` is always computed from the previous record's
/// raw on-disk `AES.GCM.SealedBox.combined` bytes (see
/// ``SessionLogCrypto/chainHash(of:)``), never from a re-encode of a
/// decoded `SessionLogRecord`. Any path that round-trips through
/// `JSONDecoder` then `JSONEncoder` to derive the next `prev` is a
/// future-`JSONEncoder`-update timebomb: a Foundation patch that changes
/// key ordering, escaping, or number formatting silently invalidates every
/// historical log. The pure-function surface deliberately exposes only
/// `chainHash(of: Data)` operating on raw bytes; there is no
/// `SessionLogRecord`-typed re-encode helper.
///
/// JSON keys are kept short and `snake_case` because `.meta` sidecar
/// readers (a future operator-facing browser, off-device SIEM forwarders)
/// will read them out of band; matching the `.meta` convention keeps the
/// two schemas legible side by side. The `JSONEncoder.OutputFormatting`
/// for writing always includes `.sortedKeys` so each record's plaintext
/// bytes are deterministic — important for reproducible builds of the
/// hash chain over the same input.
struct SessionLogRecord: Codable, Equatable, Sendable {

    /// Monotonic counter from 0. The first record in a session is `seq = 0`
    /// and carries `prev = ""`.
    let seq: UInt64

    /// ISO 8601 timestamp with fractional seconds, e.g. `2026-05-26T03:41:12.184Z`.
    let ts: String

    /// Direction of the byte chunk relative to the SSH client.
    let dir: Direction

    /// Hex-lowercase SHA-256 of the previous record's `AES.GCM.SealedBox.combined`
    /// bytes (`nonce || ciphertext || tag`). Empty string when `seq == 0`.
    let prev: String

    /// Base64-encoded raw byte chunk that flowed in this `dir`.
    let bytes: String

    /// Direction of byte flow. `out` is bytes the client wrote to the server
    /// (input typed by the operator); `in` is bytes the server wrote back
    /// (output rendered into the terminal). The naming follows the
    /// operator's perspective rather than NIO's channel-direction
    /// vocabulary because operator-facing replay reads more naturally
    /// when "in" is "things that came back at me".
    enum Direction: String, Codable, Sendable {
        case `in`
        case out
    }

    private enum CodingKeys: String, CodingKey {
        case seq
        case ts
        case dir
        case prev
        case bytes
    }
}

// MARK: - EncryptedRecord

/// Newtype wrapping the ciphertext form of a `SessionLogRecord`.
///
/// This is the only thing `SessionLogWriter.write` accepts. Plaintext
/// `SessionLogRecord` instances have no path to disk; to obtain an
/// `EncryptedRecord` the caller must go through
/// ``SessionLogCrypto/seal(record:using:)``, which is the single
/// chokepoint where session bytes meet a sealing primitive. The
/// structural ADR §6 guarantee ("no plaintext log is ever written to
/// disk") rides on the writer's signature accepting only this type.
struct EncryptedRecord: Sendable, Equatable {
    /// `AES.GCM.SealedBox.combined`: `nonce || ciphertext || tag`. This
    /// is the exact byte sequence written to a `.pulselog` line (after
    /// base64 encoding for JSONL framing) and the exact byte sequence
    /// hashed by the chain.
    let sealedCombined: Data
}

// MARK: - WrappedSessionKey

/// Header-borne envelope wrapping the per-session AES key to the device's
/// Secure-Enclave-resident log wrapping key.
///
/// The wire shape is `ephemeralPublicKeyX963 (65 bytes) || sealedSessionKey`.
/// Unwrapping requires the recipient to perform ECDH against the SE key,
/// which triggers a biometric / passcode prompt. See ``SessionLogCrypto/wrap(sessionKey:to:)``
/// and ``SessionLogCrypto/unwrap(_:with:)``.
struct WrappedSessionKey: Sendable, Equatable {
    /// `x963Representation` of the ephemeral `P256.KeyAgreement.PublicKey`
    /// generated for this session. 65 bytes: `0x04 || X(32) || Y(32)`.
    let ephemeralPublicKeyX963: Data

    /// `AES.GCM.SealedBox.combined` over the 32 bytes of session-key
    /// material, using the HKDF-SHA256-derived KEK as the symmetric key.
    let sealedSessionKey: Data

    /// Serialised wire form: ephemeral pub bytes followed by sealed key.
    /// This is the byte sequence the `.pulselog` header carries as a
    /// base64 string.
    func encode() -> Data {
        ephemeralPublicKeyX963 + sealedSessionKey
    }

    /// Parse the wire form back into the two halves. Errors if the prefix
    /// isn't a valid 65-byte SEC1 uncompressed point — caught early so
    /// a corrupted header doesn't reach the ECDH path.
    static func decode(_ data: Data) throws -> WrappedSessionKey {
        guard data.count > 65 else {
            throw SessionLogCryptoError.wrappedKeyMalformed
        }
        let ephemeral = data.prefix(65)
        guard ephemeral.first == 0x04 else {
            throw SessionLogCryptoError.wrappedKeyMalformed
        }
        let sealed = data.suffix(from: data.startIndex.advanced(by: 65))
        return WrappedSessionKey(
            ephemeralPublicKeyX963: Data(ephemeral),
            sealedSessionKey: Data(sealed)
        )
    }
}

// MARK: - Chain validation

/// Outcome of running ``SessionLogCrypto/validateChain(records:)`` against
/// a sequence of on-disk records.
enum ChainValidationResult: Equatable, Sendable {
    /// Every record's `prev` matched the hash of the previous record's
    /// raw on-disk bytes, and `seq` values increment monotonically from 0.
    case valid(recordCount: UInt64, chainHeadHash: String)

    /// Chain validation failed at the named `seq`. No plaintext from this
    /// record or any subsequent record should be exposed to the operator —
    /// the replay surface enforces this by halting before yielding any
    /// further bytes.
    case brokenAt(seq: UInt64, reason: ChainBreakReason)
}

enum ChainBreakReason: Equatable, Sendable {
    /// The record's `prev` field didn't match the hash of the previous
    /// record's raw on-disk bytes. Indicates insertion, deletion, or
    /// reordering of records on disk.
    case prevHashMismatch
    /// The `seq` field was not exactly `previousSeq + 1` (or not `0` for
    /// the first record). Indicates a deleted record or hand-edited
    /// numbering.
    case seqOutOfSequence
    /// The record's ciphertext failed AES.GCM authentication. Indicates
    /// either tampering with the byte payload or use of the wrong key.
    case ciphertextAuthenticationFailed
    /// The decoded record didn't parse as a `SessionLogRecord`. Indicates
    /// envelope corruption after authenticated decryption — which is
    /// unusual but possible if a future schema migration is partially
    /// applied.
    case envelopeDecodeFailed
}

// MARK: - Errors

enum SessionLogCryptoError: Error, CustomStringConvertible, Equatable {
    case encodingFailed(String)
    case sealFailed(String)
    case openAuthenticationFailed
    case decodingFailed(String)
    case wrappedKeyMalformed
    case ephemeralPublicKeyMalformed
    case keyDerivationFailed(String)
    case sessionKeyMaterialMalformed

    var description: String {
        switch self {
        case .encodingFailed(let reason):
            return "Failed to JSON-encode SessionLogRecord: \(reason)"
        case .sealFailed(let reason):
            return "AES.GCM.seal failed: \(reason)"
        case .openAuthenticationFailed:
            return "AES.GCM authentication tag mismatch — record bytes are not what was sealed"
        case .decodingFailed(let reason):
            return "Failed to JSON-decode SessionLogRecord after authenticated decryption: \(reason)"
        case .wrappedKeyMalformed:
            return "Wrapped session key blob is shorter than the 65-byte ephemeral public key prefix or has an invalid SEC1 indicator"
        case .ephemeralPublicKeyMalformed:
            return "Ephemeral P256 public key bytes are not a valid SEC1 uncompressed point"
        case .keyDerivationFailed(let reason):
            return "HKDF<SHA256> session-key derivation failed: \(reason)"
        case .sessionKeyMaterialMalformed:
            return "Unwrapped session key material was not exactly 32 bytes (256 bits)"
        }
    }
}

// MARK: - SessionLogCrypto

/// Pure-function surface for the per-record encryption, chain-hash, and
/// session-key wrapping primitives.
///
/// No file I/O, no actors, no Keychain calls — every function here is
/// disk-free and unit-testable end to end. The Secure-Enclave side of
/// unwrapping lives in `SessionLogWrappingKey`; this type only accepts a
/// fully-materialised `SecureEnclave.P256.KeyAgreement.PrivateKey`
/// handle from the caller, which keeps the cryptographic algebra
/// testable against a pure CryptoKit equivalent.
enum SessionLogCrypto {

    // MARK: Per-record sealing

    /// Algorithm identifier the `.pulselog` header advertises. Centralised
    /// here so header writers and parsers can't drift.
    static let algorithmIdentifier = "AES.GCM-256/HKDF-SHA256/ECDH-P256-SE"

    /// HKDF info parameter for the wrapping-key derivation. Versioned in
    /// the string itself so a future format bump can introduce a v2
    /// without losing backward decode compatibility for v1 logs.
    static let wrappingKDFInfo = Data("Pulse.SessionLog.WrappingKey.v1".utf8)

    /// Size of the per-session AES-GCM symmetric key, in bits.
    static let sessionKeyBitWidth = 256

    /// JSON-encode a `SessionLogRecord` deterministically. Sorted keys
    /// make the plaintext bytes byte-identical across two encodes of the
    /// same record — the property the chain hash relies on for any test
    /// that round-trips an envelope through encode then re-encode for
    /// vector comparison. (Chain hash itself does not re-encode; this
    /// determinism is for tests and debugging diff readability.)
    static func encode(_ record: SessionLogRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(record)
        } catch {
            throw SessionLogCryptoError.encodingFailed(String(describing: error))
        }
    }

    /// Decode a record from its plaintext JSON form. Used after
    /// authenticated decryption inside ``open(encrypted:using:)``.
    static func decode(_ data: Data) throws -> SessionLogRecord {
        do {
            return try JSONDecoder().decode(SessionLogRecord.self, from: data)
        } catch {
            throw SessionLogCryptoError.decodingFailed(String(describing: error))
        }
    }

    /// Seal a record under the per-session symmetric key, returning the
    /// ciphertext newtype. A fresh `AES.GCM.Nonce()` is generated per
    /// call; the nonce travels inside `SealedBox.combined` so callers
    /// never need to track it separately. This is the only function in
    /// the slice that produces `EncryptedRecord`; `SessionLogWriter.write`
    /// is typed to accept nothing else.
    static func seal(record: SessionLogRecord, using key: SymmetricKey) throws -> EncryptedRecord {
        let plaintext = try encode(record)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else {
                // AES.GCM.SealedBox.combined is documented to be non-nil
                // when the nonce is the default 12-byte length, which is
                // what AES.GCM.seal(_:using:) without an explicit nonce
                // produces. Treat a nil result as a CryptoKit-internal
                // failure rather than a user error.
                throw SessionLogCryptoError.sealFailed("SealedBox.combined was nil")
            }
            return EncryptedRecord(sealedCombined: combined)
        } catch let error as SessionLogCryptoError {
            throw error
        } catch {
            throw SessionLogCryptoError.sealFailed(String(describing: error))
        }
    }

    /// Reverse of ``seal(record:using:)``. Throws
    /// `.openAuthenticationFailed` on tag mismatch (a single flipped byte
    /// in the on-disk record is enough to trigger this) and
    /// `.decodingFailed` if the authenticated plaintext doesn't parse as
    /// a `SessionLogRecord`. The two cases are kept distinct so the
    /// replay path can fire the correct `ChainBreakReason`.
    static func open(encrypted: EncryptedRecord, using key: SymmetricKey) throws -> SessionLogRecord {
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: encrypted.sealedCombined)
        } catch {
            throw SessionLogCryptoError.openAuthenticationFailed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw SessionLogCryptoError.openAuthenticationFailed
        }
        return try decode(plaintext)
    }

    // MARK: Hash chain

    /// Hex-lowercase SHA-256 of the input bytes. Operates on raw bytes
    /// only — there is deliberately no overload accepting
    /// `SessionLogRecord` because the chain must hash the on-disk
    /// ciphertext, not a re-encode of a decoded envelope.
    static func chainHash(of combined: Data) -> String {
        let digest = SHA256.hash(data: combined)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Validate the hash chain over a contiguous sequence of on-disk
    /// records. The caller passes the raw `SealedBox.combined` bytes in
    /// the order they appear in the `.pulselog` (after the header line);
    /// validation decodes each record under `key` and checks both `seq`
    /// continuity and `prev` against the previous record's hash.
    ///
    /// Returns `.valid` with the final chain-head hash for `.meta`
    /// finalisation, or `.brokenAt(seq:reason:)` at the first divergence.
    /// On a break, callers must halt before yielding any further plaintext
    /// to the operator: the replay path enforces this.
    static func validateChain(records: [Data], using key: SymmetricKey) -> ChainValidationResult {
        var previousHash: String = ""
        var previousSeq: UInt64 = 0
        var chainHead: String = ""
        var count: UInt64 = 0

        for (index, combined) in records.enumerated() {
            let expectedSeq = UInt64(index)
            let recordIdentity = previousSeq

            let record: SessionLogRecord
            do {
                record = try open(
                    encrypted: EncryptedRecord(sealedCombined: combined),
                    using: key
                )
            } catch SessionLogCryptoError.openAuthenticationFailed {
                return .brokenAt(seq: expectedSeq, reason: .ciphertextAuthenticationFailed)
            } catch SessionLogCryptoError.decodingFailed {
                return .brokenAt(seq: expectedSeq, reason: .envelopeDecodeFailed)
            } catch {
                return .brokenAt(seq: expectedSeq, reason: .ciphertextAuthenticationFailed)
            }

            if record.seq != expectedSeq {
                return .brokenAt(seq: record.seq, reason: .seqOutOfSequence)
            }
            if record.prev != previousHash {
                return .brokenAt(seq: record.seq, reason: .prevHashMismatch)
            }
            _ = recordIdentity

            previousHash = chainHash(of: combined)
            previousSeq = record.seq
            chainHead = previousHash
            count += 1
        }

        return .valid(recordCount: count, chainHeadHash: chainHead)
    }

    // MARK: Session-key wrapping (ECDH + HKDF + AES.GCM)

    /// Wrap a per-session AES key to the device's SE-resident log
    /// wrapping public key. Generates an ephemeral
    /// `P256.KeyAgreement.PrivateKey`, runs ECDH against the SE wrapping
    /// public key, derives a 256-bit KEK via `HKDF<SHA256>`, then
    /// `AES.GCM.seal`s the session-key material. The returned
    /// `WrappedSessionKey` is what the `.pulselog` header carries.
    ///
    /// Pure: no Keychain calls, no biometric prompts. The wrapping
    /// public key is passed in by the caller; obtaining it (via
    /// `SessionLogWrappingKey.publicKey()`) does not require biometric.
    static func wrap(
        sessionKey: SymmetricKey,
        to wrappingPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> WrappedSessionKey {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared: SharedSecret
        do {
            shared = try ephemeral.sharedSecretFromKeyAgreement(with: wrappingPublicKey)
        } catch {
            throw SessionLogCryptoError.keyDerivationFailed(String(describing: error))
        }
        let kek = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: wrappingKDFInfo,
            outputByteCount: 32
        )
        let keyMaterial = sessionKey.withUnsafeBytes { Data($0) }
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(keyMaterial, using: kek)
        } catch {
            throw SessionLogCryptoError.sealFailed(String(describing: error))
        }
        guard let combined = sealed.combined else {
            throw SessionLogCryptoError.sealFailed("SealedBox.combined was nil during wrap")
        }
        return WrappedSessionKey(
            ephemeralPublicKeyX963: ephemeral.publicKey.x963Representation,
            sealedSessionKey: combined
        )
    }

    /// Reverse of ``wrap(sessionKey:to:)``. The SE private key parameter
    /// is the seam where biometric fires in production: CryptoKit's
    /// `SecureEnclave.P256.KeyAgreement.PrivateKey.sharedSecretFromKeyAgreement(with:)`
    /// triggers `LAContext` internally on first use.
    ///
    /// Returns the recovered 256-bit `SymmetricKey`. Throws on a bad
    /// ephemeral pub, an authentication-tag mismatch on the wrapped
    /// blob, or a length-mismatch on the recovered key material.
    static func unwrap(
        _ wrapped: WrappedSessionKey,
        with wrappingPrivateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
    ) throws -> SymmetricKey {
        let ephemeralPub = try ephemeralPublicKey(from: wrapped)
        let shared: SharedSecret
        do {
            shared = try wrappingPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPub)
        } catch {
            throw SessionLogCryptoError.keyDerivationFailed(String(describing: error))
        }
        return try completeUnwrap(wrapped, sharedSecret: shared)
    }

    /// Software-keyed unwrap overload. Provided as a test seam: the SE
    /// and software `P256.KeyAgreement` paths run identical algebra, so
    /// wrapping-key round-trip coverage can exercise the full
    /// `wrap → unwrap` contract without provisioning a real Secure
    /// Enclave and biometric. Production code never calls this overload
    /// (the SSH connect path always carries an
    /// `SecureEnclave.P256.KeyAgreement.PrivateKey` from
    /// `SessionLogWrappingKey`). Marked `internal` so it is reachable
    /// only from `@testable import Pulse`.
    static func unwrap(
        _ wrapped: WrappedSessionKey,
        with wrappingPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> SymmetricKey {
        let ephemeralPub = try ephemeralPublicKey(from: wrapped)
        let shared: SharedSecret
        do {
            shared = try wrappingPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPub)
        } catch {
            throw SessionLogCryptoError.keyDerivationFailed(String(describing: error))
        }
        return try completeUnwrap(wrapped, sharedSecret: shared)
    }

    // MARK: Unwrap helpers (private)

    private static func ephemeralPublicKey(
        from wrapped: WrappedSessionKey
    ) throws -> P256.KeyAgreement.PublicKey {
        do {
            return try P256.KeyAgreement.PublicKey(
                x963Representation: wrapped.ephemeralPublicKeyX963
            )
        } catch {
            throw SessionLogCryptoError.ephemeralPublicKeyMalformed
        }
    }

    private static func completeUnwrap(
        _ wrapped: WrappedSessionKey,
        sharedSecret: SharedSecret
    ) throws -> SymmetricKey {
        let kek = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: wrappingKDFInfo,
            outputByteCount: 32
        )
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: wrapped.sealedSessionKey)
        } catch {
            throw SessionLogCryptoError.openAuthenticationFailed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: kek)
        } catch {
            throw SessionLogCryptoError.openAuthenticationFailed
        }
        guard plaintext.count == 32 else {
            throw SessionLogCryptoError.sessionKeyMaterialMalformed
        }
        return SymmetricKey(data: plaintext)
    }
}

// MARK: - ISO8601 helper

/// ISO 8601 formatter shared by record producers. Fractional seconds
/// keep the chronology precise enough that two records emitted by the
/// same `Task` continuation within the same millisecond can still be
/// ordered if needed; sub-millisecond ordering falls back to `seq`.
///
/// Uses `Date.ISO8601FormatStyle` (value type, `Sendable`) rather than
/// the reference-type `ISO8601DateFormatter` — the latter is not
/// `Sendable`, which would force either a `nonisolated(unsafe)` static
/// cache or per-call allocation. The format-style API is the modern
/// Apple-recommended path and produces byte-identical output to
/// `ISO8601DateFormatter` with `[.withInternetDateTime, .withFractionalSeconds]`.
enum SessionLogTimestamp {
    private static let style: Date.ISO8601FormatStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )

    static func iso8601(from date: Date) -> String {
        style.format(date)
    }
}
