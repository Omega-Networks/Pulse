//
//  ZabbixJSONRPCTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Licensed under the GNU Affero General Public License version 3.
//  See <https://www.gnu.org/licenses/>.
//

import XCTest
@testable import Pulse

final class ZabbixJSONRPCTests: XCTestCase {
    func testApiTokenPutsBearerAndOmitsBodyAuth() {
        let applied = ZabbixJSONRPC.appliedAuth(
            mode: .apiToken, method: "problem.get", credential: "tok"
        )
        XCTAssertNil(applied.bodyAuth)
        XCTAssertEqual(applied.bearerHeader, "Bearer tok")
        let body = ZabbixJSONRPC.requestBody(
            method: "problem.get", params: [:], id: 1, bodyAuth: applied.bodyAuth
        )
        XCTAssertNil(body["auth"])
    }

    func testLegacyPutsAuthInBodyAndOmitsBearer() {
        let applied = ZabbixJSONRPC.appliedAuth(
            mode: .legacy, method: "problem.get", credential: "session"
        )
        XCTAssertEqual(applied.bodyAuth, "session")
        XCTAssertNil(applied.bearerHeader)
        let body = ZabbixJSONRPC.requestBody(
            method: "problem.get", params: [:], id: 1, bodyAuth: applied.bodyAuth
        )
        XCTAssertEqual(body["auth"] as? String, "session")
    }

    func testLoginAndVersionNeverCarryCredentials() {
        for method in ["user.login", "apiinfo.version"] {
            for mode in ZabbixAuthMode.allCases {
                let applied = ZabbixJSONRPC.appliedAuth(
                    mode: mode, method: method, credential: "secret"
                )
                XCTAssertNil(applied.bodyAuth, method)
                XCTAssertNil(applied.bearerHeader, method)
            }
        }
    }

    func testEmptyCredentialOmitsBoth() {
        let applied = ZabbixJSONRPC.appliedAuth(
            mode: .apiToken, method: "problem.get", credential: ""
        )
        XCTAssertNil(applied.bodyAuth)
        XCTAssertNil(applied.bearerHeader)
    }

