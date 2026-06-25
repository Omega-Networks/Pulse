//
//  SSHHostKeyDelegate.swift
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

import Foundation
import NIOCore
import NIOSSH
import OSLog
import SwiftData

// MARK: - Host trust store

/// Persistence-layer seam for `HostTrust` rows so the delegate can be tested
/// without spinning up a SwiftData container. Production conformances wrap a
/// `ModelContainer`; tests inject an in-memory mock.
///
/// All methods are `async throws` so the delegate can stay on the event loop
/// for fingerprint computation and hop to whatever isolation the store needs
/// for the SwiftData fetch.
protocol KnownHostStore: Sendable {

    /// Returns the stored trust policy for `(host, port)`, or `nil` if no row
    /// exists. Production conformances must perform an O(log n) fetch (a
    /// `FetchDescriptor` with a `#Predicate` on `(host, port)` and
    /// `fetchLimit = 1`); the load-all-and-filter form would not scale to a
    /// million-device fleet.
    func trust(forHost host: String, port: Int) async throws -> HostTrust?

    /// Writes a fresh `HostTrust.pinned` row on TOFU. Idempotent: implementations
    /// should treat a pre-existing matching row as a no-op rather than fail.
    func recordPinned(
        host: String,
        port: Int,
        fingerprintSHA256: String,
        algorithm: String
    ) async throws

    /// Updates `lastVerifiedAt` on the matching row after a successful
    /// fingerprint match. Missing rows are not an error.
    func touchLastVerified(forHost host: String, port: Int) async throws

    /// Replaces the stored pin for `(host, port)` with a fresh one
    /// under a new fingerprint and algorithm. Used by the mismatch-
    /// accept path: the operator has confirmed a legitimate key
    /// rotation and Pulse re-pins to the presented key. Implementations
    /// delete the existing row and insert a new one, restarting the
    /// `firstSeenAt` clock so the trust relationship starts fresh
    /// rather than carrying forward the old TOFU date (the operator
    /// has effectively re-TOFU'd this host).
    func replacePin(
        host: String,
        port: Int,
        fingerprintSHA256: String,
        algorithm: String
    ) async throws

    /// Removes the stored row for `(host, port)`. Used by the
    /// mismatch-forget path: the operator chooses to abandon the
    /// trust relationship; the next connection becomes a fresh TOFU.
    /// Missing rows are not an error (idempotent).
    func forget(host: String, port: Int) async throws

    /// Returns the `firstSeenAt` timestamp of the stored row for
    /// `(host, port)`, or `nil` if no row exists. Used by the
    /// mismatch sheet to surface "key first seen on ..." next to the
    /// stored fingerprint so the operator can recall when they
    /// originally TOFU'd this host.
    func firstSeenAt(forHost host: String, port: Int) async throws -> Date?
}

// MARK: - SwiftData-backed store

/// Production `KnownHostStore` over a SwiftData `ModelContainer`. The `@ModelActor`
/// macro generates the `init(modelContainer:)` and the `modelContext` accessor.
@ModelActor
actor SwiftDataKnownHostStore: KnownHostStore {

    func trust(forHost host: String, port: Int) async throws -> HostTrust? {
        var descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.trust
    }

    func recordPinned(
        host: String,
        port: Int,
        fingerprintSHA256: String,
        algorithm: String
    ) async throws {
        var descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        if try modelContext.fetch(descriptor).first != nil {
            // Caller raced with a previous TOFU. Treat as success; the existing
            // row's policy stands.
            return
        }
        let row = KnownHost(
            host: host,
            port: port,
            trust: .pinned(fingerprintSHA256: fingerprintSHA256, algorithm: algorithm)
        )
        modelContext.insert(row)
        try modelContext.save()
    }

    func touchLastVerified(forHost host: String, port: Int) async throws {
        var descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first else { return }
        row.lastVerifiedAt = .now
        try modelContext.save()
    }

    func replacePin(
        host: String,
        port: Int,
        fingerprintSHA256: String,
        algorithm: String
    ) async throws {
        var descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
        }
        let row = KnownHost(
            host: host,
            port: port,
            trust: .pinned(fingerprintSHA256: fingerprintSHA256, algorithm: algorithm)
        )
        modelContext.insert(row)
        try modelContext.save()
    }

    func forget(host: String, port: Int) async throws {
        var descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }

    func firstSeenAt(forHost host: String, port: Int) async throws -> Date? {
        var descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.firstSeenAt
    }
}

