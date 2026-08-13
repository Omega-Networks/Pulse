//
//  NetBoxLenientDateTranscoder.swift
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
import OpenAPIRuntime

/// Decodes the two ISO-8601 shapes DRF actually emits.
///
/// NetBox/DRF writes fractional seconds only when microseconds are non-zero.
/// The runtime's `.iso8601` rejects `2022-09-21T03:30:07.062900Z`;
/// `.iso8601WithFractionalSeconds` rejects `2024-01-02T03:04:05Z`.
/// Either miss silently flips `lastUpdated` comparisons or aborts a page.
///
/// Encode always emits fractional seconds — a legal ISO-8601 form DRF accepts.
struct NetBoxLenientDateTranscoder: DateTranscoder, Sendable {
    func decode(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        if let date = wholeSeconds.date(from: value) {
            return date
        }
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: [],
                debugDescription: "Invalid NetBox timestamp: \(value)"
            )
        )
    }

    func encode(_ date: Date) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
