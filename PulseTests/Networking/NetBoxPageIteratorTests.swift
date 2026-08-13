//
//  NetBoxPageIteratorTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
//

import XCTest
@testable import Pulse

final class NetBoxPageIteratorTests: XCTestCase {
    func testFetchesUntilNextIsNil() async throws {
        let pages: [NetBoxPageIterator.Page<Int>] = [
            .init(results: [1, 2], next: "https://example.com/?offset=2", count: 3),
            .init(results: [3], next: nil, count: 3),
        ]
        var offsets: [Int] = []
        let all = try await NetBoxPageIterator.fetchAll { offset in
            offsets.append(offset)
            return pages[offsets.count - 1]
        }
        XCTAssertEqual(all, [1, 2, 3])
        XCTAssertEqual(offsets, [0, 2])
    }

    func testSinglePageDoesNotAdvance() async throws {
        var calls = 0
        let all = try await NetBoxPageIterator.fetchAll { offset -> NetBoxPageIterator.Page<Int> in
            calls += 1
            XCTAssertEqual(offset, 0)
            return .init(results: [9], next: nil, count: 1)
        }
        XCTAssertEqual(all, [9])
        XCTAssertEqual(calls, 1)
    }

    func testEmptyPageWithNextThrowsAndDoesNotLoop() async {
        do {
            _ = try await NetBoxPageIterator.fetchAll { _ -> NetBoxPageIterator.Page<Int> in
                .init(results: [], next: "https://example.com/?offset=1000", count: 1)
            }
            XCTFail("expected emptyPageWithNext")
        } catch NetBoxPageIterator.IteratorError.emptyPageWithNext {
            // expected
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testForEachPageStreamsWithoutMaterializingCallerSide() async throws {
        var seen: [[Int]] = []
        try await NetBoxPageIterator.forEachPage(
            fetchPage: { offset -> NetBoxPageIterator.Page<Int> in
                if offset == 0 {
                    return .init(results: [1], next: "n", count: 2)
                }
                return .init(results: [2], next: nil, count: 2)
            },
            body: { seen.append($0) }
        )
        XCTAssertEqual(seen, [[1], [2]])
    }

    func testTransportErrorStopsIteration() async {
        struct Boom: Error {}
        var calls = 0
        do {
            _ = try await NetBoxPageIterator.fetchAll { _ -> NetBoxPageIterator.Page<Int> in
                calls += 1
                if calls == 1 {
                    return .init(results: [1], next: "n", count: 2)
                }
                throw Boom()
            }
            XCTFail("expected Boom")
        } catch is Boom {
            XCTAssertEqual(calls, 2)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }
}
