//
//  SecureEnclaveKeyManager.swift
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
import Security

/// Manages Secure Enclave–resident ECDSA P-256 private keys used as SSH credentials.
///
/// The Secure Enclave only supports ECDSA over the NIST P-256 curve (`secp256r1` /
/// `prime256v1`); not Ed25519, not RSA. This is hardware. Modern OpenSSH servers
/// (≥6.5, 2014) accept `ecdsa-sha2-nistp256` so the constraint is purely a
/// compatibility note, not a security one. See ADR 0001 §1.
///
/// Every signature triggers a biometric / device-passcode prompt because the keys are
/// created with `.privateKeyUsage` combined with `.biometryAny`. No caching of
/// the authorisation across signatures. The prompt is driven by `SecKeyCreateSignature`
/// itself; callers must not invoke `LAContext.evaluatePolicy` directly.
///
/// This file stays at the Security-framework level. The bridge that lets swift-nio-ssh
/// drive these keys lives in a separate signer type, which consumes `privateKey(for:)`
/// for signature operations and `openSSHPublicKeyWireFormat(for:)` for the SSH-layer
/// authentication challenge.
enum SecureEnclaveKeyManager {

    // MARK: - Errors

    enum KeyManagerError: Error, CustomStringConvertible {
        case secureEnclaveUnavailable
        case accessControlCreationFailed(CFError?)
        case keyGenerationFailed(CFError?)
        case keyNotFound(UUID)
        case publicKeyDerivationFailed
        case publicKeyExportFailed(CFError?)
        case unexpectedPublicKeyFormat
        case signatureFailed(CFError?)
        case deletionFailed(OSStatus)

        var description: String {
            switch self {
            case .secureEnclaveUnavailable:
                return "Secure Enclave is not available on this device."
            case .accessControlCreationFailed(let err):
                return "Failed to create Secure Enclave access control: \(String(describing: err))"
            case .keyGenerationFailed(let err):
                return "Failed to generate Secure Enclave key: \(String(describing: err))"
            case .keyNotFound(let id):
                return "No Secure Enclave key found for credential \(id)."
            case .publicKeyDerivationFailed:
                return "Could not derive a public key from the Secure Enclave private key."
            case .publicKeyExportFailed(let err):
                return "Failed to export Secure Enclave public key: \(String(describing: err))"
            case .unexpectedPublicKeyFormat:
                return "Secure Enclave public key was not in the expected uncompressed-point format."
            case .signatureFailed(let err):
                return "Secure Enclave signature failed: \(String(describing: err))"
            case .deletionFailed(let status):
                return "Secure Enclave key deletion failed (OSStatus \(status))."
            }
        }
    }

    // MARK: - Identity

    /// Prefix applied to every `kSecAttrApplicationTag` so the Pulse keys are filterable
    /// from any other ECDSA P-256 keys living on this device.
    private static let tagPrefix = "nz.omega.pulse.ssh."

    /// OpenSSH algorithm identifier for SE-backed keys. Centralised so the wire-format
    /// encoder and the `authorized_keys` rendering can't drift.
    private static let opensshAlgorithm = "ecdsa-sha2-nistp256"

    /// OpenSSH curve identifier for the algorithm above. The "nistp256" string is what
    /// servers compare against the algorithm-name prefix, not the SEC1 OID.
    private static let opensshCurveName = "nistp256"

    /// Stable application tag for a given credential id. The tag is what we look the
    /// key up by; `id` does not appear elsewhere in the Keychain query.
    private static func applicationTag(for credentialID: UUID) -> Data {
        Data("\(tagPrefix)\(credentialID.uuidString)".utf8)
    }

    private static let logger = Logger(subsystem: "pulse", category: "ssh.secureenclave")

    // MARK: - Lifecycle

