//
//  SSHTerminalView.swift
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
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import SwiftData
import SwiftUI
import OSLog

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Operator-facing SSH terminal for a single `Device` or for an ad-hoc
/// host/port pair. Owns the `SSHClient` lifecycle via `@State`: the
/// connection's lifetime is the view's lifetime. The `.task(id:)`
/// modifier opens the connection when the view appears (or when the
/// connection target changes); SwiftUI auto-cancels the task on
/// dismissal, which triggers the deferred `await client.close()` and
/// drives the underlying SwiftNIO event loop and the recording writer
/// through their teardown paths deterministically.
///
/// Single-window-per-device is enforced by SwiftUI's
/// `WindowGroup(for: DeviceWindowTarget.self)` semantics for the
/// device-backed path, not by this view:
/// `openWindow(id: "ssh-terminal", value: DeviceWindowTarget(deviceID: device.id))`
/// activates the existing window for the same device rather than creating
/// a duplicate. The nominal target type makes a misroute a compile error;
/// the explicit `id:` is retained as a restoration anchor. See
/// `SSHTerminalScene` for the rationale.
/// The ad-hoc path (driven from `DebugSSHWindow`)
/// is one connection at a time per debug window because the debug
/// window itself is a singleton scene.
///
/// **Connection mode.** Two shapes:
///
/// - `.device(Device.ID)`: looks up the device via `@Query`, reads
///   `primaryIP`, `preferredSSHPort`, `defaultUsername`, and
///   `defaultCredentialID` from the SwiftData row. Recordings land
///   under `Pulse/Sessions/dev-<Device.id>/...`.
/// - `.adHoc(host:port:credentialID:)`: skips the SwiftData lookup
///   and uses the supplied connection params directly. Used by the
///   debug verification window for loopback testing. Recordings
///   land under `Pulse/Sessions/unassigned/...` (the SSH layer's
///   `deviceID` parameter is `nil` in this mode).
///
/// Either way the byte pump, recording stack, and host-key mismatch
/// flow are identical; the two modes only differ in where the
/// connection params come from.
struct SSHTerminalView: View {

    enum Connection: Equatable, Hashable {
        case device(Device.ID)
        case adHoc(host: String, port: Int, username: String, credentialID: UUID)
    }

    let connection: Connection

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var devices: [Device]
    @Query(sort: \SSHCredential.label) private var credentials: [SSHCredential]

    /// Owns the connect → run → teardown lifecycle and the observable
    /// status / recording state the view renders. Extracted from this
    /// view per the deferral in ADR 0001; see
    /// `SSHTerminalConnectionViewModel`.
    @State private var vm = SSHTerminalConnectionViewModel()

    /// Operator's captured intent for the next (or current) connection
    /// attempt. Assigning to this triggers the `.task(id: connectionAttempt)`
    /// path; the nonce inside ensures repeated Connect-clicks with the
    /// same username + credential still re-fire the lifecycle. Nil at
    /// `.idle` before the operator clicks Connect (or for the
    /// auto-fire-on-appear path before the .task initializer assigns).
    @State private var connectionAttempt: SSHTerminalConnectionViewModel.ConnectionAttempt?

    /// Operator-typed username for the next connection attempt. Bound
    /// into `SSHConnectForm`'s username field. Distinct from
    /// `connectionAttempt.username` so the operator can edit the value
    /// between attempts without disturbing the in-flight lifecycle.
    @State private var formUsername: String = ""

    /// Operator-selected credential ID for the next connection attempt.
    /// Bound into `SSHConnectForm`'s credential picker. Nil means
    /// "Pick a credential" placeholder is showing.
    @State private var formCredentialID: UUID?

    /// Operator's "Save as default" gesture. Bound into
    /// `SSHConnectForm`'s checkbox. Captured into the next
    /// `ConnectionAttempt` at Connect-click time; the lifecycle
    /// persists `Device.defaultUsername` and `Device.defaultCredentialID`
    /// only after `status = .connected`, so a failed attempt with the
    /// box ticked persists nothing. Defaults to false: persistence is
    /// always an explicit operator gesture, never a silent side-effect
    /// of a successful connect.
    @State private var formSaveAsDefault: Bool = false

