//
//  SessionLogWrappingKey.swift
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
import NIOConcurrencyHelpers
import OSLog
import Security

/// Manages the single Secure-Enclave-resident ECDH-P256 key that every
/// session-log wraps its per-session AES key to. One key per device. Not
/// per-credential, not per-session.
///
/// **Why a separate file from `SecureEnclaveKeyManager`.** The signing-key
/// surface and the wrapping-key surface share a
/// storage pattern but model very different concerns:
///
/// - Signing keys are operator-facing identity. Each credential is its own
///   key; deletion is a routine CRUD action; the credential editor
///   surfaces fingerprints and per-credential metadata.
/// - The log wrapping key is the root of recording confidentiality on
///   this device. Deleting it destroys access to every historical
///   recording. It has no operator-facing UI in the current build (the
///   future "purge all recordings" gesture is out of scope here) and no
///   per-credential cardinality.
///
/// Keeping the two surfaces in separate files makes the intent legible
/// at the call site and prevents accidental "delete the wrong key"
/// patterns where, e.g., a credentials-list reconciliation pass thinks
/// it owns the wrapping key.
///
/// **Storage shape.** Mirrors `SecureEnclaveKeyManager`'s pattern:
/// `kSecClassGenericPassword` under service
/// `<Bundle.main.bundleIdentifier>.ssh.logwrap` and account
/// `"log-wrapping"`. The service suffix is `.ssh.logwrap` rather than
/// `.ssh` so a `SecItemCopyMatching` against the SSH credential service
/// can never accidentally surface the wrapping key, and vice versa.
/// The account string is a literal rather than a UUID because there is
/// exactly one wrapping key per device — using a UUID would imply more
/// cardinality than the model supports.
///
/// **Access control.** Same flags as the signing path:
/// `[.privateKeyUsage, .biometryAny, .or, .devicePasscode]` with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Reading the
/// `dataRepresentation` blob from the Keychain (`publicKey()`,
/// `loadOrCreate()`) does not trigger biometric. Calling
/// `sharedSecretFromKeyAgreement(with:)` against the returned private-key
/// handle does — which is the seam where replay-side biometric fires in
/// production.
///
/// **No iCloud sync.** `kSecAttrSynchronizable: false`. The recording
/// posture inherits the SSH-credential migration story: lose the device,
/// lose the logs. This is called out in `docs/credentials.md`.
enum SessionLogWrappingKey {

    // MARK: - Errors

    enum WrappingKeyError: Error, CustomStringConvertible, Equatable {
        case secureEnclaveUnavailable
        case accessControlCreationFailed
        case keyGenerationFailed(String)
        case keychainStoreFailed(OSStatus)
        case keychainReadFailed(OSStatus)
        case dataRepresentationInvalid(String)
        case deletionFailed(OSStatus)

        var description: String {
            switch self {
            case .secureEnclaveUnavailable:
                return "Secure Enclave is not available on this device; session-log recording cannot wrap a session key."
            case .accessControlCreationFailed:
                return "Failed to create Secure Enclave access control for the session-log wrapping key."
            case .keyGenerationFailed(let reason):
                return "Session-log wrapping key generation failed: \(reason)"
            case .keychainStoreFailed(let status):
                return "Failed to store the session-log wrapping key blob in the Keychain (OSStatus \(status))."
            case .keychainReadFailed(let status):
                return "Failed to read the session-log wrapping key blob from the Keychain (OSStatus \(status))."
            case .dataRepresentationInvalid(let reason):
                return "Stored session-log wrapping key blob is not a valid SecureEnclave.P256.KeyAgreement dataRepresentation: \(reason)"
            case .deletionFailed(let status):
                return "Session-log wrapping key deletion failed (OSStatus \(status))."
            }
        }