    /// Generates a new SE-backed ECDSA P-256 keypair tagged with `credentialID` and
    /// returns the OpenSSH wire-format public key for storage on `SSHCredential`.
    ///
    /// The private half never leaves the Enclave; `SecKeyCopyExternalRepresentation`
    /// on the private reference is documented to return `nil`, which the verification
    /// table checks explicitly.
    @discardableResult
    static func generateKey(
        for credentialID: UUID,
        label: String
    ) throws -> Data {
        var accessError: Unmanaged<CFError>?
        // Stricter than Configuration's `AfterFirstUnlock` access class on purpose:
        // SE-backed signing keys should only be usable while the device is currently
        // unlocked, matching Apple's TN3137 guidance for "secure operations gated by
        // user presence." The background-polling justification that motivates the
        // looser class on API tokens doesn't apply to interactive SSH signing, so the
        // stricter class stays.
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny, .or, .devicePasscode],
            &accessError
        ) else {
            throw KeyManagerError.accessControlCreationFailed(accessError?.takeRetainedValue())
        }

        // `kSecAttrSynchronizable: false` is the default for the data-protection
        // keychain on macOS, but setting it explicitly turns a default-behaviour
        // assumption into a structural guarantee: a reviewer can grep
        // `kSecAttrSynchronizable` and confirm SSH keys never opt into iCloud sync.
        let privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: applicationTag(for: credentialID),
            kSecAttrLabel as String: label,
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: false
        ]

        // `kSecUseDataProtectionKeychain` pins this call to the modern data-protection
        // keychain. On macOS the default is still the legacy file-based keychain, which
        // is what `SecKeyCreateRandomKey` would otherwise try to deposit into when
        // `kSecAttrIsPermanent` is true. SE-token-backed keys live in the data-protection
        // keychain regardless, so any mismatch between create and subsequent lookups
        // surfaces as `errSecItemNotFound` even though the key is resident.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: privateAttrs
        ]

        var genError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &genError) else {
            let err = genError?.takeRetainedValue()
            // Most common failure modes: not running on real hardware (simulator without SE),
            // device without an Enclave, or an existing tag collision.
            logger.error("SE key generation failed: \(String(describing: err))")
            throw KeyManagerError.keyGenerationFailed(err)
        }

        return try openSSHPublicKeyWireFormat(from: privateKey)
    }

    /// Looks up the SE-backed `SecKey` reference for a credential.
    ///
    /// The returned reference can be passed to `SecKeyCreateSignature` to produce
    /// signatures (which will prompt for biometric / passcode). It cannot be used to
    /// extract the private key bytes; those never leave the Enclave.
    static func privateKey(for credentialID: UUID) throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: applicationTag(for: credentialID),
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else {
            throw KeyManagerError.keyNotFound(credentialID)
        }
        // kSecClass = kSecClassKey + kSecReturnRef = true guarantees a SecKey on success.
        return item as! SecKey
    }

    /// Removes the SE-backed key for a credential. Idempotent: `errSecItemNotFound`
    /// is treated as success so the caller can use this during cleanup without first
    /// confirming the key exists.
    ///
    /// Throws on any other Keychain failure so callers can leave the surrounding
    /// SwiftData record alone and retry. An orphaned SE key with no metadata is a
    /// worse end state than a credential the user can delete again.
    static func deleteKey(for credentialID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag(for: credentialID),
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Failed to delete SE key for \(credentialID): \(status)")
            throw KeyManagerError.deletionFailed(status)
        }
    }

    /// Lists credential IDs that currently have a Secure Enclave-resident key.
    ///
    /// Used by the credentials UI to reconcile what's in SwiftData against what the
    /// Enclave actually still holds, surfacing orphans created by manual Keychain
    /// edits or sysadmin-side deletions.
    static func resident() -> [UUID] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let tag = item[kSecAttrApplicationTag as String] as? Data,
                  let tagString = String(data: tag, encoding: .utf8),
                  tagString.hasPrefix(tagPrefix) else {
                return nil
            }
            return UUID(uuidString: String(tagString.dropFirst(tagPrefix.count)))
        }
    }

    // MARK: - Signing

    /// Signs `message` with the SE-backed credential. Uses
    /// `ecdsaSignatureMessageX962SHA256`: the Enclave hashes the message itself and
    /// returns a DER-encoded ASN.1 ECDSA signature.
    ///
    /// Every invocation prompts for biometric or device passcode. This is the
    /// human-attested signing operation that ADR 0001 §1 requires for every session.
    static func sign(_ message: Data, for credentialID: UUID) throws -> Data {
        let privateKey = try privateKey(for: credentialID)
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &signError
        ) else {
            throw KeyManagerError.signatureFailed(signError?.takeRetainedValue())
        }
        return signature as Data
    }

    // MARK: - Public-key export

    /// Returns the OpenSSH wire-format encoding of the public key for the given credential
    /// (i.e. the raw bytes that get base64-encoded to form the second field of an
    /// `authorized_keys` line for `ecdsa-sha2-nistp256`).
    static func openSSHPublicKeyWireFormat(for credentialID: UUID) throws -> Data {
        let privateKey = try privateKey(for: credentialID)
        return try openSSHPublicKeyWireFormat(from: privateKey)
    }

    /// Renders an `authorized_keys`-style line for the given credential.
    static func authorizedKeysLine(
        for credentialID: UUID,
        comment: String? = nil
    ) throws -> String {
        let wire = try openSSHPublicKeyWireFormat(for: credentialID)
        let base64 = wire.base64EncodedString()
        if let comment, !comment.isEmpty {
            return "\(opensshAlgorithm) \(base64) \(comment)"
        }
        return "\(opensshAlgorithm) \(base64)"
    }

    // MARK: - Internals

    /// Derives the OpenSSH wire encoding for an SE-resident ECDSA P-256 keypair.
    ///
    /// `SecKeyCopyExternalRepresentation` on the public half returns 65 bytes:
    /// `0x04 || X(32 bytes) || Y(32 bytes)` (the SEC1 uncompressed point). OpenSSH
    /// frames the same value with two length-prefixed strings ahead of it:
    ///
    ///     string  "ecdsa-sha2-nistp256"
    ///     string  "nistp256"
    ///     string  Q       (the 65-byte uncompressed point)
    ///
    /// where each `string` is a big-endian uint32 length followed by the payload.
    private static func openSSHPublicKeyWireFormat(from privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KeyManagerError.publicKeyDerivationFailed
        }
        var exportError: Unmanaged<CFError>?
        guard let cfData = SecKeyCopyExternalRepresentation(publicKey, &exportError) else {
            throw KeyManagerError.publicKeyExportFailed(exportError?.takeRetainedValue())
        }
        return try openSSHWireFormat(secp256r1Point: cfData as Data)
    }

    /// Encodes a SEC1 uncompressed P-256 public point as `ecdsa-sha2-nistp256`
    /// OpenSSH wire format per RFC 5656 §3.1:
    ///
    ///     string  "ecdsa-sha2-nistp256"
    ///     string  "nistp256"
    ///     string  Q                       (65-byte SEC1 point: 0x04 || X || Y)
    ///
    /// Each `string` is a big-endian `uint32` length followed by the payload, giving
    /// a fixed total of `4 + 19 + 4 + 8 + 4 + 65 = 108` bytes.
    ///
    /// Internal so the wire-format unit tests can exercise it with a CryptoKit-
    /// generated point and assert byte-for-byte against the RFC; production callers
    /// reach this through `openSSHPublicKeyWireFormat(from:)`.
    internal static func openSSHWireFormat(secp256r1Point point: Data) throws -> Data {
        // 65 bytes for SEC1 uncompressed P-256; the leading 0x04 distinguishes the
        // uncompressed form from compressed encodings (0x02 / 0x03).
        guard point.count == 65, point.first == 0x04 else {
            throw KeyManagerError.unexpectedPublicKeyFormat
        }
        var wire = Data()
        wire.appendOpenSSHString(opensshAlgorithm)
        wire.appendOpenSSHString(opensshCurveName)
        wire.appendOpenSSHString(point)
        return wire
    }
}

