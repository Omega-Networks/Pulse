//
//  NetBoxLenientDateTranscoder.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
