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
/// Defines the metadata shape (`keyId`, `principals`, validity window, CA fingerprint)
/// that the rest of Pulse refers to. The actual decode pipeline depends on
/// `NIOSSHCertifiedPublicKey` from swift-nio-ssh; while that module isn't linked,
/// `metadata(for:)` throws `.parserNotAvailableYet` and the credential editor falls
/// back to displaying the raw blob length.
///
/// Per ADR 0001 §3, certificates are first-class on the data model so enrolment flows
/// (FreeIPA, smallstep, Vault) can populate `SSHCredential.certificate` without a
/// schema migration.
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
        /// Thrown when `metadata(for:)` is called and the swift-nio-ssh bridge isn't
        /// linked into the current build.
        case parserNotAvailableYet

        /// The supplied bytes don't decode as a recognised SSH certificate format.
        case malformedCertificate

        var description: String {
            switch self {
            case .parserNotAvailableYet:
                return "SSH certificate parsing requires the swift-nio-ssh signer module to be linked."
            case .malformedCertificate:
                return "The supplied bytes are not a valid SSH certificate blob."
            }
        }
    }

    /// Returns parsed metadata for a serialised certificate blob.
    ///
    /// Throws `.parserNotAvailableYet` until `NIOSSHCertifiedPublicKey` is available
    /// to decode the wire format. The signer module supplies that integration.
    static func metadata(for serialised: Data) throws -> CertificateMetadata {
        _ = serialised
        throw CertificateError.parserNotAvailableYet
    }

    /// Returns true when the certificate's validity window covers `date`.
    static func isValid(_ metadata: CertificateMetadata, at date: Date = .now) -> Bool {
        date >= metadata.validAfter && date <= metadata.validBefore
    }
}
