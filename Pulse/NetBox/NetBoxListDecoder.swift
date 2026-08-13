//
//  NetBoxListDecoder.swift
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
import OSLog

/// Per-element list decode. A poisoned result is skipped; the page continues.
/// `skipped > 0` means the caller must not run the delete pass.
enum NetBoxListDecoder {
    private static let logger = Logger(subsystem: "netbox", category: "decode")
    struct Page<Element>: Sendable where Element: Sendable {
        var results: [Element]
        var next: String?
        var count: Int
        var skipped: Int

        var allowsDelete: Bool { skipped == 0 }
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let transcoder = NetBoxLenientDateTranscoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            return try transcoder.decode(raw)
        }
        return decoder
    }

    static func decodePage<Element: Decodable & Sendable>(
        _ type: Element.Type,
        from data: Data,
        decoder: JSONDecoder = makeDecoder()
    ) throws -> Page<Element> {
        let envelope = try decoder.decode(Envelope.self, from: data)
        var results: [Element] = []
        var skipped = 0
        results.reserveCapacity(envelope.results.count)
        for element in envelope.results {
            do {
                let decoded = try decoder.decode(Element.self, from: element)
                results.append(decoded)
            } catch {
                skipped += 1
                logger.error(
                    "Skipped \(String(describing: Element.self)): \(Self.describe(error), privacy: .public)"
                )
            }
        }
        return Page(
            results: results,
            next: envelope.next,
            count: envelope.count ?? results.count,
            skipped: skipped
        )
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "missing key '\(key.stringValue)' at \(path(context.codingPath))"
        case let DecodingError.valueNotFound(type, context):
            let detail = context.debugDescription.isEmpty ? "\(type)" : context.debugDescription
            return "missing \(detail) at \(path(context.codingPath))"
        case let DecodingError.typeMismatch(type, context):
            return "type mismatch \(type) at \(path(context.codingPath))"
        case let DecodingError.dataCorrupted(context):
            return "corrupt at \(path(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let joined = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        return joined.isEmpty ? "<root>" : joined
    }

    private struct Envelope: Decodable {
        var count: Int?
        var next: String?
        var results: [Data]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            count = try container.decodeIfPresent(Int.self, forKey: .count)
            next = try container.decodeIfPresent(String.self, forKey: .next)
            var nested = try container.nestedUnkeyedContainer(forKey: .results)
            var blobs: [Data] = []
            let encoder = JSONEncoder()
            while !nested.isAtEnd {
                let raw = try nested.decode(RawJSON.self)
                blobs.append(try encoder.encode(raw))
            }
            results = blobs
        }

        private enum CodingKeys: String, CodingKey {
            case count, next, results
        }
    }

    /// Opaque JSON value so we can re-encode each results element independently.
    private struct RawJSON: Codable {
        let value: AnyCodable

        init(from decoder: Decoder) throws {
            value = try AnyCodable(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }
}

/// Minimal AnyCodable so a list page can be split without a third-party package.
private struct AnyCodable: Codable {
    let encodeTo: (Encoder) throws -> Void

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            encodeTo = { encoder in
                var c = encoder.singleValueContainer()
                try c.encodeNil()
            }
        } else if let value = try? container.decode(Bool.self) {
            encodeTo = { encoder in
                var c = encoder.singleValueContainer()
                try c.encode(value)
            }
        } else if let value = try? container.decode(Int.self) {
            encodeTo = { encoder in
                var c = encoder.singleValueContainer()
                try c.encode(value)
            }
        } else if let value = try? container.decode(Double.self) {
            encodeTo = { encoder in
                var c = encoder.singleValueContainer()
                try c.encode(value)
            }
        } else if let value = try? container.decode(String.self) {
            encodeTo = { encoder in
                var c = encoder.singleValueContainer()
                try c.encode(value)
            }
        } else if let value = try? container.decode([AnyCodable].self) {
            encodeTo = { encoder in
                var c = encoder.singleValueContainer()
                try c.encode(value)
            }
        } else if let value = try? container.decode([String: AnyCodable].self) {
            encodeTo = { encoder in
                var c = encoder.singleValueContainer()
                try c.encode(value)
            }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeTo(encoder)
    }
}
