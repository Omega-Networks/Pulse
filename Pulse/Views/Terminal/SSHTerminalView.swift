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
/// `WindowGroup(for: Device.ID.self)` semantics for the
/// device-backed path, not by this view: `openWindow(value: device.id)`
/// activates the existing window for the same `Device.ID` rather than
/// creating a duplicate. The ad-hoc path (driven from `DebugSSHWindow`)
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

    @State private var status: ConnectionStatus = .idle
    @State private var sshClient: SSHClient?
    @State private var isRecording = false

    /// Operator's captured intent for the next (or current) connection
    /// attempt. Assigning to this triggers the `.task(id: connectionAttempt)`
    /// path; the nonce inside ensures repeated Connect-clicks with the
    /// same username + credential still re-fire the lifecycle. Nil at
    /// `.idle` before the operator clicks Connect (or for the
    /// auto-fire-on-appear path before the .task initializer assigns).
    @State private var connectionAttempt: ConnectionAttempt?

    /// Operator-typed username for the next connection attempt. Bound
    /// into `SSHConnectForm`'s username field. Distinct from
    /// `connectionAttempt.username` so the operator can edit the value
    /// between attempts without disturbing the in-flight lifecycle.
    @State private var formUsername: String = ""

    /// Operator-selected credential ID for the next connection attempt.
    /// Bound into `SSHConnectForm`'s credential picker. Nil means
    /// "Pick a credential" placeholder is showing.
    @State private var formCredentialID: UUID?

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
            statusBar
            Divider()
            terminalArea
        }
        .frame(minWidth: 720, minHeight: 420)
        .background(fontSizeShortcuts)
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
            if let attempt = Self.autoFireAttempt(
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
            await runConnectionLifecycle(attempt: attempt)
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
            return device?.primaryIP
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

    /// Snapshot of the operator's captured intent for one connection
    /// attempt. The `nonce` lets a repeated attempt with the same
    /// username + credential still re-fire the lifecycle (the
    /// `.task(id: connectionAttempt)` modifier keys on Hashable
    /// equality, and changing only `nonce` is enough to invalidate).
    /// Hashable + Equatable because SwiftUI's `.task(id:)` requires
    /// `Equatable` and we synthesise hashing from the three fields.
    struct ConnectionAttempt: Hashable, Sendable {
        let nonce: UUID
        let username: String
        let credentialID: UUID
    }

    /// Returns an attempt to auto-fire on first appear, or nil if the
    /// operator must fill the form first.
    ///
    /// - For `.device`, requires both `Device.defaultUsername` and
    ///   `Device.defaultCredentialID` set, and the credential to
    ///   actually exist in the local store (defence in depth against
    ///   a stale ID whose credential was deleted after the device row
    ///   was last edited).
    /// - For `.adHoc`, the upstream debug surface already gathered
    ///   username + credential explicitly; auto-fire with those.
    ///
    /// Takes the device's two default fields plus a set of known
    /// credential IDs rather than a `Device` pointer + `[SSHCredential]`
    /// — keeps the helper testable without standing up SwiftData or a
    /// `Device` instance, which is the entire point of pulling the
    /// gate into a static method. Pure function for testability — the
    /// test pins the boundary cases (both defaults present and
    /// credential exists; both present but credential deleted; only
    /// one default present; etc.) without rendering SwiftUI or
    /// constructing an `SSHSession`.
    static func autoFireAttempt(
        connection: Connection,
        deviceDefaultUsername: String?,
        deviceDefaultCredentialID: UUID?,
        knownCredentialIDs: Set<UUID>
    ) -> ConnectionAttempt? {
        switch connection {
        case .device:
            let trimmed = deviceDefaultUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty,
                  let credentialID = deviceDefaultCredentialID,
                  knownCredentialIDs.contains(credentialID)
            else { return nil }
            return ConnectionAttempt(nonce: UUID(), username: trimmed, credentialID: credentialID)

        case .adHoc(_, _, let username, let credentialID):
            return ConnectionAttempt(nonce: UUID(), username: username, credentialID: credentialID)
        }
    }

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

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusIndicator
            // The badge is gated on both `isRecording` and the live
            // connection state so the disconnect transition does not
            // briefly render a "Recording" badge alongside the
            // disconnected status text. Without the `.connected`
            // guard there is one render pass between `signalExit`
            // firing the recording-flip task and the lifecycle
            // setting `status = .disconnected(...)` where both states
            // coexist; the guard collapses that window without
            // requiring synchronisation with the exit-handler queue.
            if isRecording && status == .connected {
                recordingBadge
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(connectionTitle)
                    .font(.headline)
                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
    /// the session is connected. The SF Symbol `record.circle.fill` is
    /// a distinct shape from the connection-status dot's plain circle,
    /// so the badge cannot be mistaken for the red `.failed` status
    /// indicator even at small statusBar sizes. Bound off by a third
    /// exit handler registered against `SSHSession.addExitHandler` in
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
        switch status {
        case .idle: return .secondary
        case .connecting: return .yellow
        case .connected: return .green
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    private var statusDescription: String {
        switch status {
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
        switch status {
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
                    username: $formUsername,
                    selectedCredentialID: $formCredentialID,
                    onConnect: submitConnectionAttempt,
                    onCancel: { dismiss() }
                )
                Spacer(minLength: 0)
            }
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        connectionAttempt = ConnectionAttempt(
            nonce: UUID(),
            username: formUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialID: credentialID
        )
    }

    // MARK: Connection lifecycle

    /// Drives the full connect → run → teardown lifecycle. Cancellation
    /// (window close, view dismissal, connection-target change) lands
    /// as a `CancellationError` inside the `await` and the `defer`
    /// block runs the close. The captured `attempt` is the operator's
    /// snapshot at Connect-click time; mutating `formUsername` or
    /// `formCredentialID` while a lifecycle is in flight does not
    /// affect the current attempt.
    private func runConnectionLifecycle(attempt: ConnectionAttempt) async {
        // Resolve the connection params and the per-connection
        // metadata. For device-backed mode we need the SwiftData row
        // to exist; for ad-hoc we get the params from the connection
        // enum. The username comes from the captured attempt (the
        // form for device mode, the upstream debug surface for
        // ad-hoc) — not from the device row, not from the macOS-short-
        // name fallback. The form's placeholder hint surfaces that
        // fallback to the operator instead, so a connect with the
        // wrong username is now an explicit operator gesture rather
        // than a silent default.
        let resolvedHost: String
        let resolvedPort: Int
        let resolvedDeviceID: Int64?

        switch connection {
        case .device(let id):
            guard let device else {
                status = .failed("Device \(id) not found in the local store.")
                return
            }
            guard let host = device.primaryIP, !host.isEmpty else {
                status = .failed("Device has no primary IP configured in NetBox.")
                return
            }
            resolvedHost = host
            resolvedPort = device.preferredSSHPort ?? 22
            resolvedDeviceID = device.id

        case .adHoc(let host, let port, _, _):
            resolvedHost = host
            resolvedPort = port
            resolvedDeviceID = nil
        }

        let resolvedUsername = attempt.username

        guard let credential = credentials.first(where: { $0.id == attempt.credentialID }) else {
            status = .failed("Credential not found. It may have been deleted while the window was open. Pick another credential to retry.")
            return
        }
        let credentialID = attempt.credentialID

        let knownHostStore = SwiftDataKnownHostStore(modelContainer: modelContext.container)
        let pemProvider: PortablePEMProvider = { [credentialID] in
            let pem = await Configuration.shared.sshPrivateKeyPEM(for: credentialID)
            return pem.map { Data($0.utf8) }
        }

        let client = SSHClient(
            transport: DirectTransport(),
            host: resolvedHost,
            port: resolvedPort,
            username: resolvedUsername,
            credentialID: credentialID,
            tier: credential.tier,
            certificateBlob: credential.certificate,
            pemProvider: pemProvider,
            knownHostStore: knownHostStore,
            hostKeyMismatchProvider: mismatchCoordinator,
            deviceID: resolvedDeviceID,
            recordSessions: credential.recordSessions
        )
        sshClient = client
        status = .connecting

        defer {
            // Window-closes-while-connected lands here via task
            // cancellation; the close drives the SSHClient's NIOSSH
            // teardown and the recording writer's finalisation.
            Task { await client.close() }
            sshClient = nil
        }

        let session: SSHSession
        do {
            session = try await client.connect()
        } catch {
            logger.error(
                "SSH connect failed for \(resolvedHost, privacy: .public):\(resolvedPort): \(String(describing: error), privacy: .public)"
            )
            status = .failed("Connection failed: \(error)")
            return
        }

        // Wire the byte pump. setOutputHandler is single-slot by
        // contract; the recording tap already sits in the channel
        // pipeline, so this consumer only sees server-to-operator
        // bytes after the tap has captured them.
        await session.setOutputHandler { bytes in
            surface.feed(bytes)
        }
        surface.sendHandler = { bytes in
            Task { await session.write(bytes) }
        }
        surface.resizeHandler = { cols, rows in
            Task { await session.resize(cols: cols, rows: rows) }
        }

        // Bell handler. Closure reads operator preferences from
        // UserDefaults at fire time (not at wiring time) so a mid-
        // session preference toggle takes effect on the next bell
        // without restarting the connection. Capturing the @AppStorage
        // value here would freeze it. Both keys default to true so a
        // build with an empty UserDefaults still produces a signal.
        // The audible path goes through the controller's 250 ms gate
        // so a server BEL loop produces ~4 Hz of beeps rather than
        // one per event; the visual flash coalesces naturally via
        // the controller's cancel-and-reschedule.
        let controller = bellController
        surface.bellHandler = { @Sendable in
            Task { @MainActor in
                let defaults = UserDefaults.standard
                let audible = defaults.object(forKey: "pulse.terminal.bell.audible") as? Bool ?? true
                let visual = defaults.object(forKey: "pulse.terminal.bell.visual") as? Bool ?? true
                if audible {
                    controller.requestAudibleBell()
                }
                if visual {
                    controller.trigger()
                }
            }
        }

        // Third exit handler — recording-indicator off-flip. Registered
        // *after* `SSHClient.connect` returns, so it joins the multicast
        // list alongside the audit emitter (registered inside
        // SSHClient.connect) and the continuation-resume handler
        // (registered below). Registration order is the firing order
        // per `SSHSession.addExitHandler`; the immediate-fire contract
        // guarantees a fast handshake-then-drop sequence still flips
        // the indicator off correctly. The static helper holds the
        // bool-flip contract so it stays testable against a stub
        // registrar without standing up a real SSHSession.
        if credential.recordSessions {
            await Self.registerRecordingLifecycle(
                register: { handler in await session.addExitHandler(handler) },
                onChange: { newValue in isRecording = newValue }
            )
        }

        status = .connected

        // Give SwiftUI a chance to complete its first layout pass for
        // the freshly-mounted PulseTerminalAdapter before we read the
        // terminal grid geometry below. Task.yield() requeues this
        // coroutine on the cooperative pool; pending MainActor work
        // (including the makeNSView/updateNSView pair we just
        // triggered by flipping status to .connected) runs ahead of
        // our resumption. The yield is not a synchronisation
        // primitive — if SwiftUI defers layout further, our geometry
        // read will still return nil and we will fall back to 80x24
        // for the initial PTY request, with the post-shell re-pump
        // catching up to reality. The yield just maximises the
        // probability that the initial PTY is allocated at the right
        // size to begin with, eliminating the bash readline
        // confusion that the post-pump alone cannot fully clean up
        // because SIGWINCH doesn't reset in-flight input state.
        await Task.yield()

        // Pump 1: read the current terminal geometry from the live
        // PulseTerminalSurface and use it for the initial PTY
        // allocation. Fall back to the SSH protocol default 80x24 if
        // the view has not yet been laid out (nil case).
        let initialGeometry = await MainActor.run {
            surface.currentTerminalGeometry()
        } ?? (cols: 80, rows: 24)

        // Suspend the lifecycle until the session ends. The exit
        // handler resumes the continuation; view dismissal cancels
        // the .task, which fires `onCancel` to close the client,
        // which drives the session's `channelInactive` path, which
        // fires the exit handler, which resumes the continuation.
        // Either way the continuation resolves exactly once and the
        // defer block at the top of this function gets to run the
        // idempotent cleanup `await client.close()`.
        //
        // Without this suspension the function returned straight
        // after `status = .connected`, the defer fired
        // `client.close()`, and the operator saw
        // `session.open → auth.success → channel-error: child
        // channel inactive` within the same UI tick. The byte pump
        // never got bytes; the recording stack never got records.
        let exitCause = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ExitCause, Never>) in
                Task {
                    // Register the lifecycle exit handler. Multicast
                    // semantics: the audit handler registered by
                    // SSHClient.connect fires alongside this one in
                    // registration order, and a late registration (the
                    // session already closed in the brief window between
                    // SSHClient.connect returning and this Task running)
                    // takes the immediate-fire path in
                    // SSHSession.addExitHandler.
                    await session.addExitHandler { cause in
                        continuation.resume(returning: cause)
                    }
                    // Drive pty-req + shell at the size we read from
                    // the surface above (or the 80x24 fallback). Two-
                    // pump pattern: pump 2 fires immediately after
                    // requestShell to re-read the geometry and send an
                    // explicit window-change if layout completed
                    // between pump 1 and now. Matches the SwiftTermApp
                    // reference at TerminalApp/iOSTerminal/UIKitSshTerminalView.swift
                    // lines 362-379 (initial) + 310-315 (sendInitialResize).
                    await session.requestPTY(
                        cols: initialGeometry.cols,
                        rows: initialGeometry.rows
                    )
                    await session.requestShell()

                    // Pump 2: re-read geometry on MainActor. If layout
                    // completed between pump 1 and now (and reported
                    // dimensions that differ from what we allocated),
                    // send window-change so bash sees the right size
                    // before it finishes printing its prompt. The
                    // surface's notifyResize dedupe will skip the
                    // subsequent updateNSView pass if it would report
                    // the same dimensions.
                    if let actualGeometry = await MainActor.run(body: { surface.currentTerminalGeometry() }),
                       actualGeometry.cols != initialGeometry.cols || actualGeometry.rows != initialGeometry.rows {
                        await session.resize(
                            cols: actualGeometry.cols,
                            rows: actualGeometry.rows
                        )
                    }
                }
            }
        } onCancel: {
            // View dismissed (window closed, Back-to-form button
            // pressed). Close the client; the exit handler will
            // resume the continuation with a channelError cause and
            // the function returns through the defer.
            Task { await client.close() }
        }

        status = .disconnected("\(exitCause)")
    }

    // MARK: Recording lifecycle helper

    /// Function type for the exit-handler registrar shape that
    /// `SSHSession.addExitHandler` satisfies. Lifting this into a
    /// typealias lets `registerRecordingLifecycle` accept either a
    /// real session call (`{ h in await session.addExitHandler(h) }`)
    /// or a stub registrar in tests, without requiring an
    /// `EmbeddedChannel`-backed `SSHSession` to exercise the bool-
    /// flip contract.
    typealias RecordingLifecycleRegistrar = (@escaping @Sendable (ExitCause) -> Void) async -> Void

    /// Wires the recording-status indicator to a session's exit
    /// handler. Calls `onChange(true)` after registration succeeds
    /// (the badge should appear) and `onChange(false)` when the
    /// session signals exit (the badge should clear). The false-flip
    /// is routed through a `Task { @MainActor in ... }` hop so the
    /// EventLoop-thread `signalExit` invocation lands on the right
    /// isolation domain for SwiftUI state mutation.
    ///
    /// **Immediate-fire ordering.** If the session has already exited
    /// at registration time, `SSHSession.addExitHandler` invokes the
    /// handler synchronously per the multicast late-attach contract.
    /// The Task hop on the false-flip ensures `onChange(true)` runs
    /// first (from the inline call after `await register`), then the
    /// deferred false-flip completes — the indicator briefly shows
    /// then clears, rather than the opposite order which would leave
    /// the badge on against an already-dead session.
    ///
    /// Extracted as a helper so the bool-flip contract is testable
    /// against a stub registrar in `PulseTerminalAdapterTests`. The
    /// alternative (testing against a real `SSHSession`) would
    /// require standing up an `EmbeddedChannel` plus a NIOSSH child
    /// channel for what is fundamentally a two-line state-machine
    /// check.
    @MainActor
    static func registerRecordingLifecycle(
        register: RecordingLifecycleRegistrar,
        onChange: @escaping @MainActor @Sendable (Bool) -> Void
    ) async {
        await register { _ in
            Task { @MainActor in onChange(false) }
        }
        onChange(true)
    }

    // MARK: Connection status

    enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(String)
        case failed(String)
    }
}

