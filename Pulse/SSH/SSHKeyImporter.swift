//
//  SSHKeyImporter.swift
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
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import OSLog

/// Validates and classifies portable (legacy-tier) SSH private keys imported from PEM
/// or OpenSSH armor. Stores the normalised PEM via `Configuration.setSSHPrivateKeyPEM`.
///
/// The importer's scope is structural: detect the armor, decode the base64 payload,
/// classify the algorithm cheaply, and surface whether the key is encrypted so the UI
/// can prompt for a passphrase. The full cryptographic decode (RSA modulus / EC point /
/// Ed25519 scalar) happens later in the signing pipeline, not here. Splitting the work
/// this way keeps the import UX free of any SSH-library dependency.
enum SSHKeyImporter {

    // MARK: - Result types

    /// Outcome of inspecting a pasted/loaded private key string.
    struct ImportedSSHKey {
        let pemKind: PEMKind
        let algorithm: Algorithm
        /// PEM normalised to LF line endings and Unix trailing newline. Safe to store
        /// directly via `Configuration.setSSHPrivateKeyPEM`.
        let normalisedPEM: String
        /// `Data`-encoded view of `normalisedPEM` for callers that want to keep
        /// the secret material out of an unzeroable `String`. The import sheet
        /// reads this and dispatches to `Configuration`'s `Data` setters so the
        /// PEM never round-trips through `String` after the user paste-buffer
        /// is classified.
        let normalisedPEMData: Data
        /// True when the armor or inner cipher field indicates the key needs a
        /// passphrase to decrypt. Drives the second prompt in the import sheet.
        let isEncrypted: Bool
    }

    enum PEMKind: String, Sendable {
        case opensshPrivate     = "OPENSSH PRIVATE KEY"
        case rsaPrivate         = "RSA PRIVATE KEY"
        case ecPrivate          = "EC PRIVATE KEY"
        case dsaPrivate         = "DSA PRIVATE KEY"
        case pkcs8              = "PRIVATE KEY"
        case encryptedPkcs8     = "ENCRYPTED PRIVATE KEY"
    }

    enum Algorithm: String, Sendable {
        case ed25519
        case ecdsaP256
        case ecdsaP384
        case ecdsaP521
        /// Traditional `BEGIN EC PRIVATE KEY` PEMs identify the curve via an OID
        /// inside the SEC1 ASN.1 payload, which this importer doesn't decode.
        /// Surface the family without claiming a specific curve so the import UI
        /// stays truthful; the signer narrows this to a specific curve when it
        /// parses the SEC1 payload for actual signing.
        case ecdsaUnknownCurve
        case rsa
        case dsa
        case unknown

        var displayName: String {
            switch self {
            case .ed25519:            return "Ed25519"
            case .ecdsaP256:          return "ECDSA P-256"
            case .ecdsaP384:          return "ECDSA P-384"
            case .ecdsaP521:          return "ECDSA P-521"
            case .ecdsaUnknownCurve:  return "ECDSA (curve detected at sign time)"
            case .rsa:                return "RSA"
            case .dsa:                return "DSA"
            case .unknown:            return "Unknown algorithm"
            }
        }
    }

    // MARK: - Errors

