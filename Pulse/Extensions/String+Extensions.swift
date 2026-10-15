//
//  String+Extensions.swift
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

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The trimmed text, or nil when nothing is left.
    var nonBlank: String? {
        let text = trimmed
        return text.isEmpty ? nil : text
    }

    func equalsIgnoringCase(_ other: String) -> Bool {
        localizedCaseInsensitiveCompare(other) == .orderedSame
    }

    /// `device_type` reads as `Device type`.
    var snakeCaseWords: String {
        let words = replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