    func testParsesObjectErrorWithData() {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": -32600,
                "message": "Invalid request.",
                "data": "Invalid parameter \"/\": unexpected parameter \"auth\"."
            ],
            "id": 1
        ]
        let description = ZabbixJSONRPC.errorDescription(from: object)
        XCTAssertTrue(description.contains("Invalid request."))
        XCTAssertTrue(description.contains("unexpected parameter"))
        XCTAssertTrue(ZabbixJSONRPC.looksLikeRejectedBodyAuth(description))
        XCTAssertEqual(
            ZabbixError.fromRPC(object),
            .invalidResponse(
                "Zabbix 7.2+ rejected body auth. Use API token authentication (default) in Settings."
            )
        )
    }

    func testParsesUnauthorizedAsAuthFailure() {
        let object: [String: Any] = [
            "error": [
                "code": -32602,
                "message": "Invalid params.",
                "data": "Not authorized."
            ]
        ]
        XCTAssertEqual(ZabbixError.fromRPC(object), .authenticationFailed)
    }

    func testStringErrorStillWorks() {
        XCTAssertEqual(
            ZabbixJSONRPC.errorDescription(from: ["error": "boom"]),
            "boom"
        )
    }

    func testMissingErrorIsUnknown() {
        XCTAssertEqual(
            ZabbixJSONRPC.errorDescription(from: ["result": []]),
            "Unknown error"
        )
    }

    func testDefaultAuthModeIsApiToken() {
        XCTAssertEqual(ZabbixAuthMode.default, .apiToken)
    }

    func testMissingModeWithUsernameIsLegacy() {
        XCTAssertEqual(
            ZabbixAuthMode.resolved(storedRawValue: nil, hasUsername: true),
            .legacy
        )
    }

    func testMissingModeWithoutUsernameIsApiToken() {
        XCTAssertEqual(
            ZabbixAuthMode.resolved(storedRawValue: nil, hasUsername: false),
            .apiToken
        )
    }

    func testStoredModeWinsOverUsername() {
        XCTAssertEqual(
            ZabbixAuthMode.resolved(storedRawValue: "apiToken", hasUsername: true),
            .apiToken
        )
        XCTAssertEqual(
            ZabbixAuthMode.resolved(storedRawValue: "legacy", hasUsername: false),
            .legacy
        )
    }

    func testUnknownStoredModeFallsBackLikeMissing() {
        XCTAssertEqual(
            ZabbixAuthMode.resolved(storedRawValue: "not-a-mode", hasUsername: true),
            .legacy
        )
        XCTAssertEqual(
            ZabbixAuthMode.resolved(storedRawValue: "not-a-mode", hasUsername: false),
            .apiToken
        )
    }

    func testHostOnlyURLUsesJsonRPCAtTheOrigin() throws {
        let url = try ZabbixServerURL.jsonRPCEndpoint("https://zabbix.example.com")
        XCTAssertEqual(url.absoluteString, "https://zabbix.example.com/api_jsonrpc.php")
    }

    func testZabbixPathAppendsJsonRPCFile() throws {
        let url = try ZabbixServerURL.jsonRPCEndpoint("https://zabbix.example.com/zabbix")
        XCTAssertEqual(url.absoluteString, "https://zabbix.example.com/zabbix/api_jsonrpc.php")
    }

    func testJsonRPCFileAlreadyInTheURLIsLeftAlone() throws {
        let url = try ZabbixServerURL.jsonRPCEndpoint("https://zabbix.example.com/api_jsonrpc.php")
        XCTAssertEqual(url.absoluteString, "https://zabbix.example.com/api_jsonrpc.php")
    }

    func testHistoryValueWiderThanInt64DoesNotTrap() throws {
        let tooWide = Double(Int64.max)
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "result": [[
                "itemid": "1",
                "clock": "1",
                "value": tooWide
            ]],
            "id": 1
        ]
        let decoded = try ZabbixJSONRPC.decodeElements(HistoryProperties.self, from: object)
        XCTAssertEqual(decoded.skipped, 0)
        XCTAssertEqual(decoded.items.first?.value, String(tooWide))
    }

    func testHistoryKeepsStringAndNumericRows() throws {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "result": [
                ["itemid": "1", "clock": "1351090996", "value": "0.085"],
                ["itemid": 2, "clock": 1351090936, "value": 0.5]
            ],
            "id": 1
        ]
        let decoded = try ZabbixJSONRPC.decodeElements(HistoryProperties.self, from: object)
        XCTAssertEqual(decoded.skipped, 0)
        XCTAssertEqual(decoded.items.map(\.itemId), ["1", "2"])
        XCTAssertEqual(decoded.items.map(\.clock), ["1351090996", "1351090936"])
        XCTAssertEqual(decoded.items.map(\.value), ["0.085", "0.5"])
    }

    func testTrendKeepsTheHourlyAverage() throws {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "result": [
                [
                    "itemid": "23715",
                    "clock": "1446199200",
                    "num": "60",
                    "value_min": "0.165",
                    "value_avg": "0.2168",
                    "value_max": "0.35"
                ],
                ["itemid": 133870, "clock": 1446199200, "value_avg": 1_250_000.5],
                ["itemid": "1", "clock": "2"]
            ],
            "id": 1
        ]
        let decoded = try ZabbixJSONRPC.decodeElements(TrendProperties.self, from: object)
        XCTAssertEqual(decoded.skipped, 1)
        XCTAssertEqual(decoded.items.map(\.itemId), ["23715", "133870"])
        XCTAssertEqual(decoded.items.map(\.clock), ["1446199200", "1446199200"])
        XCTAssertEqual(decoded.items.map(\.valueAvg), ["0.2168", "1250000.5"])
    }

    func testItemKeepsANumericValueType() throws {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "result": [[
                "itemid": "10",
                "name": "ICMP ping",
                "history": "7d",
                "trends": "365d",
                "status": 0,
                "units": "",
                "templateid": 0,
                "value_type": 3,
                "description": ""
            ]],
            "id": 1
        ]
        let decoded = try ZabbixJSONRPC.decodeElements(ItemProperties.self, from: object)
        XCTAssertEqual(decoded.skipped, 0)
        XCTAssertEqual(decoded.items.first?.valueType, "3")
        XCTAssertEqual(decoded.items.first?.name, "ICMP ping")
    }

    func testHTTPServerURLIsRejected() {
        XCTAssertThrowsError(try ZabbixServerURL.parse("http://zabbix.example.com")) { error in
            XCTAssertEqual(error as? ZabbixError, .invalidServerURL("http://zabbix.example.com"))
        }
    }

    func testUserinfoServerURLIsRejected() {
        XCTAssertThrowsError(try ZabbixServerURL.parse("https://token@zabbix.example.com")) { error in
            XCTAssertEqual(
                error as? ZabbixError,
                .invalidServerURL("https://token@zabbix.example.com")
            )
        }
    }

    func testEmptyServerURLIsInvalidRequest() {
        XCTAssertThrowsError(try ZabbixServerURL.parse("  ")) { error in
            XCTAssertEqual(error as? ZabbixError, .invalidRequest)
        }
    }

    func testDecodeSkipsPoisonElement() throws {
        struct Row: Decodable, Sendable { let eventid: String }
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "result": [
                ["eventid": "1"],
                ["nope": true]
            ],
            "id": 1
        ]
        let decoded = try ZabbixJSONRPC.decodeElements(Row.self, from: object)
        XCTAssertEqual(decoded.items.map(\.eventid), ["1"])
        XCTAssertEqual(decoded.skipped, 1)
    }

    func testDecodeMissingResultIsRPCError() {
        let object: [String: Any] = [
            "error": [
                "code": -32600,
                "message": "Invalid request.",
                "data": "Invalid parameter \"/\": unexpected parameter \"auth\"."
            ]
        ]
        XCTAssertThrowsError(try ZabbixJSONRPC.decodeElements(TinyID.self, from: object)) { error in
            XCTAssertEqual(
                error as? ZabbixError,
                .invalidResponse(
                    "Zabbix 7.2+ rejected body auth. Use API token authentication (default) in Settings."
                )
            )
        }
    }

    func testURLRequestTimeoutAndBearer() throws {
        let endpoint = try ZabbixServerURL.jsonRPCEndpoint("https://zabbix.example.com/zabbix")
        let applied = ZabbixJSONRPC.appliedAuth(
            mode: .apiToken, method: "problem.get", credential: "tok"
        )
        let request = try ZabbixJSONRPC.urlRequest(
            endpoint: endpoint,
            method: "problem.get",
            params: [:],
            applied: applied,
            extraHeaders: nil
        )
        XCTAssertEqual(request.timeoutInterval, ZabbixServerURL.timeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        XCTAssertNil(body?["auth"])
    }

    func testHistoryReadPlanUsesTheStoredSpan() {
        let series = HistorySeries.loaded(
            [HistoryPoint(clock: 10, value: 1), HistoryPoint(clock: 20, value: 2)],
            kind: .history,
            requestedStart: 0,
            requestedEnd: 30,
            truncated: false
        )
        XCTAssertEqual(historyReadPlan(series, from: 10, to: 20), .serve)
        XCTAssertEqual(historyReadPlan(series, from: 0, to: 30.5), .serve)
        XCTAssertEqual(historyReadPlan(series, from: 0, to: 32), .newer(since: 30, kind: .history))
        XCTAssertEqual(historyReadPlan(series, from: -10, to: 30), .older(until: 0))
        XCTAssertEqual(
            historyReadPlan(series, from: -10, to: 40),
            .both(until: 0, since: 30, kind: .history)
        )

        let truncated = HistorySeries.loaded(
            [HistoryPoint(clock: 50, value: 1)],
            kind: .history,
            requestedStart: 0,
            requestedEnd: 100,
            truncated: true
        )
        XCTAssertEqual(historyReadPlan(truncated, from: 0, to: 100), .serve)
    }

    func testHistorySliceKeepsTheInclusiveWindow() {
        let series = HistorySeries(
            kind: .history,
            points: [0, 10, 20, 30].map { HistoryPoint(clock: Double($0), value: 1) },
            coveredStart: 0,
            coveredEnd: 30,
            truncated: false
        )
        XCTAssertEqual(series.slice(from: 10, to: 20).map(\.clock), [10, 20])
    }

    func testHistoryMergeKeepsTheStoredBoundaryClock() {
        let merged = historyMerged(
            existing: [HistoryPoint(clock: 10, value: 1), HistoryPoint(clock: 20, value: 2)],
            fetched: [HistoryPoint(clock: 20, value: 9), HistoryPoint(clock: 30, value: 3)]
        )
        XCTAssertEqual(merged, [
            HistoryPoint(clock: 10, value: 1),
            HistoryPoint(clock: 20, value: 2),
            HistoryPoint(clock: 30, value: 3)
        ])
    }

    func testTrendReplacementDropsTheRawSamples() {
        let trends = [HistoryPoint(clock: 0, value: 1), HistoryPoint(clock: 3600, value: 2)]
        let series = HistorySeries.loaded(
            trends,
            kind: .trend,
            requestedStart: 0,
            requestedEnd: 7200,
            truncated: false
        )
        XCTAssertEqual(series.kind, .trend)
        XCTAssertEqual(series.points, trends)
        XCTAssertEqual(series.coveredEnd, 7200)
    }

    func testOlderGapDoesNotCloseTheLiveEdge() {
        let series = HistorySeries.loaded(
            [HistoryPoint(clock: 100, value: 1)],
            kind: .history,
            requestedStart: 100,
            requestedEnd: 200,
            truncated: false
        )
        let older = series.applyingOlder(
            [HistoryPoint(clock: 50, value: 1)],
            truncated: false,
            requestedStart: 40
        )
        XCTAssertEqual(older.coveredStart, 40)
        XCTAssertEqual(older.coveredEnd, 200)
        XCTAssertEqual(older.points.map(\.clock), [50, 100])
    }

    func testCatchUpDropsTheOldestPointOnceThePageIsFull() {
        let limit = zabbixHistoryPageLimit
        var points: [HistoryPoint] = []
        points.reserveCapacity(limit)
        for clock in 0..<limit {
            points.append(HistoryPoint(clock: Double(clock), value: 1))
        }
        let stored = HistorySeries.loaded(
            points,
            kind: .history,
            requestedStart: 0,
            requestedEnd: Double(limit - 1),
            truncated: true
        )
        let updated = stored.applyingNewer(
            [HistoryPoint(clock: Double(limit + 1), value: 2)],
            truncated: false,
            requestedEnd: Double(limit + 1)
        )
        XCTAssertEqual(updated.points.count, limit)
        XCTAssertEqual(updated.points.first?.clock, 1)
        XCTAssertEqual(updated.points.last?.clock, Double(limit + 1))
        XCTAssertTrue(updated.truncated)

        let small = HistorySeries.loaded(
            [HistoryPoint(clock: 0, value: 1), HistoryPoint(clock: 1, value: 1), HistoryPoint(clock: 2, value: 1)],
            kind: .history,
            requestedStart: 0,
            requestedEnd: 2,
            truncated: false
        )
        let grown = small.applyingNewer(
            [HistoryPoint(clock: 3, value: 1)],
            truncated: false,
            requestedEnd: 3
        )
        XCTAssertEqual(grown.points.map(\.clock), [0, 1, 2, 3])
        XCTAssertFalse(grown.truncated)
    }

    func testCommitNewerReturnsTheAskedWindow() async {
        let store = HistorySeriesStore()
        let week = (0...7).map { HistoryPoint(clock: Double($0) * 3600, value: Double($0)) }
        let stored = HistorySeries.loaded(
            week,
            kind: .history,
            requestedStart: 0,
            requestedEnd: 7 * 3600,
            truncated: false
        )
        _ = await store.commit(stored, itemId: "1", valueType: 0, from: 0, to: 7 * 3600)
        let rows = await store.commitNewer(
            [HistoryPoint(clock: 8 * 3600, value: 99)],
            truncated: false,
            itemId: "1",
            valueType: 0,
            from: 6 * 3600,
            requestedEnd: 8 * 3600
        )
        let clocks = rows.keys.map(\.timeIntervalSince1970).sorted()
        XCTAssertEqual(clocks, [6 * 3600, 7 * 3600, 8 * 3600])
    }

    func testQuietOlderIsNotFetchedAgain() async {
        let store = HistorySeriesStore()
        let series = HistorySeries.loaded(
            [HistoryPoint(clock: 100, value: 1)],
            kind: .history,
            requestedStart: 100,
            requestedEnd: 200,
            truncated: false
        )
        _ = await store.commit(series, itemId: "a", valueType: 0, from: 100, to: 200)
        let before = await store.plan(itemId: "a", valueType: 0, from: 50, to: 200)
        XCTAssertEqual(before, .older(until: 100))
        _ = await store.noteQuietOlder(itemId: "a", valueType: 0, from: 50, to: 200)
        let after = await store.plan(itemId: "a", valueType: 0, from: 50, to: 200)
        XCTAssertEqual(after, .serve)
        let missing = await store.overlap(itemId: "missing", valueType: 0, from: 0, to: 10)
        XCTAssertNil(missing)
    }

    func testHistorySeriesStoreKeepsEightSeries() async {
        let store = HistorySeriesStore()
        for index in 0..<9 {
            let series = HistorySeries.loaded(
                [HistoryPoint(clock: 0, value: 1)],
                kind: .history,
                requestedStart: 0,
                requestedEnd: 1,
                truncated: false
            )
            _ = await store.commit(series, itemId: "\(index)", valueType: 0, from: 0, to: 1)
        }
        let evicted = await store.plan(itemId: "0", valueType: 0, from: 0, to: 1)
        let kept = await store.plan(itemId: "8", valueType: 0, from: 0, to: 1)
        XCTAssertEqual(evicted, .load)
        XCTAssertEqual(kept, .serve)
    }

    func testHistoryDictionaryRoundTripsFiniteValues() {
        let values = [0.0, 0.0035, 0.003218, 1, 1.2, 850.126, 4.2e-05, 1e20, -0.0042, Double.pi]
        let points = values.enumerated().map { HistoryPoint(clock: Double($0.offset), value: $0.element) }
        let rows = historyDictionary(points)
        for point in points {
            XCTAssertEqual(Double(rows[Date(timeIntervalSince1970: point.clock)] ?? ""), point.value)
        }
    }
}

private struct TinyID: Decodable, Sendable {
    let eventid: String
}
