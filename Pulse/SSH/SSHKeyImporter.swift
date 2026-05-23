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

    enum ImporterError: Error, CustomStringConvertible {
        case empty
        case noPEMArmorFound
        case mismatchedArmor
        case unsupportedKeyKind(PEMKind)
        case payloadNotBase64
        case truncatedOpenSSHKey

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
            }
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

        let stripped = base64Body
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
        case .ecPrivate:
            // The curve OID lives inside the SEC1 ASN.1 payload, which this importer
            // doesn't decode. Surface as the family-level case so the UI doesn't
            // mislabel a P-384 PEM as P-256; the signer narrows the curve when it
            // parses the SEC1 payload.
            algorithm = .ecdsaUnknownCurve
            isEncrypted = hasEncryptedTraditionalPEMHeader(in: normalised)
        case .pkcs8:
            // OID classification would require ASN.1 parsing. Defer to Slice 3.
            algorithm = .unknown
            isEncrypted = false
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
        default:
            mapped = .unknown
        }
        return (mapped, isEncrypted)
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
