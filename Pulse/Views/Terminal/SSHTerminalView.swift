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
    @State private var selectedCredentialID: UUID?
    @StateObject private var surface = PulseTerminalSurface()
    @StateObject private var mismatchCoordinator = HostKeyMismatchCoordinator()

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
        .task(id: connection) {
            await runConnectionLifecycle()
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

    private var activeCredentialID: UUID? {
        selectedCredentialID ?? defaultCredentialID
    }

    // MARK: View sections

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(connectionTitle)
                    .font(.headline)
                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            credentialPicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
    private var credentialPicker: some View {
        if credentials.isEmpty {
            Text("No credentials")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Credential", selection: $selectedCredentialID) {
                Text("Default").tag(UUID?.none)
                ForEach(credentials, id: \.id) { credential in
                    Text(credential.label).tag(UUID?.some(credential.id))
                }
            }
            .labelsHidden()
            .disabled(status == .connecting || status == .connected)
        }
    }

    @ViewBuilder
    private var terminalArea: some View {
        switch status {
        case .idle, .connecting:
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .connected:
            PulseTerminalAdapter(surface: surface)

        case .disconnected, .failed:
            VStack(spacing: 8) {
                Text(statusDescription)
                    .font(.body)
                    .multilineTextAlignment(.center)
                Button("Close") { dismiss() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Connection lifecycle

    /// Drives the full connect → run → teardown lifecycle. Cancellation
    /// (window close, view dismissal, connection-target change) lands
    /// as a `CancellationError` inside the `await` and the `defer`
    /// block runs the close.
    private func runConnectionLifecycle() async {
        // Resolve the connection params and the per-connection
        // metadata. For device-backed mode we need the SwiftData row
        // to exist; for ad-hoc we get the params directly.
        let resolvedHost: String
        let resolvedPort: Int
        let resolvedUsername: String
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
            resolvedUsername = device.defaultUsername ?? NSUserName()
            resolvedDeviceID = device.id

        case .adHoc(let host, let port, let username, _):
            resolvedHost = host
            resolvedPort = port
            resolvedUsername = username
            resolvedDeviceID = nil
        }

        guard let credentialID = activeCredentialID,
              let credential = credentials.first(where: { $0.id == credentialID })
        else {
            status = .failed("Pick a credential to connect.")
            return
        }

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

        status = .connected

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
                    // Then drive pty-req + shell. The 80x24 default is a
                    // placeholder; the first notifyResize callback from
                    // PulseTerminalSurface fires a window-change to the
                    // real terminal-view bounds shortly after connect.
                    await session.requestPTY(cols: 80, rows: 24)
                    await session.requestShell()
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

    // MARK: Connection status

    enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(String)
        case failed(String)
    }
}
