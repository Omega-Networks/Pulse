//
//  ReferenceWebNavigationDecider.swift
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
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where a reference-window navigation goes. Pure, so the policy is tested
/// without opening a browser or a page.
enum ReferenceNavigation: Equatable {
    case allow
    /// The address redirected before the page committed. Stay in the window
    /// and hold this origin from here on.
    case adopt(WebOrigin)
    case openInBrowser
    case cancel

    /// Same origin stays. A redirect before the first commit to another http
    /// or https host is followed. After that, other http and https go to the
    /// system browser. Everything else is cancelled.
    static func decision(
        origin: WebOrigin,
        url: URL?,
        followsRedirect: Bool = false
    ) -> ReferenceNavigation {
        guard let url else { return .cancel }
        if origin.allows(url) { return .allow }
        if followsRedirect, let next = WebOrigin(url: url), WebOrigin.isBrowserOpenable(url) {
            return .adopt(next)
        }
        if WebOrigin.isBrowserOpenable(url) { return .openInBrowser }
        return .cancel
    }
}

/// What a thrown reference load means. Opening the system browser cancels
/// the provisional load, and that cancel is not a page failure.
enum ReferenceLoadOutcome: Equatable {
    case keepPage
    case openedInBrowser(URL)
    case failed(String)

    static func resolve(committed: Bool, handedOff: URL?, error: Error) -> ReferenceLoadOutcome {
        if let handedOff {
            return committed ? .keepPage : .openedInBrowser(handedOff)
        }
        let nsError = error as NSError
        return .failed("\(nsError.localizedDescription)\n\(nsError.domain) \(nsError.code)")
    }
}

/// A `WebPage` configuration whose website data is not written to disk.
/// Checked on the macOS 26 SDK: `WebPage.Configuration.websiteDataStore`
/// accepts `WKWebsiteDataStore.nonPersistent()`.
enum ReferenceWebConfiguration {
    @MainActor
    static func make() -> WebPage.Configuration {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        return configuration
    }
}

/// Keeps a reference page on the origin it was opened for.
/// Certificate checks are the system's. This type never reads or writes
/// `WebHostTrust`, and it never raises a trust prompt.
@MainActor
final class ReferenceWebNavigationDecider: WebPage.NavigationDeciding {
    private(set) var origin: WebOrigin
    private(set) var hasCommitted = false
    /// Set when the main frame is handed to the system browser. The load
    /// then throws, and the window shows that handoff instead of a failure.
    private(set) var handedOffURL: URL?
    private let logger = Logger(subsystem: "pulse", category: "web.reference")

    init(origin: WebOrigin) {
        self.origin = origin
    }

    func noteCommitted() {
        hasCommitted = true
    }

    func prepareForReload() {
        hasCommitted = false
        handedOffURL = nil
    }

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        let url = action.request.url
        let mainFrame = action.target?.isMainFrame ?? action.source.isMainFrame
        let followsRedirect = !hasCommitted && mainFrame && action.navigationType != .linkActivated
        let decision = ReferenceNavigation.decision(origin: origin, url: url, followsRedirect: followsRedirect)
        if let url {
            logger.debug("web.reference.nav host=\(url.host() ?? "", privacy: .public) path=\(url.path, privacy: .private) query=\(url.query ?? "", privacy: .private) type=\(action.navigationType.rawValue) decision=\(decision.label, privacy: .public)")
        }
        switch decision {
        case .allow:
            handedOffURL = nil
            return .allow
        case .adopt(let next):
            logger.notice("web.reference.adopt from=\(self.origin.host, privacy: .public) host=\(next.host, privacy: .public)")
            origin = next
            handedOffURL = nil
            return .allow
        case .openInBrowser:
            if mainFrame, let url {
                handedOffURL = url
            }
            if let url {
                await openInSystemBrowser(url)
            }
            return .cancel
        case .cancel:
            return .cancel
        }
    }

    /// System validation only. A failed certificate becomes a load failure
    /// in the window. There is no pin and no prompt.
    func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        logger.notice("web.reference.trust host=\(space.host, privacy: .public) method=\(space.authenticationMethod, privacy: .public)")
        return (.performDefaultHandling, nil)
    }

    private func openInSystemBrowser(_ url: URL) async {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        await UIApplication.shared.open(url)
        #endif
    }
}

private extension ReferenceNavigation {
    var label: String {
        switch self {
        case .allow: return "allow"
        case .adopt: return "adopt"
        case .openInBrowser: return "browser"
        case .cancel: return "cancel"
        }
    }
}
