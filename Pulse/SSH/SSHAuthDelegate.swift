//
//  SSHAuthDelegate.swift
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
import NIOCore
import NIOSSH
import OSLog

// MARK: - PEM provider seam

/// Sendable, async-throwing accessor for portable-credential PEM bytes.
/// Production conformances wrap `Configuration.sshPrivateKeyPEM(for:)`; tests
/// inject a synchronous in-memory provider.
typealias PortablePEMProvider = @Sendable () async -> Data?

// MARK: - Errors

enum SSHAuthDelegateError: Error, CustomStringConvertible, Equatable {
    case secureEnclaveCredentialNotFound(UUID)
    case portablePEMUnavailable(UUID)
    case unsupportedPortableKeyFormat
    case certificateParseFailed(String)

    var description: String {
        switch self {
        case .secureEnclaveCredentialNotFound(let id):
            return "Secure Enclave credential \(id) not resident on this device."
        case .portablePEMUnavailable(let id):
            return "Portable credential \(id) has no PEM stored or the Keychain read failed."
        case .unsupportedPortableKeyFormat:
            return
                "Portable key isn't in any v1-supported format. Pulse v1 accepts unencrypted "
                + "ECDSA P-256/384/521 (traditional, PKCS#8, OpenSSH new-format) and "
                + "unencrypted Ed25519 (OpenSSH new-format)."
        case .certificateParseFailed(let reason):
            return "Stored certificate didn't parse: \(reason)."
        }
    }
}

// MARK: - Delegate

/// `NIOSSHClientUserAuthenticationDelegate` that drives SSH user
/// authentication from a single credential, optionally presenting a CA-signed
/// certificate. Three signing paths land here:
///
/// - **`.secureEnclave`** (Primary tier): the credential's
///   `SecureEnclave.P256.Signing.PrivateKey` is loaded via
///   `SecureEnclaveKeyManager.cryptoKitPrivateKey(for:)` and handed to
///   `NIOSSHPrivateKey(secureEnclaveP256Key:)`. CryptoKit's SE path triggers
///   the biometric / passcode prompt per signing — ADR §1's human-attested
///   contract.
///
/// - **`.portable`** + OpenSSH new-format PEM: decoded via
///   `SSHKeyImporter.decodeOpenSSHPrivateKey`. The resulting algorithm-specific
///   material wraps in the matching CryptoKit primitive
///   (`Curve25519.Signing.PrivateKey`, `P256/P384/P521.Signing.PrivateKey`)
///   and then in `NIOSSHPrivateKey`.
///
/// - **`.portable`** + traditional or PKCS#8 ECDSA PEM: CryptoKit's
///   `pemRepresentation` initialisers handle the curve detection themselves;
///   the auth delegate tries P-256 → P-384 → P-521 until one succeeds.
///
/// RSA, encrypted PEMs, Ed25519 in non-OpenSSH-new-format are rejected at
/// the importer's front door; they never reach this delegate.
///
/// **Audit emissions (ADR §7).** Once per auth attempt:
/// - `cert.expired` under `ssh.certificates` when a stored cert fails the
///   `isValid(_:at:)` window check; the delegate falls back to the bare
///   public key.
/// - `cert.accepted` under `ssh.certificates` when the cert is offered to
///   NIOSSH (the delegate's perspective on cert acceptance; the server may
///   still reject).
/// - `cert.rejected` under `ssh.certificates` when NIOSSH calls back after
///   the cert offer (signalling server rejection).
/// - `auth.success` is emitted by `SSHClient` on session-open (the delegate
///   protocol gives no per-offer success callback).
/// - `auth.failure` under `ssh.auth` when the delegate exhausts its offer
///   list and returns nil, which terminates the connection.
final class SSHAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {

    // Inputs
    private let username: String
    private let host: String
    private let port: Int
    private let credentialID: UUID
    private let tier: SSHCredentialTier
    private let certificateBlob: Data?
    private let pemProvider: PortablePEMProvider
    private let now: @Sendable () -> Date

    // Mutable state, protected by the lock. The delegate's
    // `nextAuthenticationType` may be invoked from any thread; the lock
    // serialises the attempt counter, the offered-cert flag, and the
    // load-failure latch.
    private let stateLock = NSLock()
    private var _attemptIndex = 0
    private var _offeredCert = false
    /// One-shot latch. Once a key-load failure (or any other
    /// `computeNextOffer` throw) has emitted `auth.failure`, subsequent
    /// `nextAuthenticationType` callbacks return `nil` immediately with
    /// no further emission. Prevents the same failure from logging on
    /// every NIOSSH retry callback for one connection attempt.
    private var _loadFailed = false

