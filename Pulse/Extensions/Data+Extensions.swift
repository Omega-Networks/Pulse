//
//  Data+Extensions.swift
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

// MARK: - OpenSSH wire-format framing

extension Data {
    /// Appends a length-prefixed UTF-8 string in OpenSSH wire format. The length is a
    /// big-endian `uint32` followed by the raw UTF-8 bytes. Used for the algorithm
    /// name and curve identifier when encoding `ecdsa-sha2-nistp256` public keys.
    mutating func appendOpenSSHString(_ string: String) {
        appendOpenSSHString(Data(string.utf8))
    }

    /// Appends a length-prefixed binary string in OpenSSH wire format. The length is a
    /// big-endian `uint32` followed by the payload bytes. Used for the SEC1
    /// uncompressed-point payload of an ECDSA P-256 public key.
    mutating func appendOpenSSHString(_ payload: Data) {
        var length = UInt32(payload.count).bigEndian
        // Qualified call: `Data.withUnsafeBytes(_:)` shadows the free function inside
        // a `Data` extension and would otherwise capture the receiver's bytes.
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(payload)
    }
}
