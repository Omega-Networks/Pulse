//
//  ProblemDetailPopover.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import SwiftUI

/// The problem name, and a details button when operational data or the
/// trigger description is stored. The button uses the same spring as the
/// problem squares. Reduce Motion holds it still. The table is not animated.
struct ProblemDetailButton: View {
    var name: String
    var opData: String
    var descriptionText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var presented = false
    #if os(iOS)
    /// The webpage sheet for an iPad popover. It stays on this button,
    /// which remains after the popover closes.
    @State private var referenceLink: ReferenceLink?
    #endif

    private var hasDetail: Bool {
        !opData.isEmpty || !descriptionText.isEmpty
    }

    private var detailMotion: Animation? {
        reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.32)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name)
            if hasDetail {
                presentedDetail
            }
        }
        .animation(detailMotion, value: hasDetail)
    }

    /// iPad is wide enough for the popover. A compact width is not:
    /// the popover's 480-point text is clipped on iPhone.
    private var phoneSheet: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder
    private var presentedDetail: some View {
        #if os(iOS)
        if phoneSheet {
            detailButton.sheet(isPresented: $presented) {
                ProblemDetailPopover(
                    opData: opData,
                    descriptionText: descriptionText,
                    phoneSheet: true
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        } else {
            popoverDetail
        }
        #else
        popoverDetail
        #endif
    }

    private var popoverDetail: some View {
        detailButton
            .popover(isPresented: $presented) {
                ProblemDetailPopover(
                    opData: opData,
                    descriptionText: descriptionText,
                    onOpenLink: openReferenceSheet
                )
            }
            #if os(iOS)
            .sheet(item: $referenceLink) { link in
                NavigationStack {
                    ReferenceWebView(url: link.url)
                }
            }
            #endif
    }

    /// Presents the webpage after the link gesture. A sheet presented in
    /// that turn is cancelled, and iPhone then opens Safari.
    private func openReferenceSheet(_ url: URL) {
        #if os(iOS)
        Task { @MainActor in
            referenceLink = ReferenceLink(url: url)
        }
        #endif
    }

    private var detailButton: some View {
        Button("Problem details", systemImage: "text.bubble", action: toggleDetails)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .pointingHand()
            .help("Problem details")
            .transition(.scale(0.86).combined(with: .opacity))
    }

    private func toggleDetails() {
        presented.toggle()
    }
}

/// Operational data, then the trigger description as Zabbix returned it.
/// On macOS a link opens the Reference window. On iPhone the webpage is a
/// sheet above this one. On iPad the button that owns the popover presents
/// that sheet, so it survives the popover closing.
/// Mac and iPad use the fixed-width popover. iPhone uses the sheet width.
private struct ProblemDetailPopover: View {
    var opData: String
    var descriptionText: String
    var phoneSheet: Bool = false
    var onOpenLink: ((URL) -> Void)? = nil

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    #if os(iOS)
    @State private var referenceLink: ReferenceLink?
    #endif

    /// Wrapped height of the text. The table cell proposes one line, so a
    /// max width still truncates. This width wraps; the popover then takes
    /// this height until the cap, and scrolls past it.
    @State private var contentHeight: CGFloat = 0

    private var shownHeight: CGFloat? {
        guard contentHeight > 0 else { return nil }
        return min(contentHeight, 360)
    }

    var body: some View {
        Group {
            if phoneSheet {
                detailText
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    detailText
                        .frame(width: 480, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { newHeight in
                            contentHeight = newHeight
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 480, height: shownHeight, alignment: .top)
            }
        }
        #if os(iOS)
        .sheet(item: $referenceLink) { link in
            NavigationStack {
                ReferenceWebView(url: link.url)
            }
        }
        #endif
    }

    private var detailText: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !opData.isEmpty {
                Text(opData)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !descriptionText.isEmpty {
                description
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .lineLimit(nil)
        .padding(16)
    }

    @ViewBuilder
    private var description: some View {
        let text = Text(descriptionText.linkified())
            .font(.body)
            .textSelection(.enabled)
        text.environment(\.openURL, OpenURLAction(handler: openReference))
    }

    private func openReference(_ url: URL) -> OpenURLAction.Result {
        guard WebOrigin.isBrowserOpenable(url) else { return .discarded }
        #if os(macOS)
        openWindow(id: "reference-web", value: ReferenceWebWindowTarget(url: url))
        #else
        if phoneSheet {
            Task { @MainActor in
                referenceLink = ReferenceLink(url: url)
            }
        } else {
            onOpenLink?(url)
        }
        #endif
        return .handled
    }
}

#if os(iOS)
private struct ReferenceLink: Identifiable {
    let url: URL
    var id: URL { url }
}
#endif