// MARK: - Errors

enum SSHHostKeyError: Error, CustomStringConvertible, Equatable {
    case fingerprintMismatch(recorded: String, presented: String)
    case caValidationFailed(reason: String)
    case explicitlyDistrusted(reason: String)
    case storeError(String)

    var description: String {
        switch self {
        case .fingerprintMismatch(let recorded, let presented):
            return "Host key mismatch: stored \(recorded), server presented \(presented)."
        case .caValidationFailed(let reason):
            return "CA validation failed: \(reason)."
        case .explicitlyDistrusted(let reason):
            return "Host is explicitly distrusted: \(reason)."
        case .storeError(let reason):
            return "Host trust store error: \(reason)."
        }
    }
}

// MARK: - Decision (pure, for tests)

/// Outcome of evaluating a presented server host key against a stored policy.
enum HostKeyDecision: Equatable {
    /// No stored row: TOFU-pin the presented key and accept.
    case pinAndAccept
    /// Stored `.pinned` matches the presented key: accept and touch.
    case acceptKnownPinned
    /// Stored `.pinned` differs from the presented key. The delegate
    /// consults its `HostKeyMismatchDecisionProvider` (if set) to
    /// surface the operator decision; absent a provider the path
    /// rejects unconditionally. The `recordedAlgorithm` rides
    /// alongside `recordedFingerprint` because the operator sheet
    /// shows both for the stored row, and the algorithm is in scope
    /// from `HostTrust.pinned` at evaluation time.
    case rejectMismatch(recordedFingerprint: String, recordedAlgorithm: String)
    /// Stored `.trustedCA` matches the presented cert chain: accept.
    case acceptCA(caFingerprint: String, principalPattern: String)
    /// Stored `.trustedCA` rejects the presented key for the reason given.
    case rejectCA(reason: String)
    /// Stored `.explicitlyDistrusted`: reject with recorded reason.
    case rejectDistrusted(reason: String)
}

// MARK: - Host-key mismatch decision (operator-chosen)

/// Operator's response when a stored `.pinned` host key differs from the
/// fingerprint the server is now presenting. ADR §5 defines three actions
/// for this surface. The delegate (next change) maps each to a
/// `KnownHostStore` mutation, a NIOSSH validation result, and an audit
/// event under `ssh.session`:
///
/// | Case | `KnownHost` write | NIOSSH | Audit |
/// |---|---|---|---|
/// | `.accept(fingerprint, algorithm)` | replace pin | `.success` | `host.mismatch.accepted` |
/// | `.reject` | none | `.failure(.fingerprintMismatch)` | `host.mismatch.rejected` |
/// | `.forget` | delete row | `.failure(.fingerprintMismatch)` | `host.mismatch.forgotten` |
///
/// `.accept` carries the *new* fingerprint and algorithm so the delegate
/// can write the fresh pin without re-deriving them; both values are
/// already in scope at the call site (the host-key validation path
/// computes them before consulting the operator).
///
/// `.reject` carries an optional `reason` so the audit emission can
/// distinguish operator-chosen rejection (`reason = nil`) from a
/// system-driven rejection such as a decision-timeout
/// (`reason = "decision_timeout"`). The provider is the right layer
/// to set this metadata; the delegate is consumer-agnostic about
/// why the rejection happened and just routes the audit field.
enum HostKeyMismatchDecision: Equatable, Sendable {
    case accept(fingerprintSHA256: String, algorithm: String)
    case reject(reason: String? = nil)
    case forget
}

