//
//  WebTrustFoundationTests.swift
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

import CryptoKit
import Foundation
import Security
import SwiftData
import XCTest
@testable import Pulse

/// Headless coverage for the Slice W2a TLS-trust foundation: the source-of-truth
/// web-service rule, the pure trust evaluator, the certificate fingerprinter,
/// and the SwiftData trust store. No WebView, no network.
final class WebTrustFoundationTests: XCTestCase {

    // MARK: - Helpers

    private func makeService(
        id: Int64,
        name: String?,
        proto: String? = "tcp",
        ports: [Int],
        ip: String?
    ) -> Service {
        let service = Service(id: id)
        service.name = name
        service.protocolValue = proto
        service.ports = ports
        service.ipAddresses = ip.map { [$0] } ?? []
        return service
    }

    // MARK: - WebServiceResolver: scheme from the NetBox name

    func testSchemeIsDerivedFromServiceName() {
        XCTAssertEqual(WebServiceResolver.scheme(forServiceNamed: "HTTPS"), "https")
        XCTAssertEqual(WebServiceResolver.scheme(forServiceNamed: "HTTP"), "http")
        XCTAssertEqual(WebServiceResolver.scheme(forServiceNamed: "https-mgmt"), "https")
        // https is checked before http (it contains http as a substring).
        XCTAssertEqual(WebServiceResolver.scheme(forServiceNamed: "Secure HTTPS UI"), "https")
        // Non-web names resolve to nil: NetBox is the source of truth.
        XCTAssertNil(WebServiceResolver.scheme(forServiceNamed: "SSH"))
        XCTAssertNil(WebServiceResolver.scheme(forServiceNamed: "Proxmox"))
        XCTAssertNil(WebServiceResolver.scheme(forServiceNamed: nil))
    }

    // MARK: - WebServiceResolver: target from a single service

    func testTargetFromDeviceParentedHTTPSService() throws {
        let service = makeService(id: 1, name: "HTTPS", ports: [8006], ip: "172.27.10.201/24")
        let target = try XCTUnwrap(WebServiceResolver.target(from: service))
        XCTAssertEqual(target.scheme, "https")
        XCTAssertEqual(target.host, "172.27.10.201")
        XCTAssertEqual(target.port, 8006)
        XCTAssertEqual(target.url, URL(string: "https://172.27.10.201:8006/"))
        XCTAssertEqual(target.serviceName, "HTTPS")
    }

    func testNonWebOrIncompleteServicesResolveToNil() {
        // SSH: name does not announce a web scheme.
        XCTAssertNil(WebServiceResolver.target(from: makeService(id: 1, name: "SSH", ports: [22], ip: "10.0.0.1/24")))
        // UDP: not a web transport.
        XCTAssertNil(WebServiceResolver.target(from: makeService(id: 2, name: "HTTPS", proto: "udp", ports: [443], ip: "10.0.0.1/24")))
        // No port.
        XCTAssertNil(WebServiceResolver.target(from: makeService(id: 3, name: "HTTPS", ports: [], ip: "10.0.0.1/24")))
        // No IP.
        XCTAssertNil(WebServiceResolver.target(from: makeService(id: 4, name: "HTTPS", ports: [443], ip: nil)))
    }

    // MARK: - WebServiceResolver: ordering across multiple services

    func testWebTargetsPreferHttpsThenLowestPort() {
        let services = [
            makeService(id: 1, name: "HTTP", ports: [80], ip: "10.0.0.1/24"),
            makeService(id: 2, name: "HTTPS", ports: [8006], ip: "10.0.0.1/24"),
            makeService(id: 3, name: "HTTPS", ports: [443], ip: "10.0.0.1/24"),
            makeService(id: 4, name: "SSH", ports: [22], ip: "10.0.0.1/24")
        ]
        let targets = WebServiceResolver.webTargets(from: services)
        // SSH excluded; https before http; lowest https port first.
        XCTAssertEqual(targets.map(\.port), [443, 8006, 80])
        XCTAssertEqual(targets.first?.scheme, "https")
        XCTAssertEqual(targets.first?.port, 443)
    }

    func testWebTargetsEmptyWhenNoWebService() {
        let services = [
            makeService(id: 1, name: "SSH", ports: [22], ip: "10.0.0.1/24"),
            makeService(id: 2, name: "DNS", proto: "udp", ports: [53], ip: "10.0.0.1/24")
        ]
        XCTAssertTrue(WebServiceResolver.webTargets(from: services).isEmpty)
    }

    // MARK: - WebHostTrustEvaluator (pure)

    func testEvaluateSystemTrustedLoadsSilently() {
        XCTAssertEqual(
            WebHostTrustEvaluator.evaluate(systemTrusted: true, recorded: nil, presentedFingerprint: "fp"),
            .acceptSystemTrusted
        )
    }

