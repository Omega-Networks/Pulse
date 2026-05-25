//
//  SessionLogReplay.swift
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

/// Reads an encrypted `.pulselog` from disk, unwraps its session key
/// via the SE-resident wrapping key (biometric fires here), validates
/// the hash chain, and returns the recovered plaintext records.
///
/// The replay surface enforces ADR §6's tamper-detection contract:
/// no plaintext from a tampered record (or any record after it)
/// reaches the operator. The returned `records` array stops at the
/// first chain break.
///
/// Two audit events fire over the lifecycle of a replay (per the
/// plan-lock split):
///
/// - `session.recording.replayUnwrapped` on biometric success.
///   Operator access to a recorded log is security-relevant
///   independent of file integrity; this event fires regardless of
///   whether the chain validates.
/// - `session.recording.replayChainBroken` if chain validation
///   fails. Distinct event so any future SIEM rule can fire cleanly
///   on tamper-after-access.
enum SessionLogReplay {

    // MARK: - Errors

    enum ReplayError: Error, CustomStringConvertible, Equatable {
        case pulselogReadFailed(String)
        case headerLineMissing
        case headerDecodeFailed(String)
        case wrappedKeyBase64Malformed
        case wrappedKeyEnvelopeMalformed
        case sessionKeyUnwrapFailed(String)

        var description: String {
            switch self {
            case .pulselogReadFailed(let reason):
                return "Failed to read .pulselog file: \(reason)"
            case .headerLineMissing:
                return ".pulselog file did not start with a header line"
            case .headerDecodeFailed(let reason):
                return "Failed to decode .pulselog header: \(reason)"
            case .wrappedKeyBase64Malformed:
                return "Wrapped session key in header is not valid base64"
            case .wrappedKeyEnvelopeMalformed:
                return "Wrapped session key bytes did not parse as a 65-byte ephemeral pub + sealed key envelope"
            case .sessionKeyUnwrapFailed(let reason):
                return "Could not unwrap the session key against the SE wrapping key (biometric likely cancelled): \(reason)"
            }
        }
    }

    // MARK: - LoadedSession

    /// Result of a successful unwrap + chain validation pass over a
    /// `.pulselog` file.
    struct LoadedSession: Sendable, Equatable {
        /// Parsed header (version, session ID, algorithm identifier).
        let header: PulselogHeader

        /// Outcome of the hash-chain validator. `.valid` carries the
        /// expected record count and final chain-head hash. `.brokenAt`
        /// carries the seq number of the first record that failed
        /// validation and the structural reason.
        let validation: ChainValidationResult

        /// Plaintext records up to (and NOT including) the first chain
        /// break. On `.valid`, this is every record in the file. On
        /// `.brokenAt(seq:)`, this is records `[0, seq)` — the prefix
        /// the chain validator was able to verify. Records from the
        /// break onwards are deliberately withheld per ADR §6's "no
        /// plaintext exposure" rule.
        let plaintextRecords: [SessionLogRecord]
    }

    // MARK: - Load

    /// Read the `.pulselog` at `pulselogURL` and decrypt every record
    /// the chain validator accepts.
    ///
    /// `sessionID` is used only for the audit events; it's read from
    /// the matching `.meta` sidecar by the caller (the replay UI
    /// typically already has it on hand).
    ///
    /// `unwrapSessionKey` is the seam where biometric fires in
    /// production — the default closure loads the SE-resident
    /// wrapping key and runs the ECDH-based unwrap, which triggers
    /// `LAContext` inside CryptoKit. Tests pass a closure that uses
    /// a software `P256.KeyAgreement.PrivateKey` so the full
    /// load → validate → expose flow can run without provisioning a
    /// real Secure Enclave or attended biometric.
    static func load(
        pulselogURL: URL,
        sessionID: UUID,
        unwrapSessionKey: (WrappedSessionKey) throws -> SymmetricKey = { wrapped in
            let wrappingKey = try SessionLogWrappingKey.loadOrCreate()
            return try SessionLogCrypto.unwrap(wrapped, with: wrappingKey)
        }
    ) async throws -> LoadedSession {
        // 1. Read the .pulselog as a single Data blob.
        let data: Data
        do {
            data = try Data(contentsOf: pulselogURL)
        } catch {
            throw ReplayError.pulselogReadFailed(String(describing: error))
        }

        // 2. Split into lines. JSONL: \n-separated. The first line is
        // the header; subsequent lines are base64(SealedBox.combined).
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let headerLine = lines.first else {
            throw ReplayError.headerLineMissing
        }

        // 3. Decode the header and parse the wrapped key envelope.
        let header: PulselogHeader
        do {
            header = try JSONDecoder().decode(PulselogHeader.self, from: Data(headerLine))
        } catch {
            throw ReplayError.headerDecodeFailed(String(describing: error))
        }
        guard let wrappedData = Data(base64Encoded: header.wrapped_key_b64) else {
            throw ReplayError.wrappedKeyBase64Malformed
        }
        let wrapped: WrappedSessionKey
        do {
            wrapped = try WrappedSessionKey.decode(wrappedData)
        } catch {
            throw ReplayError.wrappedKeyEnvelopeMalformed
        }

        // 4. Unwrap the session key. The default closure loads the
        // SE wrapping key and runs ECDH — biometric fires inside
        // CryptoKit's sharedSecretFromKeyAgreement.
        let sessionKey: SymmetricKey
        do {
            sessionKey = try unwrapSessionKey(wrapped)
        } catch {
            throw ReplayError.sessionKeyUnwrapFailed(String(describing: error))
        }

        // 5. Biometric succeeded. Audit access independent of chain
        // validation outcome — the fact that an operator just read
        // this log is the security-relevant signal here.
        SessionRecordingAudit.replayUnwrapped(sessionID: sessionID)

        // 6. Decode each record line as base64 → SealedBox.combined.
        var combined: [Data] = []
        combined.reserveCapacity(lines.count - 1)
        for rawLine in lines.dropFirst() {
            let s = String(data: Data(rawLine), encoding: .utf8) ?? ""
            if let bytes = Data(base64Encoded: s) {
                combined.append(bytes)
            }
        }

        // 7. Validate the chain. On break, .brokenAt(seq:) tells us
        // the index of the first bad record; we expose records [0, seq).
        let validation = SessionLogCrypto.validateChain(records: combined, using: sessionKey)
        let validPrefixCount: Int
        switch validation {
        case .valid(let count, _):
            validPrefixCount = Int(count)
        case .brokenAt(let seq, _):
            validPrefixCount = Int(seq)
            SessionRecordingAudit.replayChainBroken(
                sessionID: sessionID,
                brokenAtSeq: seq
            )
        }

        // 8. Decrypt only the verified prefix. Records past the break
        // are deliberately not opened — no plaintext exposure per
        // ADR §6.
        var plaintext: [SessionLogRecord] = []
        plaintext.reserveCapacity(validPrefixCount)
        for i in 0..<validPrefixCount {
            do {
                let record = try SessionLogCrypto.open(
                    encrypted: EncryptedRecord(sealedCombined: combined[i]),
                    using: sessionKey
                )
                plaintext.append(record)
            } catch {
                // Shouldn't happen — the chain validator already
                // round-tripped these. Defensive: stop here.
                break
            }
        }

        return LoadedSession(
            header: header,
            validation: validation,
            plaintextRecords: plaintext
        )
    }
}