// MARK: - Mismatch decision provider

/// Protocol the delegate consults when a stored `.pinned` host key
/// differs from the fingerprint the server is now presenting. A
/// connecting UI implements this to surface the
/// `HostKeyMismatchSheet` and await the operator's decision. Headless
/// or background callers leave the provider `nil` on the delegate
/// and inherit today's reject-unconditionally semantics.
///
/// The provider owns the decision timeout. The recommended bound is
/// 90 seconds: long enough for an operator to read two fingerprints
/// and decide, short enough to bound a walked-away operator's
/// half-open channel. The `HostKeyMismatchCoordinator` shipping
/// alongside the SwiftUI terminal enforces this bound; alternative
/// providers (CLI, headless scripts) are free to pick their own
/// bound but should never block indefinitely.
///
/// On timeout the provider returns `.reject(reason: "decision_timeout")`.
/// The delegate emits the matching `host.mismatch.rejected` audit
/// event with the reason field populated; SIEM rules can match on
/// the reason to surface walked-away-operator events distinct from
/// deliberate rejections.
protocol HostKeyMismatchDecisionProvider: Sendable {
    func decide(
        host: String,
        port: Int,
        recordedFingerprint: String,
        recordedAlgorithm: String,
        recordedFirstSeenAt: Date,
        newFingerprint: String,
        newAlgorithm: String
    ) async -> HostKeyMismatchDecision
}

// MARK: - Delegate

/// `NIOSSHClientServerAuthenticationDelegate` that consults a `KnownHostStore`
/// to decide whether to accept the server's presented host key.
///
/// Behaviour matches ADR 0001 §5. TOFU pins the first key observed; subsequent
/// mismatches are rejected unconditionally in the current build (no
/// UI sheet yet). Trusted-CA rows are honoured when the presented
/// host key is a `NIOSSHCertifiedPublicKey` whose signing key fingerprint
/// matches the stored CA fingerprint and whose validPrincipals (or empty,
/// per spec) cover the host being connected to.
final class SSHHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {

    private let host: String
    private let port: Int
    private let store: any KnownHostStore
    private let now: @Sendable () -> Date
    private let mismatchDecisionProvider: (any HostKeyMismatchDecisionProvider)?
    private let logger = Logger(subsystem: "pulse", category: "ssh.session")