    enum ImporterError: Error, CustomStringConvertible, Equatable {
        case empty
        case noPEMArmorFound
        case mismatchedArmor
        case unsupportedKeyKind(PEMKind)
        case payloadNotBase64
        case truncatedOpenSSHKey
        /// Algorithm classified successfully but the v1 portable tier doesn't
        /// sign with it. `remediation` is operator-facing next-step copy.
        /// See ADR 0001 §1 v1 portable scope amendment.
        case unsupportedAlgorithmInV1(name: String, remediation: String)
        /// Encrypted portable keys aren't supported in v1: the KDFs needed to
        /// decrypt them (bcrypt-pbkdf for OpenSSH new-format, PBKDF2 for
        /// encrypted PKCS#8) fall on the wrong side of §10's third-party-crypto
        /// prohibition. `remediation` tells the operator how to re-export
        /// without the passphrase.
        case encryptedPortableKeyNotSupportedInV1(remediation: String)
        /// `derivePublicKey(from:)` can't recover the public key from the
        /// imported PEM without information that isn't present at import time
        /// (e.g., the passphrase for an encrypted private half, or a public
        /// point not embedded in the SEC1 payload). Not an error condition for
        /// the operator: the credential is stored with an empty `publicKey`
        /// placeholder and the auth delegate backfills at first use.
        case publicKeyDerivationDeferred
        /// The PEM kind is recognised but Pulse v1 doesn't implement public-key
        /// derivation for it (traditional `BEGIN EC PRIVATE KEY` is the
        /// realistic case). Signer integration may derive lazily.
        case publicKeyDerivationNotSupported(reason: String)

        var description: String {
            switch self {
            case .empty:
                return "No key material provided."
            case .noPEMArmorFound:
                return "Couldn't find a PEM ‘BEGIN/END’ block. Paste the full key including header and footer."
            case .mismatchedArmor:
                return "The PEM BEGIN and END markers don't match."
            case .unsupportedKeyKind(let kind):
                return "PEM kind \(kind.rawValue) isn't supported in v1."
            case .payloadNotBase64:
                return "The PEM body isn't valid base64."
            case .truncatedOpenSSHKey:
                return "OpenSSH-format key is truncated: the ‘openssh-key-v1’ payload is incomplete."
            case .publicKeyDerivationDeferred:
                return "Public key can't be derived from this PEM at import time; it will be filled in on first use."
            case .publicKeyDerivationNotSupported(let reason):
                return "Public key derivation isn't supported for this key format: \(reason)."
            case .unsupportedAlgorithmInV1(let name, let remediation):
                return "\(name) is not supported in Pulse v1. \(remediation)"
            case .encryptedPortableKeyNotSupportedInV1(let remediation):
                return "Encrypted private keys are not supported in Pulse v1. \(remediation)"
            }
        }
    }

    // MARK: - Logging

    /// Lifecycle emissions during import. Per ADR 0001 §7, every
    /// SSH-adjacent audit signal lives under a `ssh.*` category.
    private static let logger = Logger(subsystem: "pulse", category: "ssh.credentials")

    // MARK: - v1 portable-tier scope (ADR §1 amendment)

    /// Operator remediation surfaced alongside `unsupportedAlgorithmInV1` for
    /// RSA. The Secure Enclave default is intentionally recommended first;
    /// ECDSA and Ed25519 are the portable-tier alternatives.
    fileprivate static let rsaRemediation =
        "Generate an Ed25519 key with `ssh-keygen -t ed25519` or an ECDSA key with `ssh-keygen -t ecdsa -b 256`, " +
        "or use the Secure Enclave path (default in Pulse)."

    /// Operator remediation surfaced alongside
    /// `encryptedPortableKeyNotSupportedInV1`. The Pulse v1 portable tier
    /// rests on Apple's data-protection keychain (and, for the Primary tier,
    /// Secure Enclave biometric) for at-rest protection of the imported key;
    /// the operator removes the passphrase from the exported PEM rather than
    /// Pulse decrypting it client-side.
    fileprivate static let encryptedPortableRemediation =
        "Re-export the key without a passphrase: " +
        "`ssh-keygen -p -P \"oldpassphrase\" -N \"\" -f /path/to/key`. " +
        "Pulse v1 protects the imported key at rest via the data-protection keychain; " +
        "the Secure Enclave path (default) is recommended for new credentials."

    // MARK: - Public API

    /// Inspects `input` and returns a metadata description plus a normalised PEM ready
    /// for Keychain storage. Throws when the input isn't a recognisable PEM private key.
    static func validate(_ input: String) throws -> ImportedSSHKey {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImporterError.empty }

        let normalised = trimmed.replacingOccurrences(of: "\r\n", with: "\n")

