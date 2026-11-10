//
//  ReferenceWebView.swift
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

import OSLog
import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One description link, in a page that keeps no website data and trusts
/// only the system certificate check. The window title is the host.
struct ReferenceWebView: View {
    let url: URL

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: WebPage?
    @State private var decider: ReferenceWebNavigationDecider?
    @State private var loadFailure: String?
    @State private var handedOff: URL?
    @State private var reloadID = 0

    private var host: String {
        let shown = handedOff ?? page?.url ?? url
        return WebOrigin(url: shown)?.host ?? "Reference"
    }

    private var phase: String {
        if handedOff != nil { return "browser" }
        if loadFailure != nil { return "failed" }
        if page != nil { return "page" }
        return "loading"
    }

    private var contentMotion: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.35)
    }

    var body: some View {
        content
            .animation(contentMotion, value: phase)
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 480)
            #endif
            .navigationTitle(host)
            .navigationSubtitle(failureSubtitle)
            .toolbar { referenceToolbar }
            .task(id: reloadID) { await runLoad() }
    }

    /// "Failed" belongs with the window title. A toolbar item in the
    /// navigation slot is laid out in the traffic-light well, and a bare
    /// text there gets a glass pill with no inset.
    private var failureSubtitle: Text {
        guard loadFailure != nil else { return Text(verbatim: "") }
        var line = AttributedString("Failed")
        line.foregroundColor = .red
        return Text(line)
    }

    @ViewBuilder
    private var content: some View {
        if let handedOff {
            ContentUnavailableView {
                Label("Opened in Browser", systemImage: "safari")
            } description: {
                VStack(spacing: 8) {
                    Text("This address opened in the system browser.")
                    Text(handedOff.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else if let loadFailure {
            ContentUnavailableView {
                Label("Could not load", systemImage: "exclamationmark.triangle")
            } description: {
                VStack(spacing: 8) {
                    Text(loadFailure)
                    Text(url.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else if let page {
            WebView(page)
                .transition(.opacity)
        } else {
            ProgressView()
                .controlSize(.large)
        }
    }

    private var isLoading: Bool {
        page?.isLoading == true && loadFailure == nil && handedOff == nil
    }

    @ToolbarContentBuilder
    private var referenceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isLoading {
                // A bare progress view is not a toolbar control, so the
                // glass capsule clips its leading edge. A button slot
                // gives it the same inset as the icons.
                Button(action: {}) {
                    ProgressView()
                        .controlSize(.small)
                }
                .disabled(true)
                .accessibilityLabel("Loading")
                .help("Loading")
            }
            Button("Reload", systemImage: "arrow.clockwise", action: reload)
                .disabled(page == nil)
            Button("Open in Browser", systemImage: "safari", action: openInBrowser)
                .disabled(!WebOrigin.isBrowserOpenable(browserURL))
        }
    }

    private var browserURL: URL {
        handedOff ?? page?.url ?? url
    }

    private func runLoad() async {
        if page == nil {
            await setUp()
        } else if let page {
            await follow(page.reload())
        }
    }

    private func setUp() async {
        guard page == nil else { return }
        guard WebOrigin.isBrowserOpenable(url), let origin = WebOrigin(url: url) else {
            loadFailure = "This address cannot be opened in Reference."
            return
        }

        let navigationDecider = ReferenceWebNavigationDecider(origin: origin)
        let newPage = WebPage(
            configuration: ReferenceWebConfiguration.make(),
            navigationDecider: navigationDecider
        )
        decider = navigationDecider
        page = newPage
        Logger(subsystem: "pulse", category: "web.reference")
            .info("web.reference.open host=\(origin.host, privacy: .public)")
        await follow(newPage.load(URLRequest(url: url)))
    }

    private func follow<Events: AsyncSequence>(
        _ events: Events
    ) async where Events.Element == WebPage.NavigationEvent {
        let generation = reloadID
        do {
            for try await event in events {
                guard generation == reloadID else { return }
                loadFailure = nil
                handedOff = nil
                if event == .committed {
                    decider?.noteCommitted()
                }
            }
        } catch {
            guard generation == reloadID else { return }
            if error is CancellationError { return }
            let outcome = ReferenceLoadOutcome.resolve(
                committed: decider?.hasCommitted ?? false,
                handedOff: decider?.handedOffURL,
                error: error
            )
            switch outcome {
            case .keepPage:
                break
            case .openedInBrowser(let opened):
                handedOff = opened
            case .failed(let message):
                let nsError = error as NSError
                Logger(subsystem: "pulse", category: "web.reference")
                    .error("web.reference.load_failed host=\(self.host, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
                loadFailure = message
            }
        }
    }

    private func reload() {
        loadFailure = nil
        handedOff = nil
        decider?.prepareForReload()
        reloadID += 1
    }

    private func openInBrowser() {
        let opening = browserURL
        guard WebOrigin.isBrowserOpenable(opening) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(opening)
        #else
        Task { await UIApplication.shared.open(opening) }
        #endif
    }
}