    init(
        host: String,
        port: Int,
        store: any KnownHostStore,
        mismatchDecisionProvider: (any HostKeyMismatchDecisionProvider)? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.host = host
        self.port = port
        self.store = store
        self.mismatchDecisionProvider = mismatchDecisionProvider
        self.now = now
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let presentedFingerprint = SSHCertificateManager.opensshSHA256Fingerprint(of: hostKey)
        let presentedAlgorithm = Self.algorithmName(of: hostKey)
        let host = self.host
        let port = self.port
        let store = self.store
        let logger = self.logger
        let now = self.now

        // The store lookup is `async throws`, so it has to run off the
        // EventLoop. Hop to the Swift cooperative pool with `Task { ... }`,
        // complete the work, then fill the `validationCompletePromise` —
        // NIOCore's promise machinery handles the back-hop to the channel's
        // EventLoop internally. Do not "optimise" by inlining the lookup onto
        // the calling thread: the SwiftData fetch can block, and blocking the
        // EventLoop stalls every other channel sharing it.
        Task {
            let decision: HostKeyDecision
            do {
                let recorded = try await store.trust(forHost: host, port: port)
                decision = Self.evaluate(
                    recordedTrust: recorded,
                    hostKey: hostKey,
                    presentedFingerprint: presentedFingerprint,
                    presentedAlgorithm: presentedAlgorithm,
                    host: host,
                    at: now()
                )
            } catch {
                logger.error(
                    "host trust store failed for \(host, privacy: .public):\(port): \(String(describing: error))"
                )
                validationCompletePromise.fail(SSHHostKeyError.storeError(String(describing: error)))
                return
            }

            switch decision {
            case .pinAndAccept:
                do {
                    try await store.recordPinned(
                        host: host,
                        port: port,
                        fingerprintSHA256: presentedFingerprint,
                        algorithm: presentedAlgorithm
                    )
                } catch {
                    logger.error(
                        "host.pinned write failed for \(host, privacy: .public):\(port): \(String(describing: error))"
                    )
                    validationCompletePromise.fail(SSHHostKeyError.storeError(String(describing: error)))
                    return
                }
                logger.info(
                    "host.pinned host=\(host, privacy: .public) port=\(port) fp=\(presentedFingerprint, privacy: .public) alg=\(presentedAlgorithm, privacy: .public)"
                )
                validationCompletePromise.succeed(())

            case .acceptKnownPinned:
                try? await store.touchLastVerified(forHost: host, port: port)
                validationCompletePromise.succeed(())

            case .rejectMismatch(let recordedFingerprint, let recordedAlgorithm):
                await self.handleMismatch(
                    recordedFingerprint: recordedFingerprint,
                    recordedAlgorithm: recordedAlgorithm,
                    presentedFingerprint: presentedFingerprint,
                    presentedAlgorithm: presentedAlgorithm,
                    host: host,
                    port: port,
                    store: store,
                    logger: logger,
                    validationCompletePromise: validationCompletePromise
                )

            case .acceptCA(let caFingerprint, let principalPattern):
                logger.info(
                    "host.ca-accepted host=\(host, privacy: .public) port=\(port) ca=\(caFingerprint, privacy: .public) pattern=\(principalPattern, privacy: .public)"
                )
                validationCompletePromise.succeed(())

            case .rejectCA(let reason):
                logger.warning(
                    "host.ca-rejected host=\(host, privacy: .public) port=\(port) reason=\(reason, privacy: .public)"
                )
                validationCompletePromise.fail(SSHHostKeyError.caValidationFailed(reason: reason))

            case .rejectDistrusted(let reason):
                logger.warning(
                    "host.mismatch host=\(host, privacy: .public) port=\(port) reason=\(reason, privacy: .public)"
                )
                validationCompletePromise.fail(SSHHostKeyError.explicitlyDistrusted(reason: reason))
            }
        }
    }

    // MARK: - Mismatch handling

