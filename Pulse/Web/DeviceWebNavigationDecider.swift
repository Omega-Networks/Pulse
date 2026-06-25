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
import OSLog
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

    /// Whether a foreign-origin URL is safe to hand to the system browser: http
    /// or https with a host. Everything else (file:, ssh:, vnc:,
    /// x-apple.systempreferences:, custom app schemes) must never reach the OS
    /// opener from device-controlled content. Pure so the allowlist is tested.
    static func isBrowserOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host() != nil
    }
}

// MARK: - Device web navigation decider

/// Drives the two policy decisions for a device's web window: keeping navigation
/// contained to the device's origin, and accepting an otherwise-untrusted TLS
/// certificate through the TLS trust foundation.
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
    private let logger = Logger(subsystem: "pulse", category: "web.trust")

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
        let allowed = origin.allows(url)
        logger.debug("web.nav.decide host=\(url.host() ?? "nil", privacy: .public) allowed=\(allowed)")
        if allowed {
            return .allow
        }
        // Foreign origin. Hand only http/https links with a real host to the
        // system browser; never pass an arbitrary scheme (file:, ssh:, vnc:,
        // x-apple.systempreferences:, custom app schemes) to the OS opener, so
        // device-controlled page content cannot launch arbitrary apps on the
        // operator's Mac. Everything else is dropped and recorded by the audit.
        if WebOrigin.isBrowserOpenable(url) {
            await openInSystemBrowser(url)
        }
        WebAudit.navigationBlocked(host: origin.host, toURL: url.absoluteString)
        return .cancel
    }

    // MARK: Server-trust challenge

    func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        logger.notice("web.trust.challenge host=\(space.host, privacy: .public) port=\(space.port, privacy: .public) method=\(space.authenticationMethod, privacy: .public)")
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = space.serverTrust else {
            // Non-server-trust challenge (basic, digest, client cert). Pulse does
            // not collect web credentials in v1.5; let the system handle it.
            logger.notice("web.trust.challenge.not_server_trust method=\(space.authenticationMethod, privacy: .public)")
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
            logger.error("web.trust.fingerprint_unavailable host=\(host, privacy: .public)")
            return (.cancelAuthenticationChallenge, nil)
        }

        logger.notice("web.trust.evaluate host=\(host, privacy: .public) systemTrusted=\(systemTrusted) fp=\(fingerprint, privacy: .public)")

        // Fail closed on a store read error: a SwiftData fault must not read as
        // "no record", which would let an explicitly-distrusted host be
        // re-trusted. Cancel the challenge and emit a distinct audit event;
        // retry is cheap, silently re-trusting a distrusted host is not.
        let recorded: HostTrust?
        do {
            recorded = try await store.trust(forHost: host, port: port)
        } catch {
            logger.error("web.trust.store_error host=\(host, privacy: .public) port=\(port, privacy: .public)")
            WebAudit.storeError(host: host, port: port)
            return (.cancelAuthenticationChallenge, nil)
        }

        let decision = WebHostTrustEvaluator.evaluate(
            systemTrusted: systemTrusted,
            recorded: recorded,
            presentedFingerprint: fingerprint
        )

        // Only the window's own origin may raise an operator trust prompt. A
        // subresource load to a foreign host:port must not prompt for arbitrary
        // third-party certificates (prompt fatigue / social engineering). A
        // system-trusted or already-pinned foreign resource still loads; an
        // untrusted one is dropped without a prompt.
        let isOwnOrigin = host.lowercased() == origin.host && port == origin.port

        switch decision {
        case .acceptSystemTrusted:
            WebAudit.systemTrusted(host: host, port: port)
            return (.performDefaultHandling, nil)

        case .acceptPinned:
            try? await store.touchLastVerified(forHost: host, port: port)
            return (.useCredential, operatorAcceptedCredential(for: serverTrust))

        case .promptFirstSight:
            guard isOwnOrigin else {
                WebAudit.foreignChallengeSuppressed(host: host, port: port)
                return (.cancelAuthenticationChallenge, nil)
            }
            let outcome = await coordinator.decide(
                host: host,
                port: port,
                scheme: origin.scheme,
                reason: "self-signed or untrusted certificate",
                presentedFingerprint: fingerprint,
                presentedAlgorithm: algorithm
            )
            logger.notice("web.trust.first_sight_outcome host=\(host, privacy: .public) accepted=\(outcome == .accept)")
            guard case .accept = outcome else {
                WebAudit.rejected(host: host, port: port, reason: Self.rejectReason(outcome))
                return (.cancelAuthenticationChallenge, nil)
            }
            // Honour the one-time accept even if persisting the pin fails: the
            // operator approved this exact certificate and the credential is
            // scoped to it. Emit commit_failed (not pinned) so the audit trail
            // never overstates what persisted. See ADR 0001 Slice W2b.
            do {
                try await store.recordPinned(host: host, port: port, fingerprintSHA256: fingerprint, algorithm: algorithm)
                WebAudit.pinned(host: host, port: port, fingerprint: fingerprint)
                // Reload only now that the pin is durable, so the reloaded page
                // reads it back and loads silently (acceptPinned) instead of
                // racing the write and re-prompting in a loop.
                coordinator.notePinCommitted()
            } catch {
                WebAudit.commitFailed(host: host, port: port, fingerprint: fingerprint)
            }
            return (.useCredential, operatorAcceptedCredential(for: serverTrust))

        case let .promptMismatch(recordedFingerprint, recordedAlgorithm):
            guard isOwnOrigin else {
                WebAudit.foreignChallengeSuppressed(host: host, port: port)
                return (.cancelAuthenticationChallenge, nil)
            }
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
                do {
                    try await store.replacePin(host: host, port: port, fingerprintSHA256: fingerprint, algorithm: algorithm)
                    WebAudit.accepted(host: host, port: port, fingerprint: fingerprint)
                    // Reload only after the rotated pin is durable. See first-sight note.
                    coordinator.notePinCommitted()
                } catch {
                    WebAudit.commitFailed(host: host, port: port, fingerprint: fingerprint)
                }
                return (.useCredential, operatorAcceptedCredential(for: serverTrust))
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

    /// Credential for a certificate the operator has explicitly accepted (pinned
    /// by SHA-256 fingerprint, or a fresh first-sight / rotation accept). Capturing
    /// a trust exception and attaching it makes WebKit honour that decision fully:
    /// without it the navigation can still fail with `-1202` over an IP/hostname
    /// mismatch even though we return `.useCredential`, because appliances are
    /// reached by bare IP and rarely carry that IP in the certificate SAN. The
    /// exact-fingerprint pin we verify is a stronger guarantee than name matching,
    /// so overriding the name policy for an operator-accepted cert is sound. A
    /// hard failure (for example a deprecated key/algorithm WebKit refuses) is not
    /// overridable this way and remains a server-side fix.
    private func operatorAcceptedCredential(for trust: SecTrust) -> URLCredential {
        if let exceptions = SecTrustCopyExceptions(trust) {
            _ = SecTrustSetExceptions(trust, exceptions)
        }
        return URLCredential(trust: trust)
    }

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
