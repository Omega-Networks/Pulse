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
}
