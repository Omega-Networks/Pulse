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

    /// http and https runs become links. Trailing sentence punctuation stays
    /// in the text and out of the link. A query string stays. Other schemes
    /// stay plain text, so a trigger comment cannot open `file:` or `ssh:`.
    func linkified() -> AttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return AttributedString(self)
        }
        let ns = self as NSString
        let matches = detector.matches(
            in: self,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )
        let trailing = CharacterSet(charactersIn: ".,;:!?)]}>\"'")
        var result = AttributedString()
        var cursor = startIndex
        for match in matches {
            var range = match.range
            while range.length > 0 {
                let unit = ns.character(at: range.location + range.length - 1)
                guard let scalar = UnicodeScalar(unit), trailing.contains(scalar) else { break }
                range.length -= 1
            }
            guard range.length > 0, let swiftRange = Range(range, in: self) else { continue }
            guard swiftRange.lowerBound >= cursor else { continue }
            let slice = String(self[swiftRange])
            guard let url = URL(string: slice), WebOrigin.isBrowserOpenable(url) else { continue }
            if cursor < swiftRange.lowerBound {
                result += AttributedString(self[cursor..<swiftRange.lowerBound])
            }
            var linked = AttributedString(slice)
            linked.link = url
            result += linked
            cursor = swiftRange.upperBound
        }
        if cursor < endIndex {
            result += AttributedString(self[cursor..<endIndex])
        }
        return result
    }
}