    @StateObject private var surface = PulseTerminalSurface()
    @StateObject private var mismatchCoordinator = HostKeyMismatchCoordinator()
    @StateObject private var bellController = TerminalBellController()

    /// Global operator preferences. Bell defaults to on for both axes;
    /// operators in open-plan ops rooms can override via
    /// `defaults write <bundle-id> pulse.terminal.bell.audible -bool false`
    /// per `docs/credentials.md` "Terminal preferences". A future
    /// Settings → SSH "Terminal preferences" pane will surface the
    /// toggles; the @AppStorage shape lets that pane drop in without
    /// migrating storage.
    @AppStorage("pulse.terminal.bell.audible") private var audibleBell = true
    @AppStorage("pulse.terminal.bell.visual") private var visualBell = true

    /// Operator-preferred terminal font size. Same `@AppStorage` key
    /// that `PulseTerminalAdapter` reads; the keyboard-shortcut
    /// buttons below mutate this value and SwiftUI re-renders the
    /// adapter so it applies the new font through `updateNSView` /
    /// `updateUIView`.
    @AppStorage("pulse.terminal.fontSize") private var fontSize: Double = PulseTerminalAdapter.defaultFontSize

    private let logger = Logger(subsystem: "pulse", category: "ssh.session")

    // MARK: Inits