// MARK: - Bell helpers

/// Fires the platform-correct audible bell. macOS uses `NSSound.beep`
/// which respects the operator's Sound preferences (alert sound,
/// system volume) so the bell composes with macOS-wide audio settings.
/// iOS uses a warning haptic instead of audio because most ops happen
/// on devices in silent mode; the haptic is registered as "warning"
/// rather than "notification" so it does not also trigger the iOS
/// notification sound the latter would normally pair with.
@MainActor
func fireAudibleBell() {
    #if os(macOS)
    NSSound.beep()
    #else
    let generator = UINotificationFeedbackGenerator()
    generator.notificationOccurred(.warning)
    #endif
}

/// Drives both the audible bell rate-limit and the visual-bell flash
/// overlay for `SSHTerminalView.terminalArea`. Lives in a reference
/// type so the @Sendable bell closure captures the controller rather
/// than the View struct's @State; @State capture across @Sendable
/// closure boundaries is fragile in Swift 6 strict concurrency, and a
/// tiny @MainActor class is simpler than fighting the type system.
///
/// **Why both responsibilities here.** The visual flash gets natural
/// coalescing for free via `resetTask?.cancel()` — overlapping bells
/// hold the overlay at full opacity until the storm subsides, then
/// fade cleanly. The audible path needs its own gate because
/// `NSSound.beep()` and `UINotificationFeedbackGenerator` queue per
/// call with no built-in coalesce, so a server sending `\a` in a loop
/// would produce one beep per event — operator-disrupting at best,
/// weaponisable against an open-plan ops room at worst. The 250 ms
/// gate caps the audible rate at ~4 Hz, which is faster than a human
/// can distinguish individual beeps anyway but slow enough to remain
/// recognisable as a bell rather than a continuous tone.
///
/// File-scope (no `private`) so `@testable import Pulse` reaches the
/// type — the rate-limit gate is a property the slice exists to
/// deliver and tests pay rent on confirming it holds.
@MainActor
final class TerminalBellController: ObservableObject {

