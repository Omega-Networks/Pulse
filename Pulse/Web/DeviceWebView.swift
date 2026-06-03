//
//  DeviceWebView.swift
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
import SwiftData
import SwiftUI
import WebKit

// MARK: - Web load status

/// Coarse load state for the toolbar, derived from the `@Observable` `WebPage`
/// plus any thrown navigation error. Pure mapping so it is unit-testable without
/// rendering or a live page.
enum WebLoadStatus: Equatable {
    case loading
    case loaded
    case failed(String)

    static func resolve(isLoading: Bool, failure: String?) -> WebLoadStatus {
        if let failure { return .failed(failure) }
        return isLoading ? .loading : .loaded
    }

    var label: String {
        switch self {
        case .loading: return "Loading"
        case .loaded: return "Loaded"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Device web view

/// Operator-facing window that renders a device's web UI, mirroring
/// `SSHTerminalView`. The web target is resolved from the device's NetBox
/// services (`WebServiceResolver`); the page is driven by a `WebPage` whose
/// navigation decider contains navigation to the device origin and routes the
/// self-signed-TLS trust decision through the TLS trust coordinator.
struct DeviceWebView: View {

    let deviceID: Device.ID

    @Query private var devices: [Device]
    @Environment(\.modelContext) private var modelContext

    @StateObject private var trustCoordinator = TLSTrustCoordinator()

    /// `WebPage` is `@Observable`; held in `@State` and built once in `.task`.
    @State private var page: WebPage?
    /// Retains the decider for the page's lifetime (`WebPage` does not expose it
    /// back to us).
    @State private var decider: DeviceWebNavigationDecider?
    @State private var loadFailure: String?

    init(deviceID: Device.ID) {
        self.deviceID = deviceID
        _devices = Query(filter: #Predicate<Device> { $0.id == deviceID })
    }

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 480)
            .navigationTitle(navigationTitle)
            .toolbar { webToolbar }
            .task { await setUp() }
            .sheet(item: $trustCoordinator.pending) { pending in
                TLSTrustPromptSheet(pending: pending)
                    // The sheet's buttons are the only legitimate exits. A swipe
                    // or stray Esc would nil `pending` without resuming the
                    // continuation, stranding the challenge until the 90s timeout
                    // and opening the concurrent-decide path. Mirrors the SSH
                    // host-key sheet.
                    .interactiveDismissDisabled()
            }
            .onChange(of: trustCoordinator.acceptTick) {
                // The operator accepted a certificate; reload so the page
                // connects with the now-pinned cert and the error view clears.
                loadFailure = nil
                _ = page?.reload()
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let page {
            VStack(spacing: 0) {
                if let loadFailure {
                    ContentUnavailableView {
                        Label("Could not load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadFailure)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .textSelection(.enabled)
                } else {
                    WebView(page)
                }
                endpointStrip
            }
        } else if devices.first == nil {
            ContentUnavailableView("Device not found", systemImage: "questionmark.circle")
        } else if webTarget == nil {
            ContentUnavailableView {
                Label("No web service", systemImage: "globe.badge.chevron.backward")
            } description: {
                Text("This device has no HTTP or HTTPS service defined in NetBox. Define one in NetBox to open its web UI.")
            }
        } else {
            ProgressView().controlSize(.large)
        }
    }

    @ViewBuilder
    private var endpointStrip: some View {
        if let target = webTarget {
            HStack {
                Text(page?.url?.absoluteString ?? target.url.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Current address")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var webToolbar: some ToolbarContent {
        ToolbarItem(id: "web-back", placement: .navigation) {
            Button {
                goBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(!canGoBack)
        }

        ToolbarItem(id: "web-forward", placement: .navigation) {
            Button {
                goForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .disabled(!canGoForward)
        }

        ToolbarItem(id: "web-progress", placement: .navigation) {
            if let page {
                if page.isLoading {
                    ProgressView(value: page.estimatedProgress)
                        .frame(width: 120)
                } else {
                    let status = WebLoadStatus.resolve(isLoading: false, failure: loadFailure)
                    if case .failed = status {
                        Text(status.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                }
            }
        }

        ToolbarItem(id: "web-reload", placement: .primaryAction) {
            Button {
                reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(page == nil)
        }
    }

    // MARK: - Derived state

    private var webTarget: WebTarget? {
        devices.first.flatMap { WebServiceResolver.primaryTarget(for: $0) }
    }

    private var navigationTitle: String {
        if let page, !page.title.isEmpty { return page.title }
        return webTarget?.serviceName ?? "Device Web"
    }

    private var canGoBack: Bool {
        !(page?.backForwardList.backList.isEmpty ?? true)
    }

    private var canGoForward: Bool {
        !(page?.backForwardList.forwardList.isEmpty ?? true)
    }

    // MARK: - Actions

    private func setUp() async {
        guard page == nil,
              let device = devices.first,
              let resolved = WebServiceResolver.primaryTarget(for: device),
              let origin = WebOrigin(url: resolved.url) else {
            return
        }

        let store = SwiftDataWebHostTrustStore(modelContainer: modelContext.container)
        let navigationDecider = DeviceWebNavigationDecider(origin: origin, coordinator: trustCoordinator, store: store)
        let newPage = WebPage(navigationDecider: navigationDecider)

        decider = navigationDecider
        page = newPage
        WebAudit.opened(host: resolved.host, port: resolved.port, service: resolved.serviceName)

        // Drive the load and surface a thrown navigation error as the load
        // failure; the toolbar progress binds to the page's observable state.
        do {
            for try await _ in newPage.load(URLRequest(url: resolved.url)) {
                loadFailure = nil
            }
        } catch {
            // WebPage.NavigationError is an opaque wrapper (often code 0); the
            // real cause is usually the URL-loading error it carries in
            // NSUnderlyingError. Surface both so an operator can read and copy
            // the actionable code (for example -1202 untrusted cert, -1022 ATS).
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            Logger(subsystem: "pulse", category: "web.session")
                .error("web.session.load_failed host=\(resolved.host, privacy: .public) port=\(resolved.port, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) underlying=\(underlying.map { "\($0.domain)#\($0.code)" } ?? "none", privacy: .public) desc=\(nsError.localizedDescription, privacy: .public)")
            var message = "\(nsError.localizedDescription)\n\(nsError.domain) \(nsError.code)"
            if let underlying {
                message += "\nunderlying: \(underlying.domain) \(underlying.code) \(underlying.localizedDescription)"
            }
            loadFailure = message
        }
    }

    private func goBack() {
        guard let page, let item = page.backForwardList.backList.last else { return }
        _ = page.load(item)
    }

    private func goForward() {
        guard let page, let item = page.backForwardList.forwardList.first else { return }
        _ = page.load(item)
    }

    private func reload() {
        loadFailure = nil
        _ = page?.reload()
    }
}
