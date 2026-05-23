//
//  SSHCertificateManager.swift
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

/// Reads metadata out of an SSH certificate that has been signed by a CA over an
/// `SSHCredential`'s public key.
///
/// **Slice 1 status — schema reservation only.** This type defines the metadata shape
/// the rest of Pulse will refer to (principals, validity window, CA fingerprint, key
/// id), but the real parser is built in Slice 3 once swift-nio-ssh is linked. Slice 1
/// keeps the `certificate: Data?` field on `SSHCredential` so v2's certificate-aware
/// flows do not require a SwiftData migration.
///
/// Per ADR 0001 §3, certificates are first-class from v1 — meaning the data model
/// holds them. The UI surface (FreeIPA enrolment, expiry display, automatic
/// re-enrolment) lands in v2 against this stable schema.
enum SSHCertificateManager {

    /// Algorithm-agnostic projection of an SSH certificate's interesting bits.
    /// Mirrors the fields swift-nio-ssh exposes on `NIOSSHCertifiedPublicKey`.
    struct CertificateMetadata: Equatable, Sendable {
        /// Free-form identifier the CA stamps onto the cert. Often a username or
        /// hostname for human-readability in audit logs.
        let keyId: String

        /// Usernames or hostnames this certificate may impersonate. Empty means
        /// "no restriction" (rare in production; flag loudly in the UI when seen).
        let principals: [String]

        /// Earliest time the certificate is considered valid.
        let validAfter: Date

        /// Latest time the certificate is considered valid.
        let validBefore: Date

        /// SHA-256 fingerprint of the signing CA's public key. The same fingerprint
        /// that appears in `HostTrust.trustedCA` records so we can match user
        /// certificates to the trusted-CA policy.
        let caFingerprintSHA256: String
    }

    enum CertificateError: Error, CustomStringConvertible {
        /// The parser is intentionally absent until Slice 3 wires up swift-nio-ssh.
        case parserNotAvailableYet

        /// The supplied bytes don't decode as a recognised SSH certificate format.
        case malformedCertificate

        var description: String {
            switch self {
            case .parserNotAvailableYet:
                return "SSH certificate parsing lands in Slice 3 (swift-nio-ssh integration)."
            case .malformedCertificate:
                return "The supplied bytes are not a valid SSH certificate blob."
            }
        }
    }

    /// Returns parsed metadata for a serialised certificate blob.
    ///
    /// **Slice 1 — throws `.parserNotAvailableYet`.** The body is filled in Slice 3
    /// where `NIOSSHCertifiedPublicKey` is available to decode the wire format.
    static func metadata(for serialised: Data) throws -> CertificateMetadata {
        _ = serialised
        throw CertificateError.parserNotAvailableYet
    }

    /// Returns true when the certificate's validity window covers `date`.
    ///
    /// Slice 1 callers (none in practice — no UI surface yet) get `false` so the
    /// schema-reservation field on `SSHCredential.certificateExpiresAt` is never
    /// surprisingly treated as live.
    static func isValid(_ metadata: CertificateMetadata, at date: Date = .now) -> Bool {
        date >= metadata.validAfter && date <= metadata.validBefore
    }
}