    func testEvaluateUnknownUntrustedPromptsFirstSight() {
        XCTAssertEqual(
            WebHostTrustEvaluator.evaluate(systemTrusted: false, recorded: nil, presentedFingerprint: "fp"),
            .promptFirstSight
        )
    }

    func testEvaluatePinnedMatchAccepts() {
        let recorded = HostTrust.pinned(fingerprintSHA256: "fp", algorithm: "EC-256")
        XCTAssertEqual(
            WebHostTrustEvaluator.evaluate(systemTrusted: false, recorded: recorded, presentedFingerprint: "fp"),
            .acceptPinned
        )
    }

    func testEvaluatePinnedMismatchPrompts() {
        let recorded = HostTrust.pinned(fingerprintSHA256: "old", algorithm: "EC-256")
        XCTAssertEqual(
            WebHostTrustEvaluator.evaluate(systemTrusted: false, recorded: recorded, presentedFingerprint: "new"),
            .promptMismatch(recordedFingerprint: "old", recordedAlgorithm: "EC-256")
        )
    }

    func testEvaluateExplicitDistrustWinsOverSystemTrust() {
        let recorded = HostTrust.explicitlyDistrusted(reason: "blocked", recordedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            WebHostTrustEvaluator.evaluate(systemTrusted: true, recorded: recorded, presentedFingerprint: "fp"),
            .rejectDistrusted(reason: "blocked")
        )
    }

    // MARK: - TLSCertificateInspector

    func testLeafFingerprintMatchesIndependentSHA256() throws {
        // Self-signed EC P-256 certificate generated with OpenSSL; the expected
        // fingerprint was computed independently (openssl x509 ... | dgst -sha256).
        let certBase64 = "MIIBhzCCAS2gAwIBAgIUar34XGDNU+D3SStIueriC6KP6IQwCgYIKoZIzj0EAwIwGTEXMBUGA1UEAwwOcHVsc2Utd2ViLXRlc3QwHhcNMjYwNjAzMDM1NDMwWhcNMjYwNjA1MDM1NDMwWjAZMRcwFQYDVQQDDA5wdWxzZS13ZWItdGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABO3M+d3KZT7KgVnyfbcsoOSSrDHGLwBb03M0NAEwZo9xJ1cfDlGmrttEO3IV+3aMahWyZ3l77b0KoL/LZ3szEp2jUzBRMB0GA1UdDgQWBBT6PTaJxHsbaROvJh1wP+okRmuTZDAfBgNVHSMEGDAWgBT6PTaJxHsbaROvJh1wP+okRmuTZDAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIDNWedLvRvkPtoUMFeXMUqD2jJAI7poOLnhLgHi3rZdWAiEAqhUU4FZZF3S4pzxIN1W395VdTnjgYPQeeJVkjBcNVF8="
        let der = try XCTUnwrap(Data(base64Encoded: certBase64))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))

        let (sha256, algorithm) = TLSCertificateInspector.fingerprint(of: certificate)
        XCTAssertEqual(sha256, "SHA256:4HXFrcCA2cRVY3z4RHSjAe6jT31SdGmA7uR4Y7i0LRc")
        XCTAssertTrue(algorithm.hasPrefix("EC"), "expected an EC key label, got \(algorithm)")
    }

    // MARK: - SwiftDataWebHostTrustStore

    func testStorePinIsIdempotentAndForgettable() async throws {
        let schema = Schema([WebHostTrust.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = SwiftDataWebHostTrustStore(modelContainer: container)

        try await store.recordPinned(host: "10.0.0.1", port: 8006, fingerprintSHA256: "fp1", algorithm: "EC-256")
        // Idempotent: a second record for the same host:port does not add a row
        // and leaves the original policy intact.
        try await store.recordPinned(host: "10.0.0.1", port: 8006, fingerprintSHA256: "fp-ignored", algorithm: "EC-256")

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WebHostTrust>()).count, 1)
        let trust = try await store.trust(forHost: "10.0.0.1", port: 8006)
        XCTAssertEqual(trust, .pinned(fingerprintSHA256: "fp1", algorithm: "EC-256"))

        // replacePin swaps the pinned fingerprint (operator accepted a rotation).
        try await store.replacePin(host: "10.0.0.1", port: 8006, fingerprintSHA256: "fp2", algorithm: "EC-256")
        let replaced = try await store.trust(forHost: "10.0.0.1", port: 8006)
        XCTAssertEqual(replaced, .pinned(fingerprintSHA256: "fp2", algorithm: "EC-256"))

        // forget removes the row; the next connection is a fresh first-sight.
        try await store.forget(host: "10.0.0.1", port: 8006)
        let after = try await store.trust(forHost: "10.0.0.1", port: 8006)
        XCTAssertNil(after)
    }
}
