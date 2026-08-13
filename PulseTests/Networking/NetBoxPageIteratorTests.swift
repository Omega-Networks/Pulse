//
//  NetBoxPageIteratorTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  Under the terms of the GNU Affero General Public License version 3 as published by the
//  Free Software Foundation, this program is free software: communities can deploy it for
//  sovereignty, academia can extend it for research, and industry can integrate it for resilience.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
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

    func testFetchDecodedPageCapThrowsSyncError() async {
        final class LoopFetcher: NetBoxFetching, @unchecked Sendable {
            func get(path: String, query: [URLQueryItem]) async throws -> Data {
                Data(#"{"count":99,"next":"x","results":[{"ok":true}]}"#.utf8)
            }
        }
        struct Row: Decodable, Sendable { var ok: Bool }
        do {
            _ = try await NetBoxPageIterator.fetchDecoded(
                path: "/api/dcim/sites/",
                as: Row.self,
                using: LoopFetcher(),
                maxPages: 2
            )
            XCTFail("expected pageLimitExceeded")
        } catch NetBoxSyncError.pageLimitExceeded {
            // expected
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testPageCapStopsALoopingNext() async {
        var calls = 0
        do {
            try await NetBoxPageIterator.forEachPage(
                fetchPage: { offset -> NetBoxPageIterator.Page<Int> in
                    calls += 1
                    return .init(results: [offset], next: "still-more", count: 99)
                },
                maxPages: 3,
                body: { _ in }
            )
            XCTFail("expected pageLimitExceeded")
        } catch NetBoxPageIterator.IteratorError.pageLimitExceeded {
            XCTAssertEqual(calls, 3)
        } catch {
            XCTFail("wrong error \(error)")
        }
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