// MARK: - Debug inspection

#if DEBUG

extension SecureEnclaveKeyManager {

    /// Snapshot of the Keychain attributes for a Pulse SSH credential. Backs the
    /// Settings → SSH context-menu "Inspect key attributes" action so the operator
    /// can confirm at runtime that keys land in the expected access group, are
    /// pinned to the data-protection keychain, aren't synchronisable, and use the
    /// expected access-control policy.
    ///
    /// For Secure Enclave-token credentials the policy is sourced from the
    /// `SecAccessControl` flags we set at creation, not from `kSecAttrAccessible`.
    /// The OS sets that attribute for SE entries independently of the real policy,
    /// and there is no public API to introspect a stored `SecAccessControl`. The
    /// values we report are the constants the generator uses; if those constants
    /// ever change, the report changes with them.
    ///
    /// Compiled out of Release builds.
    struct KeyInspection {
        let accessGroup: String
        let tokenID: String
        let synchronizable: Bool
        /// Human-readable description of the access policy gating use of this key.
        /// For SE credentials: sourced from the SecAccessControl flags configured
        /// in `generateKey`. For portable credentials: decoded from the meaningful
        /// `kSecAttrAccessible` attribute.
        let accessControl: String
    }

    /// Reads the Keychain attribute record for `credentialID` without touching the
    /// private material. Attribute lookup does not require user presence, so this
    /// does not trigger a biometric prompt. Throws `keyNotFound` if no key is
    /// resident under the credential's application tag.
    static func inspect(_ credentialID: UUID) throws -> KeyInspection {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag(for: credentialID),
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let attrs = result as? [String: Any] else {
            throw KeyManagerError.keyNotFound(credentialID)
        }

        let tokenID = (attrs[kSecAttrTokenID as String] as? String) ?? "(none)"
        let isSecureEnclave = tokenID == "com.apple.setoken"

        // SE-token entries: the kSecAttrAccessible value reported by the OS is
        // vestigial. Source the policy from the SecAccessControl flags we set in
        // generateKey. Portable entries: kSecAttrAccessible is meaningful.
        let accessControl: String
        if isSecureEnclave {
            accessControl =
                "biometryAny OR devicePasscode, " +
                "privateKeyUsage, " +
                "WhenUnlockedThisDeviceOnly"
        } else {
            let raw = (attrs[kSecAttrAccessible as String] as? String) ?? "(none)"
            accessControl = decodePortableAccessibility(raw)
        }

        return KeyInspection(
            accessGroup: attrs[kSecAttrAccessGroup as String] as? String ?? "(none)",
            tokenID: tokenID,
            synchronizable: (attrs[kSecAttrSynchronizable as String] as? Bool) ?? false,
            accessControl: accessControl
        )
    }

    /// Decodes the short-form `kSecAttrAccessible` tag into the matching Apple
    /// constant name. Used only for portable-tier credentials where the attribute
    /// reflects the real policy. SE-token credentials route around this entirely
    /// (see `inspect(_:)`).
    ///
    /// The deprecated `kSecAttrAccessibleAlways` variants (`dk`, `dku`) are
    /// deliberately absent from the decoder. Pulse never sets those on portable
    /// items, so seeing them here would be a regression to surface — not a value
    /// to politely decode.
    private static func decodePortableAccessibility(_ raw: String) -> String {
        switch raw {
        case "ak":   return "kSecAttrAccessibleWhenUnlocked"
        case "ck":   return "kSecAttrAccessibleAfterFirstUnlock"
        case "aku":  return "kSecAttrAccessibleWhenUnlockedThisDeviceOnly"
        case "cku":  return "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"
        case "akpu": return "kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly"
        default:     return "\(raw) (unrecognised)"
        }
    }
}

#endif

