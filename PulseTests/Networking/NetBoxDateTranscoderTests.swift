//
//  NetBoxDateTranscoderTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
//

import XCTest
@testable import Pulse

/// Pins the lenient DateTranscoder against both DRF timestamp shapes.
/// The fractional fixture is a real lab value (device 882 created).
/// The whole-second fixture is synthetic: this lab snapshot had no
/// zero-microsecond timestamps, but DRF will emit them the moment a
/// row is saved on an exact second.
final class NetBoxDateTranscoderTests: XCTestCase {
    private let transcoder = NetBoxLenientDateTranscoder()

    func testDecodesFractionalSecondsFromLab() throws {
        let date = try transcoder.decode("2022-09-21T03:30:07.062900Z")
        let components = Calendar(identifier: .iso8601)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        XCTAssertEqual(components.year, 2022)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 21)
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(components.second, 7)
    }

    func testDecodesWholeSeconds() throws {
        let date = try transcoder.decode("2024-01-02T03:04:05Z")
        let components = Calendar(identifier: .iso8601)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 2)
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 4)
        XCTAssertEqual(components.second, 5)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try transcoder.decode("not-a-date"))
    }

    func testEncodeThenDecodeRoundTrips() throws {
        let original = try transcoder.decode("2022-09-21T03:30:07.062900Z")
        let encoded = try transcoder.encode(original)
        let decoded = try transcoder.decode(encoded)
        XCTAssertEqual(original.timeIntervalSince1970, decoded.timeIntervalSince1970, accuracy: 0.001)
    }
}
