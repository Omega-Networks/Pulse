//
//  NetBoxAuthorizationTests.swift
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

final class NetBoxAuthorizationTests: XCTestCase {
    func testEmptyTokenThrowsAndDoesNotProduceAHeader() {
        XCTAssertThrowsError(try NetBoxAuthorization.headerValue(for: "")) { error in
            XCTAssertEqual(error as? NetBoxSyncError, .missingToken)
        }
    }

    func testV2PrefixUsesBearer() throws {
        XCTAssertEqual(
            try NetBoxAuthorization.headerValue(for: "nbt_example.not-a-real-token"),
            "Bearer nbt_example.not-a-real-token"
        )
    }

    func testOtherTokensUseV1TokenScheme() throws {
        XCTAssertEqual(
            try NetBoxAuthorization.headerValue(for: "abc123"),
            "Token abc123"
        )
    }

    func testHTTPSServerURLIsAccepted() throws {
        let url = try NetBoxServerURL.parse("https://netbox.example.com")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "netbox.example.com")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
    }

    func testPathAtSignIsNotUserinfo() throws {
        let url = try NetBoxServerURL.parse("https://netbox.example.com/path@foo")
        XCTAssertEqual(url.host, "netbox.example.com")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
    }

    func testHTTPServerURLIsRejected() {
        XCTAssertThrowsError(try NetBoxServerURL.parse("http://netbox.example.com")) { error in
            XCTAssertEqual(
                error as? NetBoxSyncError,
                .invalidServerURL("http://netbox.example.com")
            )
        }
    }

    func testEmptyServerURLThrowsMissing() {
        XCTAssertThrowsError(try NetBoxServerURL.parse("   ")) { error in
            XCTAssertEqual(error as? NetBoxSyncError, .missingServerURL)
        }
    }

    func testGarbageServerURLIsRejected() {
        XCTAssertThrowsError(try NetBoxServerURL.parse("not a url")) { error in
            XCTAssertEqual(error as? NetBoxSyncError, .invalidServerURL("not a url"))
        }
    }

    func testUserinfoServerURLIsRejectedAndRedacted() {
        XCTAssertThrowsError(try NetBoxServerURL.parse("https://user:pass@netbox.example.com")) { error in
            let syncError = error as? NetBoxSyncError
            XCTAssertEqual(syncError, .invalidServerURL("https://netbox.example.com"))
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(description.contains("user"))
            XCTAssertFalse(description.contains("pass"))
            XCTAssertTrue(description.contains("netbox.example.com"))
        }
    }

    func testTokenUserinfoServerURLIsRejectedAndRedacted() {
        let raw = "https://nbt_example.not-a-real-token@netbox.example.com"
        XCTAssertThrowsError(try NetBoxServerURL.parse(raw)) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertEqual(
                error as? NetBoxSyncError,
                .invalidServerURL("https://netbox.example.com")
            )
            XCTAssertFalse(description.contains("nbt_example"))
            XCTAssertFalse(description.contains("not-a-real-token"))
        }
    }

    func testHTTPUserinfoIsRejectedWithoutEchoingPassword() {
        XCTAssertThrowsError(try NetBoxServerURL.parse("http://user:pass@netbox.example.com")) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertEqual(
                error as? NetBoxSyncError,
                .invalidServerURL("http://netbox.example.com")
            )
            XCTAssertFalse(description.contains("pass"))
        }
    }

    func testRedactedLeavesGarbageUnchanged() {
        XCTAssertEqual(NetBoxServerURL.redacted("not a url"), "not a url")
        XCTAssertEqual(
            NetBoxServerURL.redacted("http://netbox.example.com"),
            "http://netbox.example.com"
        )
    }

    func testLogDescriptionDropsUserinfoQueryAndFragment() throws {
        let url = try XCTUnwrap(
            URL(string: "https://user:pass@netbox.example.com:8443/api/dcim/devices/?limit=1#frag")
        )
        XCTAssertEqual(
            NetBoxServerURL.logDescription(url),
            "https://netbox.example.com:8443/api/dcim/devices"
        )
    }
}
