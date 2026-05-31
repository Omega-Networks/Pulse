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
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import CryptoKit
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
/// **Storage shape (CryptoKit migration):** keys are managed through CryptoKit's
/// `SecureEnclave.P256.Signing.PrivateKey` and persisted as the opaque
/// `dataRepresentation` blob inside a `kSecClassGenericPassword` Keychain item
/// keyed by `(service, account)` = `("<bundle-id>.ssh", credentialUUID)`.
/// The service name is derived from `Bundle.main.bundleIdentifier` at runtime
/// so it tracks the operator's `BUNDLE_IDENTIFIER` xcconfig setting (e.g.,
/// `nz.net.omega.pulse` → `nz.net.omega.pulse.ssh`). Forks or beta channels
/// that change the bundle ID automatically get a disjoint keychain namespace,
/// which is the structural enforcement of ADR §1's bundle-ID reachability
/// contract: a re-signed build's credentials are never reachable from a
/// differently-signed build.
///
/// The dataRepresentation is encrypted to this device's Secure Enclave and is
/// useless on any other device or to any other application; reading the blob
/// does not trigger biometric and is not a private-key extraction.
///
/// **Why CryptoKit, not Security.framework SecKey:** swift-nio-ssh ships a
/// first-class SE backing (`NIOSSHPrivateKey(secureEnclaveP256Key:)`) that
/// accepts CryptoKit's `SecureEnclave.P256.Signing.PrivateKey` directly. The
/// alternative — forking NIOSSH to expose its internal `BackingKey` enum —
/// carries a merge-debt tax we refuse to take on for a security-critical
/// dependency.
///
/// Every signature triggers a biometric / device-passcode prompt because the keys are
/// created with `[.privateKeyUsage, .biometryAny, .or, .devicePasscode]` baked into
/// the `SecAccessControl` that CryptoKit consumes at generation time. No caching
/// of the authorisation across signatures. The prompt is driven by CryptoKit's
/// `.signature(for:)` (which goes through `LAContext` internally); callers must
/// not invoke `LAContext.evaluatePolicy` directly.
enum SecureEnclaveKeyManager {

    // MARK: - Errors