        static func == (lhs: WrappingKeyError, rhs: WrappingKeyError) -> Bool {
            switch (lhs, rhs) {
            case (.secureEnclaveUnavailable, .secureEnclaveUnavailable),
                 (.accessControlCreationFailed, .accessControlCreationFailed):
                return true
            case (.keychainStoreFailed(let a), .keychainStoreFailed(let b)),
                 (.keychainReadFailed(let a), .keychainReadFailed(let b)),
                 (.deletionFailed(let a), .deletionFailed(let b)):
                return a == b
            case (.keyGenerationFailed(let a), .keyGenerationFailed(let b)),
                 (.dataRepresentationInvalid(let a), .dataRepresentationInvalid(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Identity

    /// Keychain service for the wrapping key. Derived from
    /// `Bundle.main.bundleIdentifier` at runtime so it tracks the
    /// operator's `BUNDLE_IDENTIFIER` xcconfig automatically. The
    /// `.ssh.logwrap` suffix is distinct from the SSH credential
    /// service `.ssh` so the two key sets never collide in
    /// `SecItemCopyMatching` queries.
    ///
    /// The fallback literal is the Omega default; it covers test
    /// contexts where `Bundle.main` may not resolve to a configured
    /// bundle. A fork that didn't populate `Development.xcconfig`
    /// would land here too, which is the right safety net rather than
    /// a crash.
    static let keychainService: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "nz.net.omega.pulse"
        return "\(bundleID).ssh.logwrap"
    }()

    /// Account string for the single per-device wrapping key. A literal
    /// rather than a UUID because there is exactly one such key per
    /// device; using a UUID would imply more cardinality than the model
    /// supports.
    static let keychainAccount = "log-wrapping"

    /// Human-legible label that appears in Keychain Access for operator
    /// diagnostic surfaces. Not load-bearing; the `(service, account)`
    /// pair is the identification key.
    static let keychainLabel = "Pulse session-log wrapping key"

    private static let logger = Logger(subsystem: "pulse", category: "ssh.recording")

    /// Serialises the check-then-create path so two concurrent
    /// `loadOrCreate()` calls on a fresh install can't both generate a
    /// wrapping key, race the Keychain insert, and leave one of the
    /// keys orphaned (along with the recordings it would wrap). The
    /// fast path (key already exists) never takes this lock.
    private static let creationLock = NIOLock()

    // MARK: - Lifecycle

    /// Returns the device's SE-resident wrapping private key, generating
    /// it if none is yet present. Idempotent and concurrency-safe via a
    /// double-checked-locking pattern on `creationLock`: the no-lock
    /// happy path covers all calls after first generation.
    ///
    /// Reading the SE-encrypted `dataRepresentation` blob and re-hydrating
    /// it does not require user presence; the biometric prompt fires the
    /// first time `sharedSecretFromKeyAgreement(with:)` runs against the
    /// returned handle, which is the seam ``SessionLogCrypto/unwrap(_:with:)``
    /// uses on the replay path.
    @discardableResult
    static func loadOrCreate() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let existing = try readResidentKey() {
            return existing
        }
        return try creationLock.withLock {
            // Re-read inside the lock: another thread may have created
            // the key while we were waiting. The fast path above
            // covers the steady state; this branch covers the
            // first-launch race window only.
            if let existing = try readResidentKey() {
                return existing
            }
            return try generateAndStore()
        }
    }

    /// Returns the wrapping public key, materialising the wrapping key
    /// itself if needed. The public-key extraction does not trigger
    /// biometric; callers that just want to wrap a fresh session key can
    /// rely on this being silent.
    static func publicKey() throws -> P256.KeyAgreement.PublicKey {
        let priv = try loadOrCreate()
        return priv.publicKey
    }

    // MARK: - Internals

    private static func readResidentKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let blob = item as? Data else {
                throw WrappingKeyError.keychainReadFailed(errSecParam)
            }
            do {
                return try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: blob
                )
            } catch {
                throw WrappingKeyError.dataRepresentationInvalid(String(describing: error))
            }
        case errSecItemNotFound:
            return nil
        default:
            throw WrappingKeyError.keychainReadFailed(status)
        }
    }

    private static func generateAndStore() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        guard SecureEnclave.isAvailable else {
            throw WrappingKeyError.secureEnclaveUnavailable
        }

        var accessError: Unmanaged<CFError>?
        // Same SecAccessControl shape as the signing path in
        // SecureEnclaveKeyManager: biometry-any or device passcode,
        // private-key usage, gated by the "device is unlocked" class.
        // The `.biometryAny` policy (rather than `.biometryCurrentSet`)
        // means an operator adding or removing a Touch ID enrolment
        // doesn't invalidate the wrapping key — which would invalidate
        // every historical recording on the device.
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny, .or, .devicePasscode],
            &accessError
        ) else {
            if let err = accessError?.takeRetainedValue() {
                logger.error("SecAccessControlCreateWithFlags failed for log wrapping key: \(String(describing: err))")
            }
            throw WrappingKeyError.accessControlCreationFailed
        }

        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        } catch {
            logger.error("SE wrapping-key generation failed: \(String(describing: error))")
            throw WrappingKeyError.keyGenerationFailed(String(describing: error))
        }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrLabel as String: keychainLabel,
            kSecValueData as String: key.dataRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            logger.notice("Session-log wrapping key generated and stored at service \(keychainService, privacy: .public)")
            return key
        case errSecDuplicateItem:
            // Another process raced us to creation. The lock above
            // guards intra-process; this branch handles the unlikely
            // multi-process case (e.g., a debug build and a release
            // build of Pulse running side by side under the same
            // bundle ID — possible during signing migrations).
            // Re-read and return the winning key.
            if let existing = try readResidentKey() {
                logger.notice("Session-log wrapping key already existed; discarded freshly-generated duplicate")
                return existing
            }
            throw WrappingKeyError.keychainStoreFailed(status)
        default:
            logger.error("Session-log wrapping key Keychain store failed: \(status)")
            throw WrappingKeyError.keychainStoreFailed(status)
        }
    }
}

// MARK: - Test seam

#if DEBUG

extension SessionLogWrappingKey {

    /// Removes the device's log wrapping key. **Not part of the
    /// operator-facing API.** Deleting the wrapping key destroys access
    /// to every recording on this device that was wrapped against it.
    /// Exposed under `#if DEBUG` so unit tests can clean up after
    /// themselves; production code never deletes the wrapping key, and
    /// no operator gesture in the current build reaches this method.
    ///
    /// Idempotent: `errSecItemNotFound` is treated as success.
    static func __deleteForTests() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WrappingKeyError.deletionFailed(status)
        }
    }

    /// Indicates whether a wrapping key is currently resident in the
    /// Keychain. Used by tests to assert the post-condition of
    /// `loadOrCreate()` without triggering a key generation. Reads the
    /// attribute record, not the key material; non-biometric.
    static func __isResidentForTests() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess
    }
}

#endif
