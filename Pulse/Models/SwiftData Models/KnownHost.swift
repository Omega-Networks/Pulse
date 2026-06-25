//
//  KnownHost.swift
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
import SwiftData

// MARK: - Host Trust

/// How Pulse decides whether to accept a server host key.
///
/// Polymorphic so adding CA-attested trust is a code change against a stable schema
/// rather than a SwiftData migration that could be skipped or fail partially. See
/// ADR 0001 §5.
enum HostTrust: Codable, Hashable, Sendable {
    /// TOFU pin: the fingerprint observed on first connection is the contract.
    case pinned(fingerprintSHA256: String, algorithm: String)

    /// CA-attested: the host key is signed by a recognised CA whose fingerprint and
    /// principal pattern are stored here.
    case trustedCA(caFingerprintSHA256: String, principalPattern: String)

    /// Hard refusal: never accept this host, with the reason recorded.
    case explicitlyDistrusted(reason: String, recordedAt: Date)
}

// MARK: - Known Host

/// Persistent record of host-key trust for a single `host:port` endpoint.
///
/// Created on first successful SSH connection (TOFU) and updated when keys rotate.
/// `HostTrust` carries the policy that the host-key delegate consults on every
/// subsequent connection.
@Model
final class KnownHost {
    @Attribute(.unique) var id: UUID
    var host: String
    var port: Int
    var trust: HostTrust
    var firstSeenAt: Date
    var lastVerifiedAt: Date

    init(
        id: UUID = UUID(),
        host: String,
        port: Int,
        trust: HostTrust,
        firstSeenAt: Date = .now,
        lastVerifiedAt: Date = .now
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.trust = trust
        self.firstSeenAt = firstSeenAt
        self.lastVerifiedAt = lastVerifiedAt
    }
}
