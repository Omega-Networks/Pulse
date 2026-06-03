//
//  WebHostTrustStore.swift
//  Pulse
//
//  Copyright © 2025-present Omega Networks Limited.
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
import SwiftData

// MARK: - Web host trust store

/// Persistence seam for device-web TLS trust, mirroring `KnownHostStore` for
/// SSH host keys. All methods are `async throws` so the navigation decider can
/// hop to the store's isolation for the SwiftData fetch.
protocol WebHostTrustStore: Sendable {

    /// Stored trust policy for `(host, port)`, or `nil` if no row exists.
    /// Conformances must perform an O(log n) fetch (a `FetchDescriptor` with a
    /// `#Predicate` on `(host, port)` and `fetchLimit = 1`) so the store scales
    /// to a fleet-sized trust table.
    func trust(forHost host: String, port: Int) async throws -> HostTrust?

    /// Writes a fresh `.pinned` row on first-sight acceptance. Idempotent: a
    /// pre-existing matching row is a no-op rather than an error.
    func recordPinned(host: String, port: Int, fingerprintSHA256: String, algorithm: String) async throws

    /// Updates `lastVerifiedAt` after a successful match. Missing rows are not
    /// an error.
    func touchLastVerified(forHost host: String, port: Int) async throws

    /// Replaces the stored pin with a fresh one (operator accepted a cert
    /// rotation). Restarts the `firstSeenAt` clock, matching the SSH
    /// mismatch-accept semantics.
    func replacePin(host: String, port: Int, fingerprintSHA256: String, algorithm: String) async throws

    /// Removes the stored row. Next connection becomes a fresh first-sight.
    /// Missing rows are not an error (idempotent).
    func forget(host: String, port: Int) async throws

    /// `firstSeenAt` of the stored row, or `nil`. Surfaced in the mismatch
    /// sheet so the operator can recall when they originally trusted the host.
    func firstSeenAt(forHost host: String, port: Int) async throws -> Date?
}

// MARK: - SwiftData-backed store

/// Production `WebHostTrustStore` over a SwiftData `ModelContainer`. The
/// `@ModelActor` macro generates `init(modelContainer:)` and the `modelContext`
/// accessor. Mirrors `SwiftDataKnownHostStore`.
@ModelActor
actor SwiftDataWebHostTrustStore: WebHostTrustStore {

    func trust(forHost host: String, port: Int) async throws -> HostTrust? {
        var descriptor = FetchDescriptor<WebHostTrust>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.trust
    }

    func recordPinned(host: String, port: Int, fingerprintSHA256: String, algorithm: String) async throws {
        var descriptor = FetchDescriptor<WebHostTrust>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        if try modelContext.fetch(descriptor).first != nil {
            // Raced with a previous first-sight accept. The existing row stands.
            return
        }
        let row = WebHostTrust(
            host: host,
            port: port,
            trust: .pinned(fingerprintSHA256: fingerprintSHA256, algorithm: algorithm)
        )
        modelContext.insert(row)
        try modelContext.save()
    }

    func touchLastVerified(forHost host: String, port: Int) async throws {
        var descriptor = FetchDescriptor<WebHostTrust>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first else { return }
        row.lastVerifiedAt = .now
        try modelContext.save()
    }

    func replacePin(host: String, port: Int, fingerprintSHA256: String, algorithm: String) async throws {
        var descriptor = FetchDescriptor<WebHostTrust>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
        }
        let row = WebHostTrust(
            host: host,
            port: port,
            trust: .pinned(fingerprintSHA256: fingerprintSHA256, algorithm: algorithm)
        )
        modelContext.insert(row)
        try modelContext.save()
    }

    func forget(host: String, port: Int) async throws {
        var descriptor = FetchDescriptor<WebHostTrust>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }

    func firstSeenAt(forHost host: String, port: Int) async throws -> Date? {
        var descriptor = FetchDescriptor<WebHostTrust>(
            predicate: #Predicate { $0.host == host && $0.port == port }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.firstSeenAt
    }
}

// MARK: - Trust decision (pure, for tests)

/// Outcome of evaluating a presented server certificate against the system
/// trust store and any recorded `HostTrust`. The navigation decider
/// maps each case to a `URLSession.AuthChallengeDisposition` and a
/// `WebHostTrustStore` mutation.
enum WebTrustDecision: Equatable {
    /// The certificate chains to a trusted root: load silently, pin nothing.
    case acceptSystemTrusted
    /// A recorded `.pinned` fingerprint matches the presented one: load
    /// silently, touch `lastVerifiedAt`.
    case acceptPinned
    /// Untrusted and unrecorded: prompt the operator (first-sight TOFU). On
    /// accept, pin the presented fingerprint.
    case promptFirstSight
    /// Untrusted and a recorded `.pinned` fingerprint differs: prompt with the
    /// stored-versus-presented comparison.
    case promptMismatch(recordedFingerprint: String, recordedAlgorithm: String)
    /// The host is explicitly distrusted: reject with the recorded reason.
    case rejectDistrusted(reason: String)
}

/// Pure trust-evaluation logic, split out so it is unit-testable without a
/// `SecTrust`, a network, or a SwiftData container. The caller (the navigation
/// decider) computes `systemTrusted` via `SecTrustEvaluateWithError` and the
/// presented fingerprint via `TLSCertificateInspector`, then routes on the
/// returned decision.
enum WebHostTrustEvaluator {

    /// Evaluate the presented certificate.
    ///
    /// Order matters: an explicit distrust is an operator hard-no and wins over
    /// everything. Otherwise a matching pin loads silently; a changed pin always
    /// prompts (the operator pinned a specific certificate, so a change is worth
    /// surfacing even if the new certificate now chains to a trusted root); and
    /// for an unrecorded host (or the schema-reserved `.trustedCA` case, not yet
    /// implemented for web) a system-trusted certificate loads silently while an
    /// untrusted one prompts on first sight.
    static func evaluate(
        systemTrusted: Bool,
        recorded: HostTrust?,
        presentedFingerprint: String
    ) -> WebTrustDecision {
        switch recorded {
        case .explicitlyDistrusted(let reason, _):
            return .rejectDistrusted(reason: reason)
        case .pinned(let fingerprint, let algorithm):
            return fingerprint == presentedFingerprint
                ? .acceptPinned
                : .promptMismatch(recordedFingerprint: fingerprint, recordedAlgorithm: algorithm)
        case .trustedCA:
            return systemTrusted ? .acceptSystemTrusted : .promptFirstSight
        case nil:
            return systemTrusted ? .acceptSystemTrusted : .promptFirstSight
        }
    }
}
