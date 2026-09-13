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

    func testHostOnlyURLUsesDefaultZabbixJsonRPCPath() throws {
        let url = try ZabbixServerURL.jsonRPCEndpoint("https://zabbix.example.com")
        XCTAssertEqual(url.absoluteString, "https://zabbix.example.com/zabbix/api_jsonrpc.php")
    }

    func testZabbixPathAppendsJsonRPCFile() throws {
        let url = try ZabbixServerURL.jsonRPCEndpoint("https://zabbix.example.com/zabbix")
        XCTAssertEqual(url.absoluteString, "https://zabbix.example.com/zabbix/api_jsonrpc.php")
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
}

private struct TinyID: Decodable, Sendable {
    let eventid: String
}
