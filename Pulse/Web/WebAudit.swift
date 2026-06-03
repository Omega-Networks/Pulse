//
//  WebAudit.swift
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

// MARK: - WebAudit

/// Typed emitter for the device-web audit surface, mirroring `CredentialAudit`:
/// a typed `Event`, a single `emit` chokepoint, and a leading token that is the
/// SIEM contract. Owns the `web.trust.*` and `web.session.*` namespaces. The
/// navigation decider routes its TLS-trust decisions and origin-containment
/// outcomes through here so every web token is defined in one greppable place.
enum WebAudit {

    enum Event: Sendable, Equatable {

        // MARK: Trust (category: web.trust)

        /// The certificate chained to a trusted root and loaded with no prompt.
        case systemTrusted(host: String, port: Int)
        /// An untrusted certificate was trusted on first sight and pinned.
        case pinned(host: String, port: Int, fingerprint: String)
        /// A changed certificate was accepted (re-pinned) by the operator.
        case accepted(host: String, port: Int, fingerprint: String)
        /// A trust prompt was rejected. `reason` distinguishes an operator
        /// reject (nil) from `decision_timeout` / `cancelled`, or an explicit
        /// distrust reason.
        case rejected(host: String, port: Int, reason: String?)
        /// An operator forgot a pin; the next connection is a fresh first sight.
        case forgotten(host: String, port: Int)

        /// A SwiftData read of the trust store failed during challenge
        /// evaluation. The challenge is cancelled (fail closed), never treated
        /// as "no record".
        case storeError(host: String, port: Int)
        /// The operator accepted a certificate but persisting the pin failed.
        /// The session proceeds on the one-time credential; the pin is not saved.
        case commitFailed(host: String, port: Int, fingerprint: String)
        /// A trust prompt was suppressed for a subresource load to a foreign
        /// origin: only the window's own origin may raise a prompt.
        case foreignChallengeSuppressed(host: String, port: Int)

        // MARK: Session (category: web.session)

        /// A device web window opened against a resolved service target.
        case opened(host: String, port: Int, service: String)
        /// In-app navigation to a foreign origin was blocked and handed to the
        /// system browser.
        case navigationBlocked(host: String, toURL: String)
    }

    private static let trustLogger = Logger(subsystem: "pulse", category: "web.trust")
    private static let sessionLogger = Logger(subsystem: "pulse", category: "web.session")

    static func emit(_ event: Event) {
        switch event {
        case let .systemTrusted(host, port):
            trustLogger.notice("web.trust.system host=\(host, privacy: .public) port=\(port, privacy: .public)")
        case let .pinned(host, port, fingerprint):
            trustLogger.notice("web.trust.pinned host=\(host, privacy: .public) port=\(port, privacy: .public) fp=\(fingerprint, privacy: .public)")
        case let .accepted(host, port, fingerprint):
            trustLogger.warning("web.trust.accepted host=\(host, privacy: .public) port=\(port, privacy: .public) fp=\(fingerprint, privacy: .public)")
        case let .rejected(host, port, reason):
            trustLogger.warning("web.trust.rejected host=\(host, privacy: .public) port=\(port, privacy: .public) reason=\(reason ?? "operator", privacy: .public)")
        case let .forgotten(host, port):
            trustLogger.warning("web.trust.forgotten host=\(host, privacy: .public) port=\(port, privacy: .public)")
        case let .opened(host, port, service):
            sessionLogger.notice("web.session.opened host=\(host, privacy: .public) port=\(port, privacy: .public) service=\(service, privacy: .public)")
        case let .navigationBlocked(host, toURL):
            sessionLogger.notice("web.session.navigation_blocked host=\(host, privacy: .public) to=\(toURL, privacy: .public)")
        case let .storeError(host, port):
            trustLogger.error("web.trust.store_error host=\(host, privacy: .public) port=\(port, privacy: .public)")
        case let .commitFailed(host, port, fingerprint):
            trustLogger.error("web.trust.commit_failed host=\(host, privacy: .public) port=\(port, privacy: .public) fp=\(fingerprint, privacy: .public)")
        case let .foreignChallengeSuppressed(host, port):
            trustLogger.notice("web.trust.foreign_suppressed host=\(host, privacy: .public) port=\(port, privacy: .public)")
        }
    }
}

// MARK: - Convenience emitters

extension WebAudit {
    static func systemTrusted(host: String, port: Int) { emit(.systemTrusted(host: host, port: port)) }
    static func pinned(host: String, port: Int, fingerprint: String) { emit(.pinned(host: host, port: port, fingerprint: fingerprint)) }
    static func accepted(host: String, port: Int, fingerprint: String) { emit(.accepted(host: host, port: port, fingerprint: fingerprint)) }
    static func rejected(host: String, port: Int, reason: String?) { emit(.rejected(host: host, port: port, reason: reason)) }
    static func forgotten(host: String, port: Int) { emit(.forgotten(host: host, port: port)) }
    static func opened(host: String, port: Int, service: String) { emit(.opened(host: host, port: port, service: service)) }
    static func navigationBlocked(host: String, toURL: String) { emit(.navigationBlocked(host: host, toURL: toURL)) }
    static func storeError(host: String, port: Int) { emit(.storeError(host: host, port: port)) }
    static func commitFailed(host: String, port: Int, fingerprint: String) { emit(.commitFailed(host: host, port: port, fingerprint: fingerprint)) }
    static func foreignChallengeSuppressed(host: String, port: Int) { emit(.foreignChallengeSuppressed(host: host, port: port)) }
}