    private let authLogger = Logger(subsystem: "pulse", category: "ssh.auth")
    private let certLogger = Logger(subsystem: "pulse", category: "ssh.certificates")

    init(
        username: String,
        host: String,
        port: Int,
        credentialID: UUID,
        tier: SSHCredentialTier,
        certificateBlob: Data?,
        pemProvider: @escaping PortablePEMProvider,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.username = username
        self.host = host
        self.port = port
        self.credentialID = credentialID
        self.tier = tier
        self.certificateBlob = certificateBlob
        self.pemProvider = pemProvider
        self.now = now
    }

    /// True if this delegate has offered a CA-signed certificate during the
    /// current connection attempt. `SSHClient` reads this on session-open
    /// to decide whether the resulting `auth.success` should also emit a
    /// `cert.accepted` qualifier (the delegate alone cannot observe whole-
    /// attempt success — see the audit-emissions doc-comment above).
    var didOfferCertificate: Bool {
        stateLock.withLock { _offeredCert }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // The credential lookup and private-key construction are async and
        // can read the Keychain; hop off the EventLoop with `Task { ... }`
        // and complete the promise from the cooperative pool. NIOCore's
        // promise machinery handles the back-hop to the channel's
        // EventLoop. Do not "optimise" by inlining the lookup on the calling
        // thread; the Keychain read can block, and blocking the EventLoop
        // stalls every other channel sharing it (same pattern as the
        // host-key delegate).
        let username = self.username
        let host = self.host
        let port = self.port

        Task {
            do {
                let offer = try await self.computeNextOffer()
                nextChallengePromise.succeed(offer)
            } catch {
                // Latch the load-failure state under the lock before we emit
                // and complete the promise. Subsequent NIOSSH callbacks see
                // `_loadFailed == true` and short-circuit without re-logging.
                self.stateLock.withLock { self._loadFailed = true }
                self.authLogger.error(
                    "auth.failure user=\(username, privacy: .public) host=\(host, privacy: .public) port=\(port) error=\(String(describing: error), privacy: .public)"
                )
                nextChallengePromise.fail(error)
            }
        }
    }

    // MARK: - Offer construction

    private func computeNextOffer() async throws -> NIOSSHUserAuthenticationOffer? {
        // Snapshot + bump under the lock. If a prior call latched
        // `_loadFailed`, return `nil` immediately and do not emit — the
        // original failure already logged its `auth.failure`.
        let (attempt, alreadyOfferedCert, loadFailed): (Int, Bool, Bool) = stateLock.withLock {
            let snapshot = (_attemptIndex, _offeredCert, _loadFailed)
            _attemptIndex += 1
            return snapshot
        }
        if loadFailed {
            return nil
        }

        switch attempt {
        case 0:
            return try await firstOffer()
        case 1 where alreadyOfferedCert:
            // The cert we offered first was rejected by the server; fall
            // back to the bare public key on a second attempt.
            certLogger.warning(
                "cert.rejected user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port) credential=\(self.credentialID, privacy: .public)"
            )
            return try await bareKeyOffer()
        default:
            // Exhausted: either we already offered the bare key, or we
            // started with the bare key and that was rejected.
            authLogger.warning(
                "auth.failure user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port) reason=offers-exhausted attempts=\(attempt)"
            )
            return nil
        }
    }

    private func firstOffer() async throws -> NIOSSHUserAuthenticationOffer {
        let privateKey = try await loadPrivateKey()

        if let blob = certificateBlob {
            do {
                let cert = try SSHCertificateManager.parse(blob)
                let metadata = try SSHCertificateManager.metadata(for: blob)
                if SSHCertificateManager.isValid(metadata, at: now()) {
                    stateLock.withLock { _offeredCert = true }
                    // `cert.offered` — the delegate's local validity check
                    // passed and we're presenting the cert to NIOSSH. The
                    // server may still reject. The post-hoc `cert.accepted`
                    // emission lives in `SSHClient` and fires only on
                    // session-open with `didOfferCertificate == true`.
                    certLogger.info(
                        "cert.offered user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port) credential=\(self.credentialID, privacy: .public) keyID=\(metadata.keyID, privacy: .public) ca=\(metadata.caFingerprintSHA256, privacy: .public)"
                    )
                    return NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "ssh-connection",
                        offer: .privateKey(.init(privateKey: privateKey, certifiedKey: cert))
                    )
                } else {
                    certLogger.warning(
                        "cert.expired user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port) credential=\(self.credentialID, privacy: .public) keyID=\(metadata.keyID, privacy: .public) validBefore=\(metadata.validBefore.timeIntervalSince1970)"
                    )
                    // Fall through to bare-key offer.
                }
            } catch {
                certLogger.warning(
                    "cert.expired user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port) credential=\(self.credentialID, privacy: .public) reason=parse-failed: \(String(describing: error), privacy: .public)"
                )
                // Fall through to bare-key offer.
            }
        }

