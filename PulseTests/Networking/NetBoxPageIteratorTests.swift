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
    struct Row: Decodable, Sendable { var ok: Bool }

    func testStreamDecodedDoesNotAccumulateCallerSide() async throws {
        final class TwoPageFetcher: NetBoxFetching, @unchecked Sendable {
            var calls = 0
            func get(path: String, query: [URLQueryItem]) async throws -> Data {
                calls += 1
                if calls == 1 {
                    return Data(#"{"count":2,"next":"x","results":[{"ok":true}]}"#.utf8)
                }
                return Data(#"{"count":2,"next":null,"results":[{"ok":false}]}"#.utf8)
            }
        }
        var seen: [[Bool]] = []
        let fetcher = TwoPageFetcher()
        let result = try await NetBoxPageIterator.streamDecoded(
            path: "/api/dcim/interfaces/",
            as: Row.self,
            using: fetcher
        ) { page, skipped in
            XCTAssertEqual(skipped, 0)
            seen.append(page.map(\.ok))
        }
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(seen, [[true], [false]])
        XCTAssertEqual(fetcher.calls, 2)
    }

    func testFetchDecodedMaterializesSmallTypes() async throws {
        final class TwoPageFetcher: NetBoxFetching, @unchecked Sendable {
            var calls = 0
            func get(path: String, query: [URLQueryItem]) async throws -> Data {
                calls += 1
                if calls == 1 {
                    return Data(#"{"count":2,"next":"x","results":[{"ok":true}]}"#.utf8)
                }
                return Data(#"{"count":2,"next":null,"results":[{"ok":false}]}"#.utf8)
            }
        }
        let page = try await NetBoxPageIterator.fetchDecoded(
            path: "/api/dcim/sites/",
            as: Row.self,
            using: TwoPageFetcher()
        )
        XCTAssertEqual(page.rows.map(\.ok), [true, false])
        XCTAssertEqual(page.skipped, 0)
    }

    func testStreamDecodedPageCapThrowsSyncError() async {
        final class LoopFetcher: NetBoxFetching, @unchecked Sendable {
            func get(path: String, query: [URLQueryItem]) async throws -> Data {
                Data(#"{"count":99,"next":"x","results":[{"ok":true}]}"#.utf8)
            }
        }
        do {
            _ = try await NetBoxPageIterator.streamDecoded(
                path: "/api/dcim/interfaces/",
                as: Row.self,
                using: LoopFetcher(),
                maxPages: 2
            ) { _, _ in }
            XCTFail("expected pageLimitExceeded")
        } catch NetBoxSyncError.pageLimitExceeded {
            // expected
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testFetchDecodedPageCapThrowsSyncError() async {
        final class LoopFetcher: NetBoxFetching, @unchecked Sendable {
            func get(path: String, query: [URLQueryItem]) async throws -> Data {
                Data(#"{"count":99,"next":"x","results":[{"ok":true}]}"#.utf8)
            }
        }
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

    func testEmptyPageWithNextThrowsAndDoesNotLoop() async {
        final class EmptyNextFetcher: NetBoxFetching, @unchecked Sendable {
            var calls = 0
            func get(path: String, query: [URLQueryItem]) async throws -> Data {
                calls += 1
                return Data(#"{"count":1,"next":"x","results":[]}"#.utf8)
            }
        }
        let fetcher = EmptyNextFetcher()
        do {
            _ = try await NetBoxPageIterator.streamDecoded(
                path: "/api/dcim/interfaces/",
                as: Row.self,
                using: fetcher
            ) { _, _ in }
            XCTFail("expected emptyPageWithNext")
        } catch NetBoxSyncError.emptyPageWithNext {
            XCTAssertEqual(fetcher.calls, 1)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testTransportErrorStopsIteration() async {
        struct Boom: Error {}
        final class BoomFetcher: NetBoxFetching, @unchecked Sendable {
            var calls = 0
            func get(path: String, query: [URLQueryItem]) async throws -> Data {
                calls += 1
                if calls == 1 {
                    return Data(#"{"count":2,"next":"x","results":[{"ok":true}]}"#.utf8)
                }
                throw Boom()
            }
        }
        let fetcher = BoomFetcher()
        do {
            _ = try await NetBoxPageIterator.streamDecoded(
                path: "/api/dcim/interfaces/",
                as: Row.self,
                using: fetcher
            ) { _, _ in }
            XCTFail("expected Boom")
        } catch is Boom {
            XCTAssertEqual(fetcher.calls, 2)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }
}
