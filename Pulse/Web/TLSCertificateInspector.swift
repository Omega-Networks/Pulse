//
//  TLSCertificateInspector.swift
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

import CryptoKit
import Foundation
import Security

// MARK: - TLS certificate inspector

/// Derives a stable identity for a server's leaf certificate so device-web TLS
/// trust can be pinned and compared, mirroring the SSH host-key fingerprint.
/// The rendering (`SHA256:<base64-no-padding>`) deliberately matches the OpenSSH
/// fingerprint shape the SSH subsystem shows, so the two trust surfaces read the
/// same way to an operator.
enum TLSCertificateInspector {

    /// Leaf-certificate identity for a server trust: SHA-256 of the leaf's DER
    /// encoding plus a coarse key-algorithm label. Returns nil when the chain is
    /// empty or unreadable.
    static func leafFingerprint(of trust: SecTrust) -> (sha256: String, algorithm: String)? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        return fingerprint(of: leaf)
    }

    /// Fingerprint of a single certificate. Split out from `leafFingerprint(of:)`
    /// so it is unit-testable from a `SecCertificate` without constructing a
    /// `SecTrust`.
    static func fingerprint(of certificate: SecCertificate) -> (sha256: String, algorithm: String) {
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der)
        let base64 = Data(digest).base64EncodedString()
        let noPadding = base64.replacingOccurrences(of: "=", with: "")
        return ("SHA256:" + noPadding, keyAlgorithm(of: certificate))
    }

    /// Coarse public-key algorithm label (e.g. `RSA-2048`, `EC-256`) for display
    /// in the trust prompt. Best-effort: returns `"unknown"` if the key or its
    /// attributes are unreadable. The label is informational only; pin identity
    /// is the SHA-256 fingerprint.
    private static func keyAlgorithm(of certificate: SecCertificate) -> String {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any] else {
            return "unknown"
        }
        let keyType = attributes[kSecAttrKeyType] as? String
        let label: String
        if keyType == (kSecAttrKeyTypeRSA as String) {
            label = "RSA"
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            label = "EC"
        } else {
            label = "key"
        }
        if let bits = attributes[kSecAttrKeySizeInBits] as? Int {
            return "\(label)-\(bits)"
        }
        return label
    }
}