    /// Routes a `.rejectMismatch` outcome through the optional
    /// `HostKeyMismatchDecisionProvider`. Absent a provider, today's
    /// reject-unconditionally semantics apply: emit `host.mismatch`
    /// and fail the validation promise with `.fingerprintMismatch`.
    ///
    /// With a provider attached, the operator picks one of three
    /// actions; the delegate routes each to a `KnownHostStore`
    /// mutation, a NIOSSH validation result, and an audit emission
    /// under `ssh.session`:
    /// `host.mismatch.accepted` / `host.mismatch.rejected` /
    /// `host.mismatch.forgotten`. The provider owns the decision
    /// timeout; on timeout it returns `.reject(reason: "decision_timeout")`
    /// and the delegate stamps the audit event with that reason so
    /// SIEM rules can distinguish walked-away-operator from
    /// deliberate rejections.
    private func handleMismatch(
        recordedFingerprint: String,
        recordedAlgorithm: String,
        presentedFingerprint: String,
        presentedAlgorithm: String,
        host: String,
        port: Int,
        store: any KnownHostStore,
        logger: Logger,
        validationCompletePromise: EventLoopPromise<Void>
    ) async {
        guard let provider = self.mismatchDecisionProvider else {
            // No UI on this connection (background flows, debug menu
            // pre-refactor, tests with a stub delegate). Reject
            // unconditionally with the legacy emission shape.
            logger.warning(
                "host.mismatch host=\(host, privacy: .public) port=\(port) recorded=\(recordedFingerprint, privacy: .public) presented=\(presentedFingerprint, privacy: .public)"
            )
            validationCompletePromise.fail(
                SSHHostKeyError.fingerprintMismatch(
                    recorded: recordedFingerprint,
                    presented: presentedFingerprint
                )
            )
            return
        }

        // The provider's sheet needs the original TOFU timestamp to
        // help the operator recall when this host was trusted. A
        // missing row at this point would be unusual (we just read
        // .pinned from the same store) but we tolerate the absence
        // by falling back to .distantPast — the sheet renders a
        // sentinel rather than crashing.
        let firstSeenAt: Date
        do {
            firstSeenAt = try await store.firstSeenAt(forHost: host, port: port) ?? .distantPast
        } catch {
            logger.error(
                "host trust store firstSeenAt lookup failed for \(host, privacy: .public):\(port): \(String(describing: error))"
            )
            firstSeenAt = .distantPast
        }

        let decision = await provider.decide(
            host: host,
            port: port,
            recordedFingerprint: recordedFingerprint,
            recordedAlgorithm: recordedAlgorithm,
            recordedFirstSeenAt: firstSeenAt,
            newFingerprint: presentedFingerprint,
            newAlgorithm: presentedAlgorithm
        )

        switch decision {
        case .accept(let newFingerprint, let newAlgorithm):
            // Record operator intent before attempting the trust-store
            // commit. A SIEM rule keyed on `host.mismatch.accepted`
            // matches this line whether or not the commit succeeds; the
            // commit-failure path emits a distinct `commit_failed`
            // sub-event so the forensic record is complete. Naming
            // convention is pinned in ADR §7.
            logger.warning(
                "host.mismatch.accepted host=\(host, privacy: .public) port=\(port) previousFingerprintSHA256=\(recordedFingerprint, privacy: .public) newFingerprintSHA256=\(newFingerprint, privacy: .public) newAlgorithm=\(newAlgorithm, privacy: .public)"
            )
            do {
                try await store.replacePin(
                    host: host,
                    port: port,
                    fingerprintSHA256: newFingerprint,
                    algorithm: newAlgorithm
                )
            } catch {
                logger.error(
                    "host.mismatch.accepted.commit_failed host=\(host, privacy: .public) port=\(port) reason=\(String(describing: error), privacy: .public)"
                )
                validationCompletePromise.fail(SSHHostKeyError.storeError(String(describing: error)))
                return
            }
            validationCompletePromise.succeed(())

        case .reject(let reason):
            if let reason {
                logger.warning(
                    "host.mismatch.rejected host=\(host, privacy: .public) port=\(port) recorded=\(recordedFingerprint, privacy: .public) presented=\(presentedFingerprint, privacy: .public) reason=\(reason, privacy: .public)"
                )
            } else {
                logger.warning(
                    "host.mismatch.rejected host=\(host, privacy: .public) port=\(port) recorded=\(recordedFingerprint, privacy: .public) presented=\(presentedFingerprint, privacy: .public)"
                )
            }
            validationCompletePromise.fail(
                SSHHostKeyError.fingerprintMismatch(
                    recorded: recordedFingerprint,
                    presented: presentedFingerprint
                )
            )

        case .forget:
            // Same intent-before-commit ordering as .accept above.
            logger.warning(
                "host.mismatch.forgotten host=\(host, privacy: .public) port=\(port) previousFingerprintSHA256=\(recordedFingerprint, privacy: .public)"
            )
            do {
                try await store.forget(host: host, port: port)
            } catch {
                logger.error(
                    "host.mismatch.forgotten.commit_failed host=\(host, privacy: .public) port=\(port) reason=\(String(describing: error), privacy: .public)"
                )
                validationCompletePromise.fail(SSHHostKeyError.storeError(String(describing: error)))
                return
            }
            validationCompletePromise.fail(
                SSHHostKeyError.fingerprintMismatch(
                    recorded: recordedFingerprint,
                    presented: presentedFingerprint
                )
            )
        }
    }

    // MARK: - Pure decision logic