        guard let (kind, base64Body) = extractPEM(from: normalised) else {
            throw ImporterError.noPEMArmorFound
        }

        switch kind {
        case .dsaPrivate:
            // DSA is deprecated and unsupported for SSH client auth in modern OpenSSH.
            // Refuse loudly rather than letting the user import something that won't work.
            throw ImporterError.unsupportedKeyKind(.dsaPrivate)
        default:
            break
        }

        // RFC 1421 traditional encrypted PEM blocks carry headers (`Proc-Type`,
        // `DEK-Info`) between the BEGIN line and the base64 body, separated by a
        // blank line. OpenSSH new-format and unencrypted traditional PEMs skip the
        // header section entirely. Strip any leading header block before decoding so
        // the headers don't end up in the base64 stream.
        let payloadBody = stripPEMHeaders(from: base64Body)
        let stripped = payloadBody
            .split(whereSeparator: \.isWhitespace)
            .joined()
        guard let payload = Data(base64Encoded: stripped) else {
            throw ImporterError.payloadNotBase64
        }

        let algorithm: Algorithm
        let isEncrypted: Bool
        switch kind {
        case .opensshPrivate:
            (algorithm, isEncrypted) = try classifyOpenSSH(payload: payload)
        case .rsaPrivate:
            // Front-door reject. RSA portable signing is deferred per ADR §1
            // v1 portable scope amendment — upstream swift-nio-ssh has no
            // RSA private-key signing path. The classification stays at the
            // PEM-kind level (we know it's RSA from the armor); we don't
            // decode the ASN.1 because the credential never reaches the
            // signing pipeline.
            throw ImporterError.unsupportedAlgorithmInV1(
                name: "RSA",
                remediation: rsaRemediation
            )
        case .ecPrivate:
            // The curve OID lives inside the SEC1 ASN.1 payload, which this importer
            // doesn't decode. Surface as the family-level case so the UI doesn't
            // mislabel a P-384 PEM as P-256; the signer narrows the curve when it
            // parses the SEC1 payload.
            algorithm = .ecdsaUnknownCurve
            isEncrypted = hasEncryptedTraditionalPEMHeader(in: normalised)
            if isEncrypted {
                throw ImporterError.encryptedPortableKeyNotSupportedInV1(
                    remediation: encryptedPortableRemediation
                )
            }
        case .pkcs8:
            // PKCS#8 PrivateKeyInfo wraps an algorithm-specific key. RSA is
            // rejected at the front door per the v1 scope. Non-RSA PKCS#8
            // (ECDSA, in practice) falls through as .unknown; CryptoKit's
            // `pemRepresentation` initializers handle the curve detection at
            // signing time in the auth delegate.
            isEncrypted = false
            if pkcs8PayloadIsRSA(payload) {
                throw ImporterError.unsupportedAlgorithmInV1(
                    name: "RSA",
                    remediation: rsaRemediation
                )
            }
            algorithm = .unknown
        case .encryptedPkcs8:
            throw ImporterError.encryptedPortableKeyNotSupportedInV1(
                remediation: encryptedPortableRemediation
            )
        case .dsaPrivate:
            algorithm = .dsa
            isEncrypted = hasEncryptedTraditionalPEMHeader(in: normalised)
        }

        let normalisedPEM = normalised.hasSuffix("\n") ? normalised : normalised + "\n"

