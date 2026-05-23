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
/// `prime256v1`) — not Ed25519, not RSA. This is hardware. Modern OpenSSH servers
/// (≥6.5, 2014) accept `ecdsa-sha2-nistp256` so the constraint is purely a
/// compatibility note, not a security one. See ADR 0001 §1.
///
/// Every signature triggers a biometric / device-passcode prompt because the keys are
/// created with `.privateKeyUsage` combined with `.biometryCurrentSet`. No caching of
/// the authorisation across signatures. The prompt is driven by `SecKeyCreateSignature`
/// itself — callers must not invoke `LAContext.evaluatePolicy` directly.
///
/// The NIOSSH signer bridge that exposes these primitives to swift-nio-ssh lives in
/// Slice 3. Slice 1 deliberately stops at the Security-framework level so the SE
/// machinery can be built and tested without NIOSSH.
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
            }
        }
    }

    // MARK: - Identity

    /// Prefix applied to every `kSecAttrApplicationTag` so the Pulse keys are filterable
    /// from any other ECDSA P-256 keys living on this device.
    private static let tagPrefix = "nz.omega.pulse.ssh."

    /// Stable application tag for a given credential id. The tag is what we look the
    /// key up by — `id` does not appear elsewhere in the Keychain query.
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
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet, .or, .devicePasscode],
            &accessError
        ) else {
            throw KeyManagerError.accessControlCreationFailed(accessError?.takeRetainedValue())
        }

        let privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: applicationTag(for: credentialID),
            kSecAttrLabel as String: label,
            kSecAttrAccessControl as String: access
        ]

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
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
    /// extract the private key bytes — those never leave the Enclave.
    static func privateKey(for credentialID: UUID) throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: applicationTag(for: credentialID),
            kSecReturnRef as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let ref = result else {
            throw KeyManagerError.keyNotFound(credentialID)
        }
        return ref as! SecKey
    }

    /// Removes the SE-backed key for a credential. Idempotent — succeeds even when no
    /// key is currently resident (used during `SSHCredential` deletion cleanup).
    static func deleteKey(for credentialID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag(for: credentialID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Failed to delete SE key for \(credentialID): \(status)")
        }
    }

    /// Lists credential IDs that currently have a Secure Enclave-resident key.
    ///
    /// Used by the credentials UI to reconcile what's in SwiftData against what the
    /// Enclave actually still holds — and to surface orphans created by manual
    /// Keychain edits or sysadmin-side deletions.
    static func resident() -> [UUID] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecMatchLimit as String: kSecMatchLimitAll,
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
    /// `ecdsaSignatureMessageX962SHA256` — the Enclave hashes the message itself, the
    /// result is a DER-encoded ASN.1 ECDSA signature.
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
            return "ecdsa-sha2-nistp256 \(base64) \(comment)"
        }
        return "ecdsa-sha2-nistp256 \(base64)"
    }

    // MARK: - Internals

    /// Derives the OpenSSH wire encoding for an SE-resident ECDSA P-256 keypair.
    ///
    /// `SecKeyCopyExternalRepresentation` on the public half returns 65 bytes:
    /// `0x04 || X(32 bytes) || Y(32 bytes)` — the SEC1 uncompressed point. OpenSSH
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
        let point = cfData as Data
        // 65 bytes for uncompressed P-256; defensive — surface any future surprise loudly.
        guard point.count == 65, point.first == 0x04 else {
            throw KeyManagerError.unexpectedPublicKeyFormat
        }

        var wire = Data()
        wire.appendOpenSSHString("ecdsa-sha2-nistp256")
        wire.appendOpenSSHString("nistp256")
        wire.appendOpenSSHString(point)
        return wire
    }
}

// MARK: - OpenSSH framing helper

private extension Data {
    /// Appends a length-prefixed string. The length is a big-endian uint32.
    mutating func appendOpenSSHString(_ string: String) {
        appendOpenSSHString(Data(string.utf8))
    }

    /// Appends a length-prefixed binary string. The length is a big-endian uint32.
    mutating func appendOpenSSHString(_ payload: Data) {
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(payload)
    }
}