    enum KeyManagerError: Error, CustomStringConvertible {
        case secureEnclaveUnavailable
        case accessControlCreationFailed(CFError?)
        case keyGenerationFailed(Error)
        case keyNotFound(UUID)
        case publicKeyDerivationFailed
        case unexpectedPublicKeyFormat
        case signatureFailed(Error)
        case keychainStoreFailed(OSStatus)
        case keychainReadFailed(OSStatus)
        case dataRepresentationInvalid(Error)
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
            case .unexpectedPublicKeyFormat:
                return "Secure Enclave public key was not in the expected uncompressed-point format."
            case .signatureFailed(let err):
                return "Secure Enclave signature failed: \(String(describing: err))"
            case .keychainStoreFailed(let status):
                return "Failed to store Secure Enclave key blob in Keychain (OSStatus \(status))."
            case .keychainReadFailed(let status):
                return "Failed to read Secure Enclave key blob from Keychain (OSStatus \(status))."
            case .dataRepresentationInvalid(let err):
                return "Stored Secure Enclave blob isn't a valid dataRepresentation: \(String(describing: err))"
            case .deletionFailed(let status):
                return "Secure Enclave key deletion failed (OSStatus \(status))."
            }
        }
    }

    // MARK: - Identity

    /// Keychain service name shared by every Pulse SE credential. The
    /// `(service, account)` pair is the Keychain's idiomatic identification
    /// for generic-password items; `account` carries the credential UUID.
    ///
    /// Derived from `Bundle.main.bundleIdentifier` rather than hardcoded so
    /// it tracks the operator's `BUNDLE_IDENTIFIER` xcconfig (which flows
    /// into `PRODUCT_BUNDLE_IDENTIFIER` in pbxproj and on into the bundle's
    /// `CFBundleIdentifier` at build time). Bundle-ID resolution routes
    /// through `pulseBundleID()` so a misconfigured test or CI
    /// environment fires a loud fault (and a DEBUG assertion) rather
    /// than silently routing through the production literal.
    private static let keychainService: String = {
        return "\(pulseBundleID()).ssh"
    }()

    /// OpenSSH algorithm identifier for SE-backed keys. Centralised so the wire-format
    /// encoder and the `authorized_keys` rendering can't drift.
    private static let opensshAlgorithm = "ecdsa-sha2-nistp256"

    /// OpenSSH curve identifier for the algorithm above. The "nistp256" string is what
    /// servers compare against the algorithm-name prefix, not the SEC1 OID.
    private static let opensshCurveName = "nistp256"

    private static let logger = Logger(subsystem: "pulse", category: "ssh.secureenclave")

    // MARK: - Lifecycle

    /// Generates a new SE-backed ECDSA P-256 keypair tagged with `credentialID` and
    /// returns the OpenSSH wire-format public key for storage on `SSHCredential`.
    ///
    /// The private half never leaves the Enclave. CryptoKit's
    /// `SecureEnclave.P256.Signing.PrivateKey` type has no API to extract the
    /// raw private scalar; the `dataRepresentation` blob is an SE-encrypted
    /// reference that only this device's SE can unwrap for use. This is a
    /// stronger, compile-time guarantee than the runtime
    /// `SecKeyCopyExternalRepresentation`-returns-nil contract the previous
    /// SecKey-based implementation relied on.
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
        //
        // `.biometryAny` rather than `.biometryCurrentSet` so adding or removing a
        // fingerprint / changing the passcode does not invalidate existing credentials.
        // See ADR 0001 §1 for the threat-model justification.
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny, .or, .devicePasscode],
            &accessError
        ) else {
            throw KeyManagerError.accessControlCreationFailed(accessError?.takeRetainedValue())
        }

        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        } catch {
            logger.error("SE key generation failed: \(String(describing: error))")
            throw KeyManagerError.keyGenerationFailed(error)
        }

        // `kSecAttrSynchronizable: false` is the default for the data-protection
        // keychain on macOS, but setting it explicitly turns a default-behaviour
        // assumption into a structural guarantee: a reviewer can grep
        // `kSecAttrSynchronizable` and confirm SSH keys never opt into iCloud sync.
        //
        // `kSecAttrAccessible` gates the Keychain *read* of the dataRepresentation
        // blob — no biometric, just unlock state. The biometric / passcode gate on
        // signing is baked into the `SecAccessControl` already inside the blob via
        // CryptoKit's `init(accessControl:)`. Two-layered.
        //
        // `kSecUseDataProtectionKeychain` pins this call to the modern data-
        // protection keychain (rather than macOS's legacy file-based keychain),
        // matching where SE-attested material lives regardless.
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: credentialID.uuidString,
            kSecAttrLabel as String: label,
            kSecValueData as String: key.dataRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("SE key Keychain store failed: \(status)")
            throw KeyManagerError.keychainStoreFailed(status)
        }

        return try openSSHPublicKeyWireFormat(from: key)
    }

    /// Loads the SE-backed CryptoKit private key for a credential. The returned
    /// value can be handed directly to `NIOSSHPrivateKey(secureEnclaveP256Key:)`
    /// or signed against via `.signature(for:)`.
    ///
    /// This call reads the SE-encrypted `dataRepresentation` blob from the
    /// Keychain (no biometric) and unwraps it into a usable handle. Signing
    /// against the returned key prompts for biometric / passcode per ADR §1.
    static func cryptoKitPrivateKey(
        for credentialID: UUID
    ) throws -> SecureEnclave.P256.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: credentialID.uuidString,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeyManagerError.keyNotFound(credentialID)
            }
            throw KeyManagerError.keychainReadFailed(status)
        }
        guard let blob = item as? Data else {
            throw KeyManagerError.keychainReadFailed(errSecParam)
        }
        do {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        } catch {
            throw KeyManagerError.dataRepresentationInvalid(error)
        }
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
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: credentialID.uuidString,
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
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return UUID(uuidString: account)
        }
    }

    // MARK: - Signing

    /// Signs `message` with the SE-backed credential and returns the
    /// DER-encoded ECDSA signature (X9.62 / RFC 3279 form). This is what
    /// the existing OpenSSH wire-format consumer expects and is byte-identical
    /// to what the previous `SecKeyCreateSignature` path produced.
    ///
    /// Every invocation prompts for biometric or device passcode via
    /// CryptoKit's `.signature(for:)`. The prompt is the
    /// human-attested signing operation that ADR 0001 §1 requires.
    ///
    /// The auth delegate does not call this directly:
    /// it hands the `SecureEnclave.P256.Signing.PrivateKey` straight to
    /// `NIOSSHPrivateKey(secureEnclaveP256Key:)` which routes signing
    /// through NIOSSH's built-in path. `sign(_:for:)` remains public as
    /// the test seam for "the biometric prompt fires for this credential"
    /// verification scenarios.
    static func sign(_ message: Data, for credentialID: UUID) throws -> Data {
        let key = try cryptoKitPrivateKey(for: credentialID)
        do {
            let signature = try key.signature(for: message)
            return signature.derRepresentation
        } catch {
            throw KeyManagerError.signatureFailed(error)
        }
    }

    // MARK: - Public-key export

    /// Returns the OpenSSH wire-format encoding of the public key for the given credential
    /// (i.e. the raw bytes that get base64-encoded to form the second field of an
    /// `authorized_keys` line for `ecdsa-sha2-nistp256`).
    static func openSSHPublicKeyWireFormat(for credentialID: UUID) throws -> Data {
        let key = try cryptoKitPrivateKey(for: credentialID)
        return try openSSHPublicKeyWireFormat(from: key)
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

    /// Derives the OpenSSH wire encoding from a CryptoKit SE private key.
    ///
    /// `SecureEnclave.P256.Signing.PrivateKey.publicKey.x963Representation`
    /// returns the 65-byte SEC1 uncompressed point: `0x04 || X(32) || Y(32)`.
    /// Byte-identical to what `SecKeyCopyExternalRepresentation` produced
    /// under the previous SecKey-based path, so the wire-format encoder below
    /// works unchanged.
    private static func openSSHPublicKeyWireFormat(
        from privateKey: SecureEnclave.P256.Signing.PrivateKey
    ) throws -> Data {
        try openSSHWireFormat(secp256r1Point: privateKey.publicKey.x963Representation)
    }

    /// Encodes a SEC1 uncompressed P-256 public point as `ecdsa-sha2-nistp256`
    /// OpenSSH wire format per RFC 5656 §3.1:
    ///
    ///     string  "ecdsa-sha2-nistp256"
    ///     string  "nistp256"
    ///     string  Q                       (65-byte SEC1 point: 0x04 || X || Y)
    ///
    /// Each `string` is a big-endian `uint32` length followed by the payload, giving
    /// a fixed total of `4 + 19 + 4 + 8 + 4 + 65 = 104` bytes.
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
    /// **Current storage shape.** Pulse SE credentials are stored as
    /// `kSecClassGenericPassword` items whose `kSecValueData` is the
    /// `dataRepresentation` blob from CryptoKit's
    /// `SecureEnclave.P256.Signing.PrivateKey`. `kSecAttrTokenID` is not set on
    /// this storage class (that attribute is for `kSecClassKey` token-backed
    /// items, which we no longer use); the field is preserved on `KeyInspection`
    /// so the debug surface stays comparable across the migration, with a
    /// descriptive placeholder that calls out the new storage model.
    ///
    /// For the access policy: there is no public API to introspect a stored
    /// `SecAccessControl`, so the reported string is the constants the generator
    /// uses. If those constants change, the report changes with them.
    ///
    /// Compiled out of Release builds.
    struct KeyInspection {
        let accessGroup: String
        let tokenID: String
        let synchronizable: Bool
        /// Human-readable description of the access policy gating signing.
        let accessControl: String
    }

    /// Reads the Keychain attribute record for `credentialID` without touching the
    /// private material. Attribute lookup does not require user presence, so this
    /// does not trigger a biometric prompt. Throws `keyNotFound` if no key is
    /// resident under the credential's service/account pair.
    static func inspect(_ credentialID: UUID) throws -> KeyInspection {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: credentialID.uuidString,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let attrs = result as? [String: Any] else {
            throw KeyManagerError.keyNotFound(credentialID)
        }

        // kSecAttrTokenID isn't set on generic-password items. Report the new
        // storage model so the inspection alert isn't ambiguous.
        let tokenID = "(CryptoKit SE.P256 — generic-password storage)"

        // The access policy is baked into the dataRepresentation blob by
        // CryptoKit's SecureEnclave.P256.Signing.PrivateKey(accessControl:).
        // There's no public API to read it back, so we report the constants
        // the generator uses.
        let accessControl =
            "biometryAny OR devicePasscode, " +
            "privateKeyUsage, " +
            "WhenUnlockedThisDeviceOnly"

        return KeyInspection(
            accessGroup: attrs[kSecAttrAccessGroup as String] as? String ?? "(none)",
            tokenID: tokenID,
            synchronizable: (attrs[kSecAttrSynchronizable as String] as? Bool) ?? false,
            accessControl: accessControl
        )
    }
}

#endif
