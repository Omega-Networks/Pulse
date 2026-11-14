//
//  ReferenceWebTests.swift
//  PulseTests
//
//  Copyright © 2025-present Omega Networks Limited.
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

import Foundation
import WebKit
import XCTest
@testable import Pulse

final class ReferenceWebTests: XCTestCase {
    private let origin = WebOrigin(scheme: "https", host: "nvd.nist.gov", port: 443)

    func testSameOriginStaysInTheWindow() {
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "https://nvd.nist.gov/vuln/detail/CVE-2024-1234")!),
            .allow
        )
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "https://nvd.nist.gov/")!),
            .allow
        )
    }

    func testForeignWebGoesToTheSystemBrowser() {
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "https://www.cisa.gov/known-exploited-vulnerabilities-catalog?search_api_fulltext=CVE-2024-1234")!),
            .openInBrowser
        )
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "http://example.com/advisory")!),
            .openInBrowser
        )
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "https://nvd.nist.gov:8443/")!),
            .openInBrowser
        )
    }

    func testRedirectBeforeThePageCommitsStaysInTheWindow() {
        let next = URL(string: "https://www.fortiguard.com/psirt/FG-IR-26-122")!
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: next, followsRedirect: true),
            .adopt(WebOrigin(url: next)!)
        )
        let adopted = WebOrigin(url: next)!
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: adopted, url: URL(string: "https://www.fortiguard.com/psirt/FG-IR-26-122")!),
            .allow
        )
    }

    func testSameOriginRedirectDoesNotReplaceTheOrigin() {
        XCTAssertEqual(
            ReferenceNavigation.decision(
                origin: origin,
                url: URL(string: "https://nvd.nist.gov/vuln/detail/CVE-2024-1234")!,
                followsRedirect: true
            ),
            .allow
        )
    }

    func testRedirectToANonWebSchemeIsCancelled() {
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "file:///etc/passwd")!, followsRedirect: true),
            .cancel
        )
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "javascript:alert(1)")!, followsRedirect: true),
            .cancel
        )
    }

    func testHandoffBeforeCommitIsOpenedInTheBrowser() {
        let opened = URL(string: "https://www.cisa.gov/known-exploited-vulnerabilities-catalog")!
        let error = NSError(domain: "WebKit.WebPage.NavigationError", code: 0)
        XCTAssertEqual(
            ReferenceLoadOutcome.resolve(committed: false, handedOff: opened, error: error),
            .openedInBrowser(opened)
        )
    }

    func testHandoffAfterCommitKeepsThePage() {
        let opened = URL(string: "https://www.cisa.gov/")!
        XCTAssertEqual(
            ReferenceLoadOutcome.resolve(committed: true, handedOff: opened, error: NSError(domain: "x", code: 1)),
            .keepPage
        )
    }

    func testARealLoadErrorStaysAFailure() {
        let error = NSError(
            domain: "NSURLErrorDomain",
            code: -1009,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        guard case .failed(let message) = ReferenceLoadOutcome.resolve(committed: false, handedOff: nil, error: error) else {
            return XCTFail("expected a load failure")
        }
        XCTAssertTrue(message.contains("NSURLErrorDomain"))
        XCTAssertTrue(message.contains("-1009"))
    }

    func testOtherSchemesAreCancelled() {
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "file:///etc/passwd")!),
            .cancel
        )
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "ssh://10.0.0.1")!),
            .cancel
        )
        XCTAssertEqual(
            ReferenceNavigation.decision(origin: origin, url: URL(string: "javascript:alert(1)")!),
            .cancel
        )
        XCTAssertEqual(ReferenceNavigation.decision(origin: origin, url: nil), .cancel)
    }

    @MainActor
    func testChallengeUsesSystemValidation() async {
        let decider = ReferenceWebNavigationDecider(origin: origin)
        let space = URLProtectionSpace(
            host: "nvd.nist.gov",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: UnusedChallengeSender()
        )
        let (disposition, credential) = await decider.decideAuthenticationChallengeDisposition(for: challenge)
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    @MainActor
    func testReferenceStoreIsNotPersistent() {
        XCTAssertFalse(ReferenceWebConfiguration.make().websiteDataStore.isPersistent)
    }
}

private final class UnusedChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