        return NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: privateKey))
        )
    }

    private func bareKeyOffer() async throws -> NIOSSHUserAuthenticationOffer {
        let privateKey = try await loadPrivateKey()
        return NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: privateKey))
        )
    }

    // MARK: - Private-key loading

    private func loadPrivateKey() async throws -> NIOSSHPrivateKey {
        switch tier {
        case .secureEnclave:
            do {
                let key = try SecureEnclaveKeyManager.cryptoKitPrivateKey(for: credentialID)
                return NIOSSHPrivateKey(secureEnclaveP256Key: key)
            } catch {
                throw SSHAuthDelegateError.secureEnclaveCredentialNotFound(credentialID)
            }
        case .portable:
            // PEM materialises as a transient `String` for CryptoKit's
            // `pemRepresentation` initialisers
            // (`P{256,384,521}.Signing.PrivateKey(pemRepresentation:)`).
            // The String is unzeroable but the window is bounded by the
            // duration of the SSH handshake — milliseconds — not by view
            // lifetime. We cannot avoid the conversion: CryptoKit's PEM
            // init API takes `String`. The improvement over holding it
            // longer is real but not absolute; same framing as
            // `SSHCredentialsSettings.ImportLegacyCredentialSheet`'s
            // `@State Data` zeroing block. Do not "fix"
            // by wrapping CryptoKit: the API boundary is the constraint.
            guard let pemData = await pemProvider(),
                  let pem = String(data: pemData, encoding: .utf8) else {
                throw SSHAuthDelegateError.portablePEMUnavailable(credentialID)
            }
            return try Self.buildPortablePrivateKey(fromPEM: pem)
        }
    }

    /// Try to construct a `NIOSSHPrivateKey` from a portable PEM string.
    ///
    /// Three paths, attempted in order:
    ///
    /// 1. OpenSSH new-format decoder (`SSHKeyImporter.decodeOpenSSHPrivateKey`).
    ///    Covers ssh-keygen-default output for ECDSA P-256/384/521 and
    ///    Ed25519. Falls through on `.notOpenSSHNewFormat`.
    /// 2. CryptoKit's `P256/P384/P521.Signing.PrivateKey(pemRepresentation:)`,
    ///    tried in order. Covers traditional `BEGIN EC PRIVATE KEY` (SEC1)
    ///    and PKCS#8 `BEGIN PRIVATE KEY` carrying ecPublicKey. CryptoKit
    ///    rejects the wrong-curve PEM with a recoverable throw, so the
    ///    next curve is tried until one succeeds.
    /// 3. None matched: throws `.unsupportedPortableKeyFormat`. Should be
    ///    unreachable in practice — the importer's front-door reject filters
    ///    everything outside the v1 portable scope.
    ///
    /// `internal` rather than `private static` so tests can exercise the
    /// branch logic without spinning up a Keychain-backed credential.
    static func buildPortablePrivateKey(fromPEM pem: String) throws -> NIOSSHPrivateKey {
        // Path 1: OpenSSH new-format decoder.
        do {
            let decoded = try SSHKeyImporter.decodeOpenSSHPrivateKey(from: pem)
            switch decoded {
            case .ed25519(let seed):
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                return NIOSSHPrivateKey(ed25519Key: key)
            case .ecdsaP256(let scalar):
                let key = try P256.Signing.PrivateKey(rawRepresentation: scalar)
                return NIOSSHPrivateKey(p256Key: key)
            case .ecdsaP384(let scalar):
                let key = try P384.Signing.PrivateKey(rawRepresentation: scalar)
                return NIOSSHPrivateKey(p384Key: key)
            case .ecdsaP521(let scalar):
                let key = try P521.Signing.PrivateKey(rawRepresentation: scalar)
                return NIOSSHPrivateKey(p521Key: key)
            }
        } catch SSHKeyImporter.OpenSSHDecodeError.notOpenSSHNewFormat {
            // Fall through to the CryptoKit PEM-init chain.
        }

        // Path 2: CryptoKit PEM init chain, P-256 → P-384 → P-521.
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p256Key: key)
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p384Key: key)
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p521Key: key)
        }

        throw SSHAuthDelegateError.unsupportedPortableKeyFormat
    }
}
