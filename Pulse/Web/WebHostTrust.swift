//
//  WebHostTrust.swift
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

// MARK: - Web Host Trust

/// Persistent record of TLS trust for a single device-web `host:port` endpoint.
///
/// Created when an operator acknowledges an otherwise-untrusted certificate
/// (trust-on-first-use) and updated when a certificate rotates. It reuses the
/// `HostTrust` enum the SSH host-key subsystem already defines (`KnownHost.swift`):
/// a `.pinned` case carries the certificate SHA-256 fingerprint and key
/// algorithm, exactly as the SSH side carries a host-key fingerprint.
///
/// This is a separate model from `KnownHost` on purpose. A device's TLS-cert
/// trust and its SSH host-key trust are different facts about different
/// protocols on different ports; keeping them in separate tables lets an
/// operator forget one without disturbing the other, and stops a port-22 SSH
/// pin from ever being consulted for an HTTPS connection (or the reverse). See
/// ADR 0001 §5 (polymorphic host trust) and §9 (the Device Web window).
@Model
final class WebHostTrust {
    // Composite index on (host, port): the trust store's only query is a
    // FetchDescriptor predicate on host + port, so this keeps that lookup
    // O(log n) at fleet scale (see WebHostTrustStore), honouring the store's
    // own scaling contract rather than leaving it to a full-table scan.
    #Index<WebHostTrust>([\.host, \.port])

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