    /// Minimum gap between audible bell firings. Set on the type so
    /// tests can reference the same constant rather than hard-coding
    /// the duration, and any future tuning lands in one place.
    static let audibleBellGate: TimeInterval = 0.25

    @Published var isFlashing = false

    private var resetTask: Task<Void, Never>?

    /// Timestamp of the last audible bell that made it past the gate.
    /// `nil` until the first request. Bells within `audibleBellGate`
    /// of this value are dropped silently.
    private var lastAudibleAt: Date?

    /// Test seam. Counts every audible bell that actually fired
    /// through the gate (i.e. was *not* rate-limited). Tests assert
    /// the gate by triggering N bells inside the window and checking
    /// this value equals 1.
    private(set) var audibleBellFireCount: Int = 0

    /// Audible bell request. Drops the request silently when the
    /// previous audible fired within `audibleBellGate`. Otherwise
    /// records the time, increments the test-observable counter, and
    /// invokes the platform helper. The `now:` parameter is the
    /// inject-the-clock test seam; production callers leave it at the
    /// default.
    func requestAudibleBell(now: Date = Date()) {
        if let last = lastAudibleAt, now.timeIntervalSince(last) < Self.audibleBellGate {
            return
        }
        lastAudibleAt = now
        audibleBellFireCount += 1
        fireAudibleBell()
    }

    /// 120 ms visual flash beat. Long enough to register peripherally;
    /// short enough not to obscure terminal contents on a server
    /// emitting repeated bells (e.g. a runaway script). Repeated calls
    /// cancel the in-flight reset task so the overlay holds at full
    /// opacity until the bell storm subsides, then fades cleanly. No
    /// rate gate is needed here because the cancel-and-reschedule
    /// pattern coalesces visually for free.
    func trigger() {
        isFlashing = true
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.isFlashing = false
        }
    }
}
