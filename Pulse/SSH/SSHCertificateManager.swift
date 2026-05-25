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
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Crypto
import Foundation
import NIOSSH

/// Reads metadata out of an SSH certificate signed by a CA over an `SSHCredential`'s
/// public key.
///
/// `SSHCredential.certificate` carries the textual OpenSSH cert form as UTF-8 bytes
/// (the same single-line representation `ssh-keygen` writes to a `*-cert.pub` file:
/// `algorithm-id BASE64-cert-blob comment`). Storing the textual form keeps round
/// trips to `ssh-keygen`, FreeIPA, smallstep, and Vault byte-identical, and avoids
/// having to spec a binary wire layout in our schema.
///
/// Per ADR 0001 §3, certificates are first-class on the data model so enrolment flows
/// can populate `SSHCredential.certificate` without a schema migration.
enum SSHCertificateManager {

    /// Algorithm-agnostic projection of an SSH certificate's interesting fields.
    /// Sourced from `NIOSSHCertifiedPublicKey`; the `caFingerprintSHA256` is the same
    /// fingerprint `ssh-keygen -l -E sha256` prints for the signing key, which is also
    /// what `HostTrust.trustedCA(caFingerprintSHA256:...)` rows compare against.
    struct CertificateMetadata: Equatable, Sendable {
        let keyID: String
        let principals: [String]
        let validAfter: Date
        let validBefore: Date
        let caFingerprintSHA256: String
        let serial: UInt64
    }

    enum CertificateError: Error, CustomStringConvertible, Equatable {
        case malformedCertificate(reason: String)
        case notACertifiedKey

        var description: String {
            switch self {
            case .malformedCertificate(let reason):
                return "The supplied bytes are not a valid SSH certificate blob: \(reason)"
            case .notACertifiedKey:
                return "The supplied OpenSSH key is a plain public key, not a certificate."
            }
        }
    }

    /// Parses the textual OpenSSH cert form stored in `SSHCredential.certificate`.
    static func metadata(for serialised: Data) throws -> CertificateMetadata {
        guard let text = String(data: serialised, encoding: .utf8) else {
            throw CertificateError.malformedCertificate(reason: "blob is not valid UTF-8")
        }
        let publicKey: NIOSSHPublicKey
        do {
            publicKey = try NIOSSHPublicKey(openSSHPublicKey: text)
        } catch {
            throw CertificateError.malformedCertificate(reason: String(describing: error))
        }
        guard let cert = NIOSSHCertifiedPublicKey(publicKey) else {
            throw CertificateError.notACertifiedKey
        }
        return CertificateMetadata(
            keyID: cert.keyID,
            principals: cert.validPrincipals,
            validAfter: Date(timeIntervalSince1970: TimeInterval(cert.validAfter)),
            validBefore: Date(timeIntervalSince1970: TimeInterval(cert.validBefore)),
            caFingerprintSHA256: opensshSHA256Fingerprint(of: cert.signatureKey),
            serial: cert.serial
        )
    }

    /// Encodes a `NIOSSHCertifiedPublicKey` back into the textual OpenSSH cert form
    /// that `SSHCredential.certificate` carries. Round-trips with `metadata(for:)`.
    static func serialise(_ cert: NIOSSHCertifiedPublicKey) -> Data {
        Data(String(openSSHPublicKey: NIOSSHPublicKey(cert)).utf8)
    }

    /// True when `date` falls inside the certificate's validity window.
    /// `SSHAuthDelegate` calls this immediately before presenting a cert and falls
    /// back to the bare public key on `false`, per ADR §7 (cert.expired emission).
    static func isValid(_ metadata: CertificateMetadata, at date: Date = .now) -> Bool {
        date >= metadata.validAfter && date <= metadata.validBefore
    }

    /// SHA-256 over the OpenSSH wire-format public key, rendered as
    /// `SHA256:<base64-no-padding>`. Matches `ssh-keygen -l -E sha256` output and the
    /// fingerprint format `HostTrust.trustedCA` and `HostTrust.pinned` rows store.
    private static func opensshSHA256Fingerprint(of key: NIOSSHPublicKey) -> String {
        // `String.init(openSSHPublicKey:)` emits "algo BASE64". The base64 payload is
        // the same wire bytes a host-key handler hashes for the pinned-fingerprint
        // comparison, so we recover them by splitting on the first space and decoding.
        let text = String(openSSHPublicKey: key)
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count >= 2, let wire = Data(base64Encoded: String(parts[1])) else {
            return "SHA256:(unavailable)"
        }
        let digest = SHA256.hash(data: wire)
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }
}
