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
        /// RSA modulus is below the NZISM 17.1.40 hard floor of 2048 bits.
        /// The associated value is the observed bit length so the UI can
        /// surface a precise message ("found 1024 bits, need 2048+").
        case rsaModulusTooSmall(observed: Int)
        /// PKCS#1 / PKCS#8 ASN.1 payload doesn't parse far enough for us to
        /// reach the modulus. Treated like a truncation: the user re-imports.
        case truncatedASN1
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
            case .rsaModulusTooSmall(let observed):
                return "RSA key has a \(observed)-bit modulus; Pulse requires at least 2048 bits per NZISM 17.1.40."
            case .truncatedASN1:
                return "ASN.1 payload is truncated or malformed; the modulus length could not be read."
            case .publicKeyDerivationDeferred:
                return "Public key can't be derived from this PEM at import time; it will be filled in on first use."
            case .publicKeyDerivationNotSupported(let reason):
                return "Public key derivation isn't supported for this key format: \(reason)."
            }
        }
    }

    // MARK: - Logging

    /// Lifecycle and policy emissions during import. Per ADR 0001 §7, every
    /// SSH-adjacent audit signal lives under a `ssh.*` category. The modulus
    /// warning band (2048..<3072) fires through this logger as `credential.weakRSA`.
    private static let logger = Logger(subsystem: "pulse", category: "ssh.credentials")

    // MARK: - RSA policy

    /// NZISM 17.1.40 hard floor. Keys below this are rejected; the policy is not
    /// per-tenant configurable in v1. A per-site override (`Site.allowsLegacyRSA`)
    /// is a future schema addition if a deployment ever needs to weaken it.
    private static let rsaModulusHardFloor = 2048

    /// Hardened-deployment recommendation. Keys in `2048..<3072` are accepted
    /// but emit a warning so the operator can rotate them ahead of any future
    /// hardening policy change.
    private static let rsaModulusHardenedFloor = 3072

    /// Applies the RSA modulus policy: reject below 2048, warn 2048..<3072,
    /// silently accept >= 3072. The `context` argument is interpolated into
    /// the warning emission so an operator scanning `log show` can tell which
    /// key path the warning came from.
    private static func enforceRSAModulusPolicy(bits: Int, context: String) throws {
        if bits < rsaModulusHardFloor {
            throw ImporterError.rsaModulusTooSmall(observed: bits)
        }
        if bits < rsaModulusHardenedFloor {
            logger.warning(
                "Imported RSA key has a \(bits)-bit modulus (\(context)); accepted but below the 3072-bit hardened-deployment recommendation."
            )
        }
    }

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
            algorithm = .rsa
            isEncrypted = hasEncryptedTraditionalPEMHeader(in: normalised)
            // NZISM 17.1.40. Encrypted traditional PEMs can't be modulus-checked
            // at import time without the passphrase; the signer rechecks after
            // decryption. Unencrypted PEMs are checked now so the operator sees
            // the rejection in the import sheet rather than at first sign.
            if !isEncrypted {
                let bits = try rsaModulusBitsFromPKCS1(payload)
                try enforceRSAModulusPolicy(bits: bits, context: "PKCS#1 traditional PEM")
            }
        case .ecPrivate:
            // The curve OID lives inside the SEC1 ASN.1 payload, which this importer
            // doesn't decode. Surface as the family-level case so the UI doesn't
            // mislabel a P-384 PEM as P-256; the signer narrows the curve when it
            // parses the SEC1 payload.
            algorithm = .ecdsaUnknownCurve
            isEncrypted = hasEncryptedTraditionalPEMHeader(in: normalised)
        case .pkcs8:
            // PKCS#8 PrivateKeyInfo wraps an algorithm-specific key. We classify
            // the inner OID and, for RSA, descend into the OCTET STRING for a
            // PKCS#1-shaped modulus check. Non-RSA PKCS#8 falls through as
            // .unknown for now; the signer narrows the algorithm at sign time.
            isEncrypted = false
            if let rsaPayload = try pkcs8RSAInnerPKCS1(payload) {
                algorithm = .rsa
                let bits = try rsaModulusBitsFromPKCS1(rsaPayload)
                try enforceRSAModulusPolicy(bits: bits, context: "PKCS#8 PEM")
            } else {
                algorithm = .unknown
            }
        case .encryptedPkcs8:
            algorithm = .unknown
            isEncrypted = true
        case .dsaPrivate:
            algorithm = .dsa
            isEncrypted = hasEncryptedTraditionalPEMHeader(in: normalised)
        }

        let normalisedPEM = normalised.hasSuffix("\n") ? normalised : normalised + "\n"

        return ImportedSSHKey(
            pemKind: kind,
            algorithm: algorithm,
            normalisedPEM: normalisedPEM,
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

        let mapped: Algorithm
        switch alg {
        case "ssh-ed25519":            mapped = .ed25519
        case "ecdsa-sha2-nistp256":    mapped = .ecdsaP256
        case "ecdsa-sha2-nistp384":    mapped = .ecdsaP384
        case "ecdsa-sha2-nistp521":    mapped = .ecdsaP521
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512":
            mapped = .rsa
            // NZISM 17.1.40. The public-key blob layout after the algorithm
            // name for ssh-rsa is `mpint e, mpint n`. Encrypted new-format keys
            // still carry an unencrypted public-key blob — the encryption only
            // covers the private half — so the modulus is checkable regardless
            // of `isEncrypted`.
            let modulusBits = try rsaModulusBitsFromOpenSSHPublicBlob(publicBlob)
            try enforceRSAModulusPolicy(bits: modulusBits, context: "OpenSSH new-format")
        default:
            mapped = .unknown
        }
        return (mapped, isEncrypted)
    }

    // MARK: - RSA modulus extraction

    /// Reads the modulus `n` from a PKCS#1 RSAPrivateKey DER payload and returns
    /// its bit length. The structure is:
    ///
    ///     RSAPrivateKey ::= SEQUENCE {
    ///         version           INTEGER,
    ///         modulus           INTEGER, -- n
    ///         publicExponent    INTEGER, -- e
    ///         ...
    ///     }
    ///
    /// We only need the first two integers; the rest of the structure is
    /// untouched. Used by both the traditional `BEGIN RSA PRIVATE KEY` arm and
    /// the inner payload of PKCS#8 PrivateKeyInfo for RSA keys.
    private static func rsaModulusBitsFromPKCS1(_ payload: Data) throws -> Int {
        let bytes = [UInt8](payload)
        var cursor = 0
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x30) // SEQUENCE
        _ = try readASN1Length(bytes, cursor: &cursor)
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x02) // INTEGER (version)
        let versionLength = try readASN1Length(bytes, cursor: &cursor)
        cursor += versionLength
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x02) // INTEGER (modulus n)
        let modulusLength = try readASN1Length(bytes, cursor: &cursor)
        guard cursor + modulusLength <= bytes.count else {
            throw ImporterError.truncatedASN1
        }
        let modulus = Array(bytes[cursor..<(cursor + modulusLength)])
        return asn1IntegerBitLength(modulus)
    }

    /// If `payload` is a PKCS#8 PrivateKeyInfo wrapping an RSA key, returns the
    /// inner PKCS#1 RSAPrivateKey payload (the OCTET STRING contents) for the
    /// modulus check. Returns nil for non-RSA PKCS#8 keys so the caller can
    /// fall through to `.unknown` without raising.
    ///
    /// PKCS#8 PrivateKeyInfo:
    ///     SEQUENCE {
    ///         version           INTEGER (0)
    ///         algorithm         AlgorithmIdentifier { OID, params }
    ///         privateKey        OCTET STRING
    ///         ...
    ///     }
    /// rsaEncryption OID is 1.2.840.113549.1.1.1, DER-encoded
    /// `06 09 2A 86 48 86 F7 0D 01 01 01`.
    private static func pkcs8RSAInnerPKCS1(_ payload: Data) throws -> Data? {
        let bytes = [UInt8](payload)
        var cursor = 0
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x30) // outer SEQUENCE
        _ = try readASN1Length(bytes, cursor: &cursor)
        // version INTEGER
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x02)
        let versionLen = try readASN1Length(bytes, cursor: &cursor)
        cursor += versionLen
        // AlgorithmIdentifier SEQUENCE
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x30)
        let algIDLen = try readASN1Length(bytes, cursor: &cursor)
        let algIDEnd = cursor + algIDLen
        guard algIDEnd <= bytes.count else { throw ImporterError.truncatedASN1 }
        // OID
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x06)
        let oidLen = try readASN1Length(bytes, cursor: &cursor)
        guard cursor + oidLen <= bytes.count else { throw ImporterError.truncatedASN1 }
        let oid = Array(bytes[cursor..<(cursor + oidLen)])
        cursor = algIDEnd // skip past parameters
        let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        guard oid == rsaEncryptionOID else { return nil }
        // OCTET STRING containing the PKCS#1 RSAPrivateKey
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x04)
        let octetLen = try readASN1Length(bytes, cursor: &cursor)
        guard cursor + octetLen <= bytes.count else { throw ImporterError.truncatedASN1 }
        return Data(bytes[cursor..<(cursor + octetLen)])
    }

    /// Reads `mpint e, mpint n` from an OpenSSH new-format public-key blob whose
    /// algorithm prefix has already been consumed (the caller passes the full
    /// blob; this function skips the `ssh-rsa` string itself). Returns the bit
    /// length of `n`.
    private static func rsaModulusBitsFromOpenSSHPublicBlob(_ publicBlob: Data) throws -> Int {
        var cursor = 0
        // Skip the algorithm-name SSH string ("ssh-rsa", "rsa-sha2-256", or
        // "rsa-sha2-512"). The caller already inspected it.
        _ = try readSSHString(from: publicBlob, cursor: &cursor)
        // mpint e — discard
        _ = try readSSHString(from: publicBlob, cursor: &cursor)
        // mpint n — the modulus
        let n = try readSSHString(from: publicBlob, cursor: &cursor)
        return asn1IntegerBitLength([UInt8](n))
    }

    // MARK: - Public-key derivation

    /// Derives the OpenSSH wire-format public key (the bytes that get base64-
    /// encoded as the second field of an `authorized_keys` line) from a
    /// successfully-validated `ImportedSSHKey`.
    ///
    /// Supported paths:
    ///
    /// - OpenSSH new-format (any algorithm, encrypted or not): the public-key
    ///   blob lives unencrypted in the payload regardless of cipher, so this
    ///   works for password-protected keys too.
    /// - Traditional `BEGIN RSA PRIVATE KEY` (unencrypted): n and e read from
    ///   the PKCS#1 ASN.1, repacked as `ssh-rsa` wire format.
    /// - PKCS#8 `BEGIN PRIVATE KEY` carrying rsaEncryption (unencrypted): same
    ///   as PKCS#1 after descending into the OCTET STRING.
    ///
    /// Encrypted traditional / PKCS#8 keys and traditional EC PEMs raise
    /// `publicKeyDerivationDeferred` or `publicKeyDerivationNotSupported`. The
    /// credential is still stored with an empty `publicKey` placeholder; the
    /// auth delegate's first-use path backfills once the signer can read the
    /// private half (after passphrase or for EC PEMs after SEC1 decoding).
    static func derivePublicKey(from key: ImportedSSHKey) throws -> Data {
        guard let (_, base64Body) = extractPEM(from: key.normalisedPEM) else {
            throw ImporterError.noPEMArmorFound
        }
        let stripped = stripPEMHeaders(from: base64Body)
            .split(whereSeparator: \.isWhitespace)
            .joined()
        guard let payload = Data(base64Encoded: stripped) else {
            throw ImporterError.payloadNotBase64
        }

        switch key.pemKind {
        case .opensshPrivate:
            return try opensshPublicBlobFromNewFormat(payload: payload)
        case .rsaPrivate:
            if key.isEncrypted {
                throw ImporterError.publicKeyDerivationDeferred
            }
            let (n, e) = try rsaModulusAndExponentFromPKCS1(payload)
            return opensshWireForRSA(n: n, e: e)
        case .pkcs8:
            guard let inner = try pkcs8RSAInnerPKCS1(payload) else {
                throw ImporterError.publicKeyDerivationNotSupported(reason: "PKCS#8 non-RSA")
            }
            let (n, e) = try rsaModulusAndExponentFromPKCS1(inner)
            return opensshWireForRSA(n: n, e: e)
        case .encryptedPkcs8:
            throw ImporterError.publicKeyDerivationDeferred
        case .ecPrivate:
            throw ImporterError.publicKeyDerivationNotSupported(reason: "traditional EC PEM")
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

    /// PKCS#1 INTEGER pair extractor: pulls the modulus and public exponent
    /// without re-reading version (the modulus check arm already validated
    /// the SEQUENCE prefix, but `derivePublicKey` may be called on a freshly
    /// parsed payload, so the structural walk repeats here).
    private static func rsaModulusAndExponentFromPKCS1(_ payload: Data) throws -> (n: Data, e: Data) {
        let bytes = [UInt8](payload)
        var cursor = 0
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x30)
        _ = try readASN1Length(bytes, cursor: &cursor)
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x02)
        let versionLen = try readASN1Length(bytes, cursor: &cursor)
        cursor += versionLen
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x02)
        let nLen = try readASN1Length(bytes, cursor: &cursor)
        guard cursor + nLen <= bytes.count else { throw ImporterError.truncatedASN1 }
        let n = Data(bytes[cursor..<(cursor + nLen)])
        cursor += nLen
        try expectASN1Tag(bytes, cursor: &cursor, tag: 0x02)
        let eLen = try readASN1Length(bytes, cursor: &cursor)
        guard cursor + eLen <= bytes.count else { throw ImporterError.truncatedASN1 }
        let e = Data(bytes[cursor..<(cursor + eLen)])
        return (n, e)
    }

    /// Builds the OpenSSH wire format for an RSA public key:
    ///     string  "ssh-rsa"
    ///     mpint   e
    ///     mpint   n
    private static func opensshWireForRSA(n: Data, e: Data) -> Data {
        var wire = Data()
        wire.append(sshWireString(Data("ssh-rsa".utf8)))
        wire.append(sshWireMpint(e))
        wire.append(sshWireMpint(n))
        return wire
    }

    /// uint32 length-prefixed SSH string.
    private static func sshWireString(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// SSH `mpint` wire format: length-prefixed two's-complement big-endian.
    /// Unsigned values whose high bit is set get a 0x00 prefix to keep the
    /// integer positive when re-decoded as two's complement.
    private static func sshWireMpint(_ raw: Data) -> Data {
        var bytes = [UInt8](raw)
        // Strip incidental leading zeros (ASN.1 INTEGERs may carry a sign
        // byte; mpints are also free of them).
        while bytes.count > 1 && bytes.first == 0x00 {
            bytes.removeFirst()
        }
        if bytes.isEmpty {
            return sshWireString(Data([0x00]))
        }
        if bytes[0] >= 0x80 {
            bytes.insert(0x00, at: 0)
        }
        return sshWireString(Data(bytes))
    }

    // MARK: - ASN.1 primitives

    private static func expectASN1Tag(_ data: [UInt8], cursor: inout Int, tag: UInt8) throws {
        guard cursor < data.count, data[cursor] == tag else {
            throw ImporterError.truncatedASN1
        }
        cursor += 1
    }

    private static func readASN1Length(_ data: [UInt8], cursor: inout Int) throws -> Int {
        guard cursor < data.count else { throw ImporterError.truncatedASN1 }
        let first = data[cursor]
        cursor += 1
        if first < 0x80 {
            return Int(first)
        }
        let countBytes = Int(first & 0x7F)
        // 0x80 is an indefinite-length form, illegal in DER for the constructions
        // we parse. 9+ length bytes would imply >= 2^64 bytes of payload, which
        // we'll never see and refuse to allocate for.
        guard countBytes >= 1, countBytes <= 8, cursor + countBytes <= data.count else {
            throw ImporterError.truncatedASN1
        }
        var length = 0
        for i in 0..<countBytes {
            length = (length << 8) | Int(data[cursor + i])
        }
        cursor += countBytes
        return length
    }

    /// Returns the bit length of a big-endian unsigned integer represented as a
    /// byte sequence. Handles the leading sign byte that both DER INTEGER and
    /// SSH mpint use to keep large unsigned values positive.
    private static func asn1IntegerBitLength(_ raw: [UInt8]) -> Int {
        var i = 0
        // Strip leading zero bytes (the DER/mpint sign byte, plus any incidental
        // leading zeros — shouldn't appear in well-formed payloads but be safe).
        while i < raw.count && raw[i] == 0 { i += 1 }
        guard i < raw.count else { return 0 }
        let firstNonzero = raw[i]
        let remaining = raw.count - i - 1
        return remaining * 8 + (8 - Int(firstNonzero.leadingZeroBitCount))
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
