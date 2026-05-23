//
//  SSHCredential.swift
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

// MARK: - Credential Tier

/// Where the private key material lives and how it's exercised.
///
/// The tier determines the signing path; everything else about the credential is identical
/// across tiers. There is deliberately no `.password` case (see ADR 0001 §2).
enum SSHCredentialTier: String, Codable, Sendable {
    /// Private key resides in the Secure Enclave. Non-exportable. Every signature is
    /// gated by `kSecAccessControlBiometryCurrentSet` (or device passcode). Default for new
    /// credentials. ECDSA P-256 (the only algorithm the SE supports).
    case secureEnclave

    /// Private key is portable: stored as PEM in the Keychain. Algorithm can be Ed25519,
    /// ECDSA, or RSA. Surfaced as "Legacy" in the UI per ADR 0001 §1.
    case portable
}

// MARK: - SSH Credential

/// A reusable SSH identity. Carries the public material and the metadata; the private
/// material lives in Keychain (portable tier) or the Secure Enclave (default tier),
/// keyed by `id`.
///
/// Deliberately omits:
///
/// - `username`: usernames are per-connection (`Device.defaultUsername` or a per-session
///   override), not per-credential. One key authorises many usernames. See ADR 0001 §4.
/// - `password` / `authType`: password authentication is not supported. The tier is the
///   only discriminator. See ADR 0001 §2.
///
/// The optional `certificate` blob attaches a CA-signed `NIOSSHCertifiedPublicKey` to
/// the credential without altering the underlying public key. Carried on the model so
/// enrolment workflows (FreeIPA, smallstep, Vault) can populate it without a SwiftData
/// migration.
@Model
final class SSHCredential {
    @Attribute(.unique) var id: UUID
    var label: String
    var tier: SSHCredentialTier
    /// OpenSSH wire-format public key. Exportable on both tiers (this is the public half).
    var publicKey: Data
    /// Serialised `NIOSSHCertifiedPublicKey` when a CA has signed `publicKey`. Parsed
    /// by `SSHCertificateManager` for the credential editor to display expiry and
    /// principals.
    var certificate: Data?
    /// Mirrors the certificate's validity window for cheap UI display without re-parsing.
    var certificateExpiresAt: Date?
    /// When true, session byte streams using this credential are recorded under
    /// `~/Library/Application Support/Pulse/Sessions/...`. AES-GCM encrypted with
    /// SE-wrapped per-session keys. Off by default; opt-in per ADR 0001 §6.
    var recordSessions: Bool
    var lastUsedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        tier: SSHCredentialTier,
        publicKey: Data,
        certificate: Data? = nil,
        certificateExpiresAt: Date? = nil,
        recordSessions: Bool = false,
        lastUsedAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.label = label
        self.tier = tier
        self.publicKey = publicKey
        self.certificate = certificate
        self.certificateExpiresAt = certificateExpiresAt
        self.recordSessions = recordSessions
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }
}