        return ImportedSSHKey(
            pemKind: kind,
            algorithm: algorithm,
            normalisedPEM: normalisedPEM,
            normalisedPEMData: Data(normalisedPEM.utf8),
            isEncrypted: isEncrypted
        )
    }

    // MARK: - PEM scanning

    /// Returns `(kind, base64Body)` if the input contains a single PEM block we recognise.
    private static func extractPEM(from input: String) -> (PEMKind, String)? {
        // BEGIN line: "-----BEGIN <kind>-----"
        guard let beginRange = input.range(of: "-----BEGIN ") else { return nil }
        guard let endOfBeginLine = input.range(
            of: "-----",
            range: beginRange.upperBound..<input.endIndex
        ) else { return nil }
        let kindString = String(input[beginRange.upperBound..<endOfBeginLine.lowerBound])
        guard let kind = PEMKind(rawValue: kindString) else { return nil }

        // END line: "-----END <kind>-----"
        let endMarker = "-----END \(kindString)-----"
        guard let endRange = input.range(of: endMarker) else { return nil }
        guard endRange.lowerBound > endOfBeginLine.upperBound else { return nil }

        let body = String(input[endOfBeginLine.upperBound..<endRange.lowerBound])
        return (kind, body)
    }

    /// Detects the OpenSSL `Proc-Type: 4,ENCRYPTED` header that older `ssh-keygen`
    /// versions emit when a passphrase is set on RSA/EC traditional PEM keys.
    private static func hasEncryptedTraditionalPEMHeader(in input: String) -> Bool {
        input.range(of: "Proc-Type: 4,ENCRYPTED", options: .caseInsensitive) != nil
    }

    /// Strips an RFC 1421 header block from the PEM body if one is present. Headers
    /// look like `Name: Value` and terminate at the first blank line; once that line
    /// is found, everything after it is the base64 body. Bodies without headers fall
    /// through unchanged.
    private static func stripPEMHeaders(from body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstNonEmpty = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return body
        }
        // PEM headers are `Name: Value`. If the first content line doesn't contain a
        // colon it's already base64; nothing to strip.
        guard lines[firstNonEmpty].contains(":") else { return body }
        guard let blankIndex = lines[firstNonEmpty...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return body
        }
        return lines[(blankIndex + 1)...].joined(separator: "\n")
    }

    // MARK: - OpenSSH new-format inspection

    /// Inspects an OpenSSH `openssh-key-v1` private key payload enough to classify the
    /// algorithm and detect whether it's encrypted. Does not decrypt or fully parse
    /// the payload: the signer handles that when it actually consumes the key.
    ///
    /// Format (OpenSSH `PROTOCOL.key`):
    ///
    ///     "openssh-key-v1\0"
    ///     string  ciphername      "none" when unencrypted
    ///     string  kdfname
    ///     string  kdfoptions
    ///     uint32  number of keys (always 1 from ssh-keygen)
    ///     string  publickey1      (the public key in SSH wire format)
    ///         string  algorithm-name      ("ssh-ed25519", "ecdsa-sha2-nistp256", ...)
    ///         (algorithm-specific tail follows)
    ///     ...
    ///
    /// Each `string` is uint32-be length followed by payload.
    private static func classifyOpenSSH(payload: Data) throws -> (Algorithm, Bool) {
        var cursor = 0
        let magic = "openssh-key-v1\u{0}"
        let magicBytes = Data(magic.utf8)
        guard payload.count >= magicBytes.count,
              payload.prefix(magicBytes.count) == magicBytes else {
            throw ImporterError.truncatedOpenSSHKey
        }
        cursor += magicBytes.count

        let cipherName = try readSSHString(from: payload, cursor: &cursor)
        _ = try readSSHString(from: payload, cursor: &cursor) // kdfname
        _ = try readSSHString(from: payload, cursor: &cursor) // kdfoptions
        _ = try readUInt32(from: payload, cursor: &cursor)    // number of keys
        let publicBlob = try readSSHString(from: payload, cursor: &cursor)

        let isEncrypted = !(String(data: cipherName, encoding: .ascii) == "none")

        // Reach into the public-key blob just far enough to read the algorithm identifier.
        var pubCursor = 0
        let algorithmName = try readSSHString(from: publicBlob, cursor: &pubCursor)
        let alg = String(data: algorithmName, encoding: .ascii) ?? ""

        // Front-door reject for v1-unsupported algorithms. RSA is rejected
        // regardless of cipher; encrypted Ed25519/ECDSA are rejected via the
        // encryption gate below.
        switch alg {
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512":
            throw ImporterError.unsupportedAlgorithmInV1(
                name: "RSA",
                remediation: rsaRemediation
            )
        default:
            break
        }

        if isEncrypted {
            throw ImporterError.encryptedPortableKeyNotSupportedInV1(
                remediation: encryptedPortableRemediation
            )
        }

        let mapped: Algorithm
        switch alg {
        case "ssh-ed25519":            mapped = .ed25519
        case "ecdsa-sha2-nistp256":    mapped = .ecdsaP256
        case "ecdsa-sha2-nistp384":    mapped = .ecdsaP384
        case "ecdsa-sha2-nistp521":    mapped = .ecdsaP521
        default:
            mapped = .unknown
        }
        return (mapped, isEncrypted)
    }

    // MARK: - PKCS#8 RSA detection (front-door reject support)

    /// Returns non-nil when `payload` is a PKCS#8 PrivateKeyInfo wrapping an
    /// RSA key. The caller (`validate`) only checks for non-nil to fire the
    /// v1 front-door reject; the returned payload is not consumed. Non-RSA
    /// PKCS#8 returns nil so the classifier falls through to `.unknown`,
    /// and CryptoKit's `pemRepresentation` initialisers handle the curve
    /// detection at signing time in the auth delegate.
    ///
    /// PKCS#8 PrivateKeyInfo:
    ///     SEQUENCE {
    ///         version           INTEGER (0)
    ///         algorithm         AlgorithmIdentifier { OID, params }
    ///         privateKey        OCTET STRING
    ///         ...
    ///     }
    /// Detects an RSA PKCS#8 payload by substring-searching for the
    /// rsaEncryption OID byte sequence — DER-encoded as
    /// `2A 86 48 86 F7 0D 01 01 01` (OID 1.2.840.113549.1.1.1).
    /// Replaces a 28-line ASN.1 walk; same security guarantee for the
    /// front-door reject path with no DER parsing surface to maintain.
    ///
    /// The OID is distinctive enough that false matches on random key
    /// material (ECDSA scalar, Ed25519 seed, RSA modulus when it
    /// somehow leaks past the reject) are astronomically rare: ~1/2^72
    /// per 9-byte window, vs an actual rsaEncryption OID which is
    /// guaranteed to appear in any PKCS#8 RSA AlgorithmIdentifier.
    /// Over-rejecting on a vanishingly-improbable false match is the
    /// safe-direction outcome — encrypted-PEM imports of RSA are
    /// already deferred per ADR §1.
    private static func pkcs8PayloadIsRSA(_ payload: Data) -> Bool {
        let rsaOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        return payload.firstRange(of: rsaOID) != nil
    }

    // MARK: - OpenSSH new-format private-key decoder

    /// Algorithm-specific private material extracted from an unencrypted
    /// OpenSSH new-format (`openssh-key-v1`) private-key payload. The auth
    /// delegate wraps each case in the corresponding
    /// CryptoKit primitive and hands the result to `NIOSSHPrivateKey`.
    ///
    /// The scalar / seed byte lengths are pinned to the algorithm's curve:
    /// 32 bytes for Ed25519 seed and P-256 scalar, 48 bytes for P-384, 66
    /// bytes for P-521.
    enum DecodedOpenSSHPrivateKey: Equatable, Sendable {
        case ed25519(seed: Data)
        case ecdsaP256(scalar: Data)
        case ecdsaP384(scalar: Data)
        case ecdsaP521(scalar: Data)
    }

    /// Errors raised while walking the private-key section of an OpenSSH
    /// new-format payload. Surfaced separately from `ImporterError` so the
    /// auth delegate can distinguish "this PEM didn't decode" from "the PEM
    /// classified but the front door rejected it."
    enum OpenSSHDecodeError: Error, CustomStringConvertible, Equatable {
        case notOpenSSHNewFormat
        case encrypted
        case checkintMismatch
        case truncatedPrivateSection
        case unsupportedInnerAlgorithm(String)
        case unexpectedFieldLength(field: String, expected: Int, observed: Int)

        var description: String {
            switch self {
            case .notOpenSSHNewFormat:
                return "Key is not in OpenSSH new-format (BEGIN OPENSSH PRIVATE KEY)."
            case .encrypted:
                return "OpenSSH new-format key is encrypted; Pulse v1 doesn't support encrypted portable keys."
            case .checkintMismatch:
                return "Decryption check-integer mismatch; the private section is malformed or tampered."
            case .truncatedPrivateSection:
                return "Private-key section ended before the expected fields were read."
            case .unsupportedInnerAlgorithm(let name):
                return "OpenSSH inner algorithm \(name) isn't supported by Pulse v1."
            case .unexpectedFieldLength(let field, let expected, let observed):
                return "OpenSSH \(field) field length: expected \(expected), got \(observed)."
            }
        }
    }

    /// Decodes an unencrypted OpenSSH new-format private-key PEM and returns
    /// the algorithm-specific private material.
    ///
    /// The decoder operates only on the binary wire format — no cryptographic
    /// algorithms run here. Encrypted payloads (`ciphername != "none"`) are
    /// rejected via `OpenSSHDecodeError.encrypted` rather than attempted;
    /// implementing bcrypt-pbkdf in-house is the §10 line we don't cross.
    ///
    /// Wire structure (`PROTOCOL.key`):
    ///
    ///     "openssh-key-v1\0"
    ///     string  ciphername     "none"
    ///     string  kdfname        "none"
    ///     string  kdfoptions     ""
    ///     uint32  numkeys        1
    ///     string  publickey1     (SSH wire-format public key, already covered by
    ///                             `opensshPublicBlobFromNewFormat`)
    ///     string  privateKeySection
    ///       uint32  checkint1
    ///       uint32  checkint2    (must equal checkint1)
    ///       for each key (1 in practice):
    ///         string  algoname
    ///         [algorithm-specific public fields]
    ///         [algorithm-specific private fields]
    ///         string  comment
    ///       padding 1, 2, ..., n (to align to cipher block size; 1..7 bytes for
    ///       cipher "none" using an 8-byte alignment in ssh-keygen practice)
    static func decodeOpenSSHPrivateKey(from pem: String) throws -> DecodedOpenSSHPrivateKey {
        guard let (kind, base64Body) = extractPEM(from: pem), kind == .opensshPrivate else {
            throw OpenSSHDecodeError.notOpenSSHNewFormat
        }
        let stripped = stripPEMHeaders(from: base64Body)
            .split(whereSeparator: \.isWhitespace)
            .joined()
        guard let payload = Data(base64Encoded: stripped) else {
            throw ImporterError.payloadNotBase64
        }

        var cursor = 0
        let magic = Data("openssh-key-v1\u{0}".utf8)
        guard payload.count >= magic.count, payload.prefix(magic.count) == magic else {
            throw OpenSSHDecodeError.notOpenSSHNewFormat
        }
        cursor += magic.count

        let cipherName = try readSSHString(from: payload, cursor: &cursor)
        guard String(data: cipherName, encoding: .ascii) == "none" else {
            throw OpenSSHDecodeError.encrypted
        }
        _ = try readSSHString(from: payload, cursor: &cursor) // kdfname (also "none")
        _ = try readSSHString(from: payload, cursor: &cursor) // kdfoptions ("")
        _ = try readUInt32(from: payload, cursor: &cursor)    // numKeys (== 1)
        _ = try readSSHString(from: payload, cursor: &cursor) // publickey1

        let privateSection = try readSSHString(from: payload, cursor: &cursor)
        var sub = 0
        let checkint1 = try readUInt32(from: privateSection, cursor: &sub)
        let checkint2 = try readUInt32(from: privateSection, cursor: &sub)
        guard checkint1 == checkint2 else {
            throw OpenSSHDecodeError.checkintMismatch
        }

        let algoData = try readSSHString(from: privateSection, cursor: &sub)
        let algoName = String(data: algoData, encoding: .ascii) ?? ""

        switch algoName {
        case "ssh-ed25519":
            // Ed25519 inner layout: string pub (32 bytes), string priv (64
            // bytes: seed[32] || pubkey[32]). We only need the seed; CryptoKit
            // derives the public half from it.
            let pub = try readSSHString(from: privateSection, cursor: &sub)
            guard pub.count == 32 else {
                throw OpenSSHDecodeError.unexpectedFieldLength(
                    field: "ed25519 public", expected: 32, observed: pub.count
                )
            }
            let priv = try readSSHString(from: privateSection, cursor: &sub)
            guard priv.count == 64 else {
                throw OpenSSHDecodeError.unexpectedFieldLength(
                    field: "ed25519 private", expected: 64, observed: priv.count
                )
            }
            return .ed25519(seed: priv.prefix(32))

        case "ecdsa-sha2-nistp256":
            return try decodeECDSAInnerPrivateKey(
                from: privateSection,
                cursor: &sub,
                expectedCurveName: "nistp256",
                scalarLength: 32
            )
        case "ecdsa-sha2-nistp384":
            return try decodeECDSAInnerPrivateKey(
                from: privateSection,
                cursor: &sub,
                expectedCurveName: "nistp384",
                scalarLength: 48
            )
        case "ecdsa-sha2-nistp521":
            return try decodeECDSAInnerPrivateKey(
                from: privateSection,
                cursor: &sub,
                expectedCurveName: "nistp521",
                scalarLength: 66
            )

        default:
            throw OpenSSHDecodeError.unsupportedInnerAlgorithm(algoName)
        }
    }

    /// Reads the ECDSA-specific inner-private-key fields for a P-256/384/521
    /// curve and returns the appropriate `DecodedOpenSSHPrivateKey` case.
    /// Inner layout after the algoname:
    ///     string  curveName  ("nistp256", "nistp384", or "nistp521")
    ///     string  Q          (65/97/133-byte uncompressed point)
    ///     mpint   d          (private scalar; may carry a leading 0x00 sign byte)
    private static func decodeECDSAInnerPrivateKey(
        from data: Data,
        cursor: inout Int,
        expectedCurveName: String,
        scalarLength: Int
    ) throws -> DecodedOpenSSHPrivateKey {
        let curveData = try readSSHString(from: data, cursor: &cursor)
        guard String(data: curveData, encoding: .ascii) == expectedCurveName else {
            throw OpenSSHDecodeError.unsupportedInnerAlgorithm(
                "curve mismatch: expected \(expectedCurveName)"
            )
        }
        _ = try readSSHString(from: data, cursor: &cursor) // Q, the uncompressed point
        // d is an mpint: SSH-string-framed two's-complement integer that may
        // carry a leading 0x00 byte to keep the value positive when the high
        // bit of the magnitude is set. Normalise to the curve's fixed scalar
        // length by stripping a single leading zero if present, then
        // left-padding with zeros if shorter.
        let dRaw = try readSSHString(from: data, cursor: &cursor)
        var bytes = [UInt8](dRaw)
        if bytes.count == scalarLength + 1 && bytes.first == 0x00 {
            bytes.removeFirst()
        }
        if bytes.count < scalarLength {
            bytes = Array(repeating: 0x00, count: scalarLength - bytes.count) + bytes
        }
        guard bytes.count == scalarLength else {
            throw OpenSSHDecodeError.unexpectedFieldLength(
                field: "ecdsa scalar (\(expectedCurveName))",
                expected: scalarLength,
                observed: bytes.count
            )
        }
        let scalar = Data(bytes)
        switch expectedCurveName {
        case "nistp256": return .ecdsaP256(scalar: scalar)
        case "nistp384": return .ecdsaP384(scalar: scalar)
        case "nistp521": return .ecdsaP521(scalar: scalar)
        default:
            // Unreachable: the caller passes a known curve name.
            throw OpenSSHDecodeError.unsupportedInnerAlgorithm(expectedCurveName)
        }
    }

    // MARK: - Public-key derivation

    /// Derives the OpenSSH wire-format public key (the bytes that get base64-
    /// encoded as the second field of an `authorized_keys` line) from a
    /// successfully-validated `ImportedSSHKey`.
    ///
    /// Supported path: OpenSSH new-format (any algorithm, encrypted or not).
    /// The public-key blob lives unencrypted in the payload regardless of
    /// cipher, so this works for password-protected keys too.
    ///
    /// Other PEM kinds raise `publicKeyDerivationNotSupported`. The realistic
    /// callers — `SSHCredentialsSettings.commit()` and the auth delegate's
    /// first-use backfill — only reach this function after `validate()`, and
    /// `validate()` rejects traditional `BEGIN RSA PRIVATE KEY`, PKCS#8 RSA,
    /// any encrypted PEM, and DSA at the front door per the v1 portable
    /// scope. The non-OpenSSH branches stay for switch exhaustiveness; they
    /// are unreachable through normal flow.
    static func derivePublicKey(from key: ImportedSSHKey) throws -> Data {
        switch key.pemKind {
        case .opensshPrivate:
            guard let (_, base64Body) = extractPEM(from: key.normalisedPEM) else {
                throw ImporterError.noPEMArmorFound
            }
            let stripped = stripPEMHeaders(from: base64Body)
                .split(whereSeparator: \.isWhitespace)
                .joined()
            guard let payload = Data(base64Encoded: stripped) else {
                throw ImporterError.payloadNotBase64
            }
            return try opensshPublicBlobFromNewFormat(payload: payload)
        case .rsaPrivate, .pkcs8, .encryptedPkcs8, .ecPrivate:
            throw ImporterError.publicKeyDerivationNotSupported(
                reason: "PEM kind \(key.pemKind.rawValue) is rejected by `validate()` under the v1 portable scope"
            )
        case .dsaPrivate:
            throw ImporterError.unsupportedKeyKind(.dsaPrivate)
        }
    }

    /// Reads the public-key blob (already SSH wire-format) out of an
    /// OpenSSH new-format private-key payload. Walks past the cipher / kdf /
    /// numkeys header to the `publickey1` SSH string.
    private static func opensshPublicBlobFromNewFormat(payload: Data) throws -> Data {
        var cursor = 0
        let magicBytes = Data("openssh-key-v1\u{0}".utf8)
        guard payload.count >= magicBytes.count,
              payload.prefix(magicBytes.count) == magicBytes else {
            throw ImporterError.truncatedOpenSSHKey
        }
        cursor += magicBytes.count
        _ = try readSSHString(from: payload, cursor: &cursor) // ciphername
        _ = try readSSHString(from: payload, cursor: &cursor) // kdfname
        _ = try readSSHString(from: payload, cursor: &cursor) // kdfoptions
        _ = try readUInt32(from: payload, cursor: &cursor)    // number of keys
        return try readSSHString(from: payload, cursor: &cursor)
    }

    // MARK: - SSH wire format helpers

    private static func readUInt32(from data: Data, cursor: inout Int) throws -> UInt32 {
        guard cursor + 4 <= data.count else { throw ImporterError.truncatedOpenSSHKey }
        let slice = data.subdata(in: cursor..<(cursor + 4))
        cursor += 4
        return slice.withUnsafeBytes { rawBuffer -> UInt32 in
            var value: UInt32 = 0
            for byte in rawBuffer {
                value = (value << 8) | UInt32(byte)
            }
            return value
        }
    }

    private static func readSSHString(from data: Data, cursor: inout Int) throws -> Data {
        let length = try readUInt32(from: data, cursor: &cursor)
        let length32 = Int(length)
        guard cursor + length32 <= data.count else { throw ImporterError.truncatedOpenSSHKey }
        let payload = data.subdata(in: cursor..<(cursor + length32))
        cursor += length32
        return payload
    }
}