    init(connection: Connection) {
        self.connection = connection
        switch connection {
        case .device(let id):
            _devices = Query(filter: #Predicate<Device> { $0.id == id })
        case .adHoc:
            // Empty fetch. Ad-hoc mode does not consult the device store,
            // but @Query must be initialised on every code path so the
            // SwiftData binding is well-formed. The tautological-false
            // predicate is the structural placeholder; a future refactor
            // that splits this view into device-backed and ad-hoc shapes
            // will remove it.
            _devices = Query(filter: #Predicate<Device> { _ in false })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionEndpointStrip
            terminalArea
        }
        .frame(minWidth: 720, minHeight: 420)
        .background(fontSizeShortcuts)
        // Window title tracks the live device name. `connectionTitle`
        // resolves to `device?.name ?? "Device <id>"` for the device
        // path or `username@host:port` for ad-hoc; either way the
        // title bar reflects the operator's mental model of the
        // session target. Without this modifier the window inherits
        // the WindowGroup's static "SSH Terminal" string or, worse,
        // falls back to "Unknown" under certain restoration paths.
        .navigationTitle(connectionTitle)
        .toolbar { sshTerminalToolbar }
        // First-render setup. Pre-fill the form from device defaults
        // (if present) and synthesise an auto-fire attempt when the
        // device has both defaults set and the credential exists in
        // the store. Body is synchronous; `.onAppear` is the right
        // primitive — `.task` would imply async work and would also
        // keep the auto-fire-on-appear path keyed off `connection`,
        // which the structural gate forbids (the lifecycle .task
        // below is the only place that keys on a connection-identity-
        // derived value). The `connection` identity is set at view
        // init and does not change for the view's lifetime
        // (WindowGroup creates a new view per Device.ID), so the
        // "re-fire on id change" semantics of `.task(id:)` were
        // never needed here.
        .onAppear {
            initializeFormFromDefaults()
            if let attempt = SSHTerminalConnectionViewModel.autoFireAttempt(
                connection: connection,
                deviceDefaultUsername: device?.defaultUsername,
                deviceDefaultCredentialID: device?.defaultCredentialID,
                knownCredentialIDs: Set(credentials.map { $0.id })
            ) {
                connectionAttempt = attempt
            }
        }
        // Lifecycle driver: each new `ConnectionAttempt` (auto-fire on
        // first appear, or operator-clicked Connect on `.idle` /
        // `.failed`) fires this task. The nonce inside the attempt
        // guarantees a repeated attempt with the same username +
        // credential still re-runs the lifecycle.
        .task(id: connectionAttempt) {
            guard let attempt = connectionAttempt else { return }
            await vm.run(
                attempt: attempt,
                context: SSHTerminalConnectionViewModel.LifecycleContext(
                    connection: connection,
                    device: device,
                    credentials: credentials,
                    modelContext: modelContext,
                    surface: surface,
                    bellController: bellController,
                    mismatchCoordinator: mismatchCoordinator
                )
            )
        }
        .sheet(item: $mismatchCoordinator.pending) { request in
            HostKeyMismatchSheet(
                host: request.host,
                port: request.port,
                recordedFingerprint: request.recordedFingerprint,
                recordedAlgorithm: request.recordedAlgorithm,
                recordedFirstSeenAt: request.recordedFirstSeenAt,
                newFingerprint: request.newFingerprint,
                newAlgorithm: request.newAlgorithm,
                resume: { decision in
                    mismatchCoordinator.resolve(decision)
                }
            )
            // The three buttons inside the sheet are the only legitimate
            // exits. iOS swipe-down or a stray Esc on macOS would drop
            // the operator into the 90-second timeout silently; block
            // those paths so the audit trail is always one of the three
            // explicit decisions (or the cancellation reason if the
            // parent view is torn down).
            .interactiveDismissDisabled()
        }
    }

    // MARK: Connection-target derivations

    private var device: Device? {
        devices.first
    }

    private var connectionHost: String? {
        switch connection {
        case .device:
            // `primaryIPAddress` strips the CIDR mask that NetBox's
            // IPAM attaches to addresses (`172.17.255.1/32`,
            // `2001:db8::1/64`). NIOSSH's `Channel.connect(host:port:)`
            // resolves the host string literally; passing the CIDR
            // form lands as "Connect timeout (10 s)" with no further
            // diagnosis. Display sites keep reading `primaryIP`
            // directly so the CIDR remains visible where operators
            // expect to see it.
            return device?.primaryIPAddress
        case .adHoc(let host, _, _, _):
            return host
        }
    }

    private var connectionPort: Int {
        switch connection {
        case .device:
            return device?.preferredSSHPort ?? 22
        case .adHoc(_, let port, _, _):
            return port
        }
    }

    private var connectionTitle: String {
        switch connection {
        case .device(let id):
            return device?.name ?? "Device \(id)"
        case .adHoc(let host, let port, let username, _):
            return "\(username)@\(host):\(port)"
        }
    }

    private var defaultCredentialID: UUID? {
        switch connection {
        case .device:
            return device?.defaultCredentialID
        case .adHoc(_, _, _, let credentialID):
            return credentialID
        }
    }

    // MARK: Connect-form helpers

    /// First-render initialization for the form bindings. Pre-fills
    /// the username with the device's preferred username (empty if
    /// unset; the form's placeholder shows the fallback hint). Pre-
    /// selects the credential only if the device's preferred
    /// credential still exists in the store — a stale ID resolves to
    /// the placeholder "Pick a credential", forcing an explicit
    /// operator selection.
    ///
    /// Idempotent on the @State values: re-running this when the
    /// connection target changes overwrites previous selections with
    /// the new target's defaults.
    private func initializeFormFromDefaults() {
        switch connection {
        case .device:
            formUsername = device?.defaultUsername ?? ""
            if let preferred = device?.defaultCredentialID,
               credentials.contains(where: { $0.id == preferred }) {
                formCredentialID = preferred
            } else {
                formCredentialID = nil
            }
        case .adHoc(_, _, let username, let credentialID):
            formUsername = username
            formCredentialID = credentialID
        }
    }

    // MARK: View sections

    /// Connection-endpoint indicator. Single-line monospaced caption
    /// that shows the resolved `host:port` at `.connected`, empty
    /// elsewhere. Replaces the prior in-view status bar which
    /// duplicated the device name (already in the toolbar
    /// navigationTitle) and the status word (already in the toolbar
    /// status pill).
    ///
    /// **Why a single-line endpoint strip remains.** The toolbar
    /// promotes the device name and the status word, but the host
    /// itself is not surfaced anywhere in the toolbar. Removing the
    /// in-view bar entirely would lose the operator-visible host
    /// string, which is the "where am I typing" check that closes
    /// two session-pinning threats:
    ///
    /// - Mistaken-target keystrokes. Two terminals open to
    ///   similarly-named devices (template-deployed NetBox sites
    ///   produce names like `OMG-0001-01-SR01` and
    ///   `OMG-0002-01-SR01`); operator Cmd-Tabs and types a
    ///   destructive command into the wrong shell. The host string
    ///   is the structural defence; the device name alone is not
    ///   sufficient under naming-collision conditions.
    /// - Mid-session re-IP. A NetBox sync mutates `Device.primaryIP`
    ///   while the session is connected; the endpoint strip shows
    ///   the actual connected host (resolved at connect time),
    ///   giving the operator visible evidence the row and the
    ///   session have diverged.
    ///
    /// The accessibility label spells out the endpoint so VoiceOver
    /// readers get the same session-pinning signal.
    @ViewBuilder
    private var connectionEndpointStrip: some View {
        if vm.status == .connected, let host = connectionHost {
            HStack {
                Text("\(host):\(connectionPort)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Connected endpoint: \(host) port \(connectionPort)")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    /// Context-sensitive toolbar primary action. The button's label
    /// and action both depend on the live `status` via
    /// `primaryActionShape(for:)`; placement is pinned by an
    /// explicit `ToolbarItem(id:)` so SwiftUI's toolbar diffing
    /// animates the label change rather than reflowing surrounding
    /// items.
    @ViewBuilder
    private var primaryActionButton: some View {
        switch SSHTerminalConnectionViewModel.primaryActionShape(for: vm.status) {
        case .disconnect:
            Button("Disconnect") { dismiss() }
                .help("Close this window and tear down the SSH session.")
        case .reconnect:
            Button("Reconnect") { submitConnectionAttempt() }
                .help("Re-fire the connection lifecycle using the form's captured username and credential.")
        case .none:
            EmptyView()
        }
    }

    // MARK: - Toolbar

    /// Window toolbar. Passive indicators (status pill, recording
    /// badge) opt out of the shared Liquid Glass background via
    /// `.sharedBackgroundVisibility(.hidden)` so they don't read as
    /// interactive controls; the primary action keeps its default
    /// glass.
    @ToolbarContentBuilder
    private var sshTerminalToolbar: some ToolbarContent {
        ToolbarItem(id: "status-pill", placement: .navigation) {
            if vm.status != .idle {
                let copy = SSHTerminalConnectionViewModel.statusPillCopy(for: vm.status)
                HStack(spacing: 6) {
                    statusIndicator
                    Text(copy)
                        .font(.caption.weight(.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Connection status: \(copy)")
            }
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "recording-badge", placement: .primaryAction) {
            if vm.isRecording && vm.status == .connected {
                recordingBadge
            }
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "primary-action", placement: .primaryAction) {
            primaryActionButton
        }
    }

    /// Hidden keyboard-shortcut harness for macOS Cmd-+ / Cmd-= /
    /// Cmd-- / Cmd-0. The buttons render zero-size and transparent so
    /// they take the shortcut without participating in the visible
    /// layout. iOS gets the same behaviour through
    /// `UIPinchGestureRecognizer` on the terminal view; the platform
    /// gate keeps the hidden controls off iOS where they would
    /// confuse VoiceOver focus order without adding value.
    #if os(macOS)
    private var fontSizeShortcuts: some View {
        ZStack {
            Button { fontSize = PulseTerminalAdapter.clampFontSize(fontSize + 1.0) } label: { EmptyView() }
                .keyboardShortcut("+", modifiers: .command)
            Button { fontSize = PulseTerminalAdapter.clampFontSize(fontSize + 1.0) } label: { EmptyView() }
                .keyboardShortcut("=", modifiers: .command)
            Button { fontSize = PulseTerminalAdapter.clampFontSize(fontSize - 1.0) } label: { EmptyView() }
                .keyboardShortcut("-", modifiers: .command)
            Button { fontSize = PulseTerminalAdapter.defaultFontSize } label: { EmptyView() }
                .keyboardShortcut("0", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
    #else
    private var fontSizeShortcuts: some View {
        EmptyView()
    }
    #endif

    /// Visible while the credential's `recordSessions` flag is on and
    /// the session is connected. Lives in the window toolbar (see the
    /// `recording-badge` ToolbarItem on `body`), not the in-view
    /// status bar: the toolbar is where session-state indicators
    /// conventionally appear in terminal apps (Terminal.app, iTerm).
    /// The SF Symbol `record.circle.fill` is a distinct shape from the
    /// status pill's plain circle so the badge cannot be mistaken for
    /// the red `.failed` status indicator. Bound off by a third exit
    /// handler registered against `SSHSession.addExitHandler` in
    /// `runConnectionLifecycle`; the byte pump's consumer API stays
    /// unwidened.
    private var recordingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "record.circle.fill")
            Text("Recording")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.red)
        .accessibilityLabel("Session is being recorded")
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        switch vm.status {
        case .idle: return .secondary
        case .connecting: return .yellow
        case .connected: return .green
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    private var statusDescription: String {
        switch vm.status {
        case .idle:
            return "Idle"
        case .connecting:
            guard let host = connectionHost else { return "Connecting…" }
            return "Connecting to \(host):\(connectionPort)…"
        case .connected:
            guard let host = connectionHost else { return "Connected" }
            return "Connected to \(host)"
        case .disconnected(let cause):
            return "Disconnected: \(cause)"
        case .failed(let reason):
            return reason
        }
    }

    @ViewBuilder
    private var terminalArea: some View {
        switch vm.status {
        case .idle:
            // First appearance with no auto-fire (device defaults
            // not set, or ad-hoc surface deferred). Show the form
            // so the operator can fill the missing pieces. For
            // ad-hoc mode, autoFireAttempt always returns non-nil,
            // so this branch only renders in device mode without
            // both defaults set.
            idleArea

        case .connecting:
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .connected:
            PulseTerminalAdapter(surface: surface)
                .overlay {
                    // Visual bell. White overlay at 18 % opacity for a
                    // 120 ms beat — enough to register peripherally
                    // without obscuring terminal contents. Driven by
                    // `TerminalBellController` so the @Sendable bell
                    // closure can flip state without capturing the
                    // view struct's @State.
                    Color.white
                        .opacity(bellController.isFlashing ? 0.18 : 0)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.12), value: bellController.isFlashing)
                }

        case .disconnected:
            VStack(spacing: 8) {
                Text(statusDescription)
                    .font(.body)
                    .multilineTextAlignment(.center)
                Button("Close") { dismiss() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let reason):
            // Retry path. Same form as `.idle`, with the failure
            // message banner above. Operator fixes username or
            // credential and clicks Connect again; the form's
            // onConnect closure synthesises a fresh
            // `ConnectionAttempt` (new nonce) which re-fires the
            // `.task(id: connectionAttempt)`. Ad-hoc keeps Close-
            // only because the upstream debug surface owns the
            // retry path for that mode.
            failedArea(reason: reason)
        }
    }

    // MARK: Form rendering for .idle and .failed

    /// Form rendering at `.idle`. Device mode shows the connect form;
    /// ad-hoc mode shows a spinner (the auto-fire attempt is already
    /// in flight via the `.task` modifier).
    @ViewBuilder
    private var idleArea: some View {
        switch connection {
        case .device:
            connectFormScroller(errorMessage: nil)
        case .adHoc:
            // The auto-fire path will have already assigned
            // connectionAttempt; this branch is effectively a
            // very brief spinner before status flips to .connecting.
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Form rendering at `.failed`. Device mode re-renders the form
    /// with the failure banner; ad-hoc mode keeps the existing
    /// "error + Close" affordance because the upstream debug
    /// surface owns the retry flow for ad-hoc.
    @ViewBuilder
    private func failedArea(reason: String) -> some View {
        switch connection {
        case .device:
            connectFormScroller(errorMessage: reason)
        case .adHoc:
            VStack(spacing: 8) {
                Text(reason)
                    .font(.body)
                    .multilineTextAlignment(.center)
                Button("Close") { dismiss() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Wraps `SSHConnectForm` with a centred ScrollView so the form
    /// stays usable when the window is sized below the form's natural
    /// height (operator dragged the divider, or opened on a small
    /// display). Centring keeps the form in the visual middle while
    /// allowing scroll on narrow vertical layouts.
    private func connectFormScroller(errorMessage: String?) -> some View {
        ScrollView {
            HStack {
                Spacer(minLength: 0)
                SSHConnectForm(
                    title: connectionTitle,
                    primaryIP: connectionHost,
                    port: connectionPort,
                    initialUsername: formUsername,
                    credentials: credentials,
                    errorMessage: errorMessage,
                    isDeviceMode: isDeviceMode,
                    hasSavedDefaults: hasSavedDeviceDefaults,
                    username: $formUsername,
                    selectedCredentialID: $formCredentialID,
                    saveAsDefault: $formSaveAsDefault,
                    onConnect: submitConnectionAttempt,
                    onCancel: { dismiss() },
                    onClearDefaults: clearDeviceDefaultsFromForm
                )
                Spacer(minLength: 0)
            }
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether the current `connection` is a device-backed connection.
    /// The "Save as default" checkbox and the "Clear saved defaults"
    /// button only render in device mode; ad-hoc connections never
    /// persist to a SwiftData row.
    private var isDeviceMode: Bool {
        switch connection {
        case .device: return true
        case .adHoc: return false
        }
    }

    /// Whether the device row carries either default field populated.
    /// Drives visibility of the form's "Clear saved defaults" button:
    /// the button only renders when there is something to clear, and
    /// hides itself once both fields are nil.
    private var hasSavedDeviceDefaults: Bool {
        guard let device else { return false }
        return device.defaultUsername != nil || device.defaultCredentialID != nil
    }

    /// Handler for the form's "Clear saved defaults" button. Nils
    /// both Device default fields in one transaction, saves the
    /// context, and resets the form's two pre-fill bindings so the
    /// next render shows the empty form rather than the just-cleared
    /// values. The "Save as default" checkbox is also reset to
    /// false: clearing is a deliberate "no defaults" gesture and
    /// keeping the box ticked would silently re-persist on the next
    /// successful connect, defeating the point.
    private func clearDeviceDefaultsFromForm() {
        guard let device else { return }
        SSHTerminalConnectionViewModel.clearDeviceDefaults(device: device)
        do {
            try modelContext.save()
            logger.info("Cleared device defaults for device id \(device.id, privacy: .public)")
        } catch {
            logger.error("Failed to save context after clearing device defaults: \(String(describing: error), privacy: .public)")
        }
        formUsername = ""
        formCredentialID = nil
        formSaveAsDefault = false
    }

    /// Synthesises a fresh `ConnectionAttempt` from the form's
    /// current bindings and assigns it to `connectionAttempt`,
    /// firing the `.task(id: connectionAttempt)` lifecycle. New
    /// `nonce` per click so a repeated retry with identical fields
    /// still re-fires.
    private func submitConnectionAttempt() {
        guard let credentialID = formCredentialID,
              SSHConnectForm.canConnect(
                username: formUsername,
                credentialID: formCredentialID,
                primaryIP: connectionHost
              )
        else { return }
        connectionAttempt = SSHTerminalConnectionViewModel.ConnectionAttempt(
            nonce: UUID(),
            username: formUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialID: credentialID,
            saveAsDefault: formSaveAsDefault
        )
    }

}

// `TerminalBellController` and `fireAudibleBell()` live in
// `TerminalBellController.swift` per the Omega Swift convention of
// one type per file for non-view types.
