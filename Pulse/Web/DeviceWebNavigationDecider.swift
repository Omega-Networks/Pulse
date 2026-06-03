//
//  DeviceWebNavigationDecider.swift
//  Pulse
//
//  Copyright © 2025-present Omega Networks Limited.
//
//  Pulse
//  The Platform for Unified Leadership in Smart Environments.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  This program is free software: communities can deploy it for sovereignty, academia can
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import Security
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Web origin

/// A scheme + host + port tuple used to keep in-app navigation contained to the
/// device the window was opened for. Pure and unit-testable.
struct WebOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    /// Derives an origin from a URL, defaulting the port from the scheme when the
    /// URL omits it. Returns nil for a URL without a scheme or host.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else {
            return nil
        }
        self.init(scheme: scheme, host: host, port: url.port ?? (scheme == "https" ? 443 : 80))
    }

    /// Same-origin per scheme, host, and port. In-app navigation to a same-origin
    /// URL is allowed; anything else is routed to the system browser.
    func allows(_ url: URL) -> Bool {
        guard let other = WebOrigin(url: url) else { return false }
        return other == self
    }
}

// MARK: - Device web navigation decider

/// Drives the two policy decisions for a device's web window: keeping navigation
/// contained to the device's origin, and accepting an otherwise-untrusted TLS
/// certificate through the W2a trust foundation.
///
/// A `final class` (not a struct) because `WebPage.NavigationDeciding`'s methods
/// are `@MainActor mutating`: a class satisfies the `mutating` requirement
/// trivially and lets the decider hold references to the MainActor trust
/// coordinator and the trust store for the window's lifetime.
@MainActor
final class DeviceWebNavigationDecider: WebPage.NavigationDeciding {

    let origin: WebOrigin
    private let coordinator: TLSTrustCoordinator
    private let store: any WebHostTrustStore

    init(origin: WebOrigin, coordinator: TLSTrustCoordinator, store: any WebHostTrustStore) {
        self.origin = origin
        self.coordinator = coordinator
        self.store = store
    }

    // MARK: Origin containment

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if origin.allows(url) {
            return .allow
        }
        // Foreign origin: keep the in-app view pinned to this device and hand the
        // link to the system browser rather than navigating away inside Pulse.
        await openInSystemBrowser(url)
        WebAudit.navigationBlocked(host: origin.host, toURL: url.absoluteString)
        return .cancel
    }

    // MARK: Server-trust challenge

    func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = space.serverTrust else {
            // Non-server-trust challenge (basic, digest, client cert). Pulse does
            // not collect web credentials in v1.5; let the system handle it.
            return (.performDefaultHandling, nil)
        }

        let host = space.host
        let port = space.port

        // Standard validation first: a certificate that chains to a trusted root
        // needs no operator prompt.
        var trustError: CFError?
        let systemTrusted = SecTrustEvaluateWithError(serverTrust, &trustError)

        guard let (fingerprint, algorithm) = TLSCertificateInspector.leafFingerprint(of: serverTrust) else {
            // Unreadable certificate chain: refuse rather than guess.
            return (.cancelAuthenticationChallenge, nil)
        }

        let recorded = try? await store.trust(forHost: host, port: port)
        let decision = WebHostTrustEvaluator.evaluate(
            systemTrusted: systemTrusted,
            recorded: recorded,
            presentedFingerprint: fingerprint
        )

        switch decision {
        case .acceptSystemTrusted:
            WebAudit.systemTrusted(host: host, port: port)
            return (.performDefaultHandling, nil)

        case .acceptPinned:
            try? await store.touchLastVerified(forHost: host, port: port)
            return (.useCredential, URLCredential(trust: serverTrust))

        case .promptFirstSight:
            let outcome = await coordinator.decide(
                host: host,
                port: port,
                scheme: origin.scheme,
                reason: "self-signed or untrusted certificate",
                presentedFingerprint: fingerprint,
                presentedAlgorithm: algorithm
            )
            if case .accept = outcome {
                try? await store.recordPinned(host: host, port: port, fingerprintSHA256: fingerprint, algorithm: algorithm)
                WebAudit.pinned(host: host, port: port, fingerprint: fingerprint)
                return (.useCredential, URLCredential(trust: serverTrust))
            }
            WebAudit.rejected(host: host, port: port, reason: Self.rejectReason(outcome))
            return (.cancelAuthenticationChallenge, nil)

        case let .promptMismatch(recordedFingerprint, recordedAlgorithm):
            let firstSeen = try? await store.firstSeenAt(forHost: host, port: port)
            let outcome = await coordinator.decide(
                host: host,
                port: port,
                scheme: origin.scheme,
                reason: "changed certificate",
                presentedFingerprint: fingerprint,
                presentedAlgorithm: algorithm,
                recordedFingerprint: recordedFingerprint,
                recordedAlgorithm: recordedAlgorithm,
                recordedFirstSeenAt: firstSeen
            )
            switch outcome {
            case .accept:
                try? await store.replacePin(host: host, port: port, fingerprintSHA256: fingerprint, algorithm: algorithm)
                WebAudit.accepted(host: host, port: port, fingerprint: fingerprint)
                return (.useCredential, URLCredential(trust: serverTrust))
            case .forget:
                try? await store.forget(host: host, port: port)
                WebAudit.forgotten(host: host, port: port)
                return (.cancelAuthenticationChallenge, nil)
            case let .reject(reason):
                WebAudit.rejected(host: host, port: port, reason: reason)
                return (.cancelAuthenticationChallenge, nil)
            }

        case let .rejectDistrusted(reason):
            WebAudit.rejected(host: host, port: port, reason: reason)
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - Helpers

    private static func rejectReason(_ outcome: TLSTrustDecision) -> String? {
        if case let .reject(reason) = outcome { return reason }
        return nil
    }

    private func openInSystemBrowser(_ url: URL) async {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        await UIApplication.shared.open(url)
        #endif
    }
}