    /// Pure function that decides whether to accept a presented host key given
    /// the stored trust policy. Factored out of `validateHostKey` so the
    /// decision table can be unit-tested with mock inputs without needing a
    /// SwiftData container or an `EventLoopPromise`.
    static func evaluate(
        recordedTrust: HostTrust?,
        hostKey: NIOSSHPublicKey,
        presentedFingerprint: String,
        presentedAlgorithm: String,
        host: String,
        at now: Date
    ) -> HostKeyDecision {
        guard let recorded = recordedTrust else {
            return .pinAndAccept
        }

        switch recorded {
        case .pinned(let storedFingerprint, let storedAlgorithm):
            return storedFingerprint == presentedFingerprint
                ? .acceptKnownPinned
                : .rejectMismatch(
                    recordedFingerprint: storedFingerprint,
                    recordedAlgorithm: storedAlgorithm
                )

        case .trustedCA(let caFingerprint, let principalPattern):
            return evaluateCA(
                hostKey: hostKey,
                expectedCAFingerprint: caFingerprint,
                principalPattern: principalPattern,
                host: host,
                at: now
            )

        case .explicitlyDistrusted(let reason, _):
            return .rejectDistrusted(reason: reason)
        }
    }

    private static func evaluateCA(
        hostKey: NIOSSHPublicKey,
        expectedCAFingerprint: String,
        principalPattern: String,
        host: String,
        at now: Date
    ) -> HostKeyDecision {
        guard let cert = NIOSSHCertifiedPublicKey(hostKey) else {
            return .rejectCA(reason: "server presented a plain public key, not a CA-attested cert")
        }
        let actualCAFingerprint = SSHCertificateManager.opensshSHA256Fingerprint(of: cert.signatureKey)
        guard actualCAFingerprint == expectedCAFingerprint else {
            return .rejectCA(
                reason: "cert is signed by \(actualCAFingerprint); trusted CA is \(expectedCAFingerprint)"
            )
        }
        let nowSeconds = UInt64(max(0, now.timeIntervalSince1970))
        guard cert.validAfter <= nowSeconds && nowSeconds <= cert.validBefore else {
            return .rejectCA(reason: "cert is outside its validity window")
        }
        if !cert.validPrincipals.isEmpty
            && !matches(host: host, anyOf: cert.validPrincipals, pattern: principalPattern) {
            return .rejectCA(
                reason: "cert principals \(cert.validPrincipals) don't cover host \(host) under pattern \(principalPattern)"
            )
        }
        return .acceptCA(caFingerprint: expectedCAFingerprint, principalPattern: principalPattern)
    }

    /// Minimal pattern check for v1. The principalPattern is an OpenSSH-style
    /// glob (e.g., `*.internal.example`) or a literal hostname. Either the
    /// pattern itself or one of the cert's `validPrincipals` must match the
    /// host. v1 supports literal-equality and trailing-`*` wildcard; richer
    /// patterns can land alongside the future CA-import UI.
    private static func matches(host: String, anyOf principals: [String], pattern: String) -> Bool {
        if principals.contains(host) { return true }
        if Self.glob(pattern, matches: host) { return true }
        return principals.contains(where: { Self.glob($0, matches: host) })
    }

    private static func glob(_ pattern: String, matches host: String) -> Bool {
        if pattern == host { return true }
        if pattern.hasSuffix("*") {
            let prefix = pattern.dropLast()
            return host.hasPrefix(prefix)
        }
        return false
    }

    /// Extracts the algorithm identifier from the OpenSSH text form. Used as
    /// the `algorithm` field stored on TOFU pins so an operator inspecting a
    /// `KnownHost` row can tell at a glance whether the server is presenting
    /// ed25519, ecdsa-sha2-nistp256, ssh-rsa, etc.
    private static func algorithmName(of key: NIOSSHPublicKey) -> String {
        let text = String(openSSHPublicKey: key)
        return text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "unknown"
    }
}
