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

/// Operator-facing SSH terminal for a single `Device`. Owns the
/// `SSHClient` lifecycle via `@State`: the connection's lifetime is
/// the view's lifetime. The `.task(id:)` modifier opens the
/// connection when the view appears (or the device ID changes);
/// SwiftUI auto-cancels the task on dismissal, which triggers the
/// deferred `await client.close()` and drives the underlying
/// SwiftNIO event loop and the recording writer through their
/// teardown paths deterministically.
///
/// Single-window-per-device is enforced by SwiftUI's
/// `WindowGroup(for: Device.ID.self)` semantics, not by this view:
/// `openWindow(value: device.id)` activates the existing window for
/// the same `Device.ID` rather than creating a duplicate. This view
/// can therefore assume it is the sole owner of the connection for
/// the lifetime of the on-screen window.
///
/// The host-key mismatch sheet is wired in a subsequent change; this
/// view ships the byte pump and the connection lifecycle. Mismatches
/// during connection continue to reject via the existing
/// `SSHHostKeyDelegate` path; the operator sees the failed-status
/// banner.
struct SSHTerminalView: View {

    let deviceID: Device.ID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var devices: [Device]
    @Query(sort: \SSHCredential.label) private var credentials: [SSHCredential]

    @State private var status: ConnectionStatus = .idle
    @State private var sshClient: SSHClient?
    @State private var selectedCredentialID: UUID?
    @StateObject private var surface = PulseTerminalSurface()

    private let logger = Logger(subsystem: "pulse", category: "ssh.session")

    init(deviceID: Device.ID) {
        self.deviceID = deviceID
        _devices = Query(filter: #Predicate<Device> { $0.id == deviceID })
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            terminalArea
        }
        .frame(minWidth: 720, minHeight: 420)
        .task(id: deviceID) {
            await runConnectionLifecycle()
        }
    }

    private var device: Device? {
        devices.first
    }

    private var activeCredentialID: UUID? {
        selectedCredentialID ?? device?.defaultCredentialID
    }

    private var activeCredential: SSHCredential? {
        guard let id = activeCredentialID else { return nil }
        return credentials.first(where: { $0.id == id })
    }

    // MARK: View sections

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(device?.name ?? "Device \(deviceID)")
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
            guard let host = device?.primaryIP else { return "Connecting…" }
            let port = device?.preferredSSHPort ?? 22
            return "Connecting to \(host):\(port)…"
        case .connected:
            guard let host = device?.primaryIP else { return "Connected" }
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
    /// (window close, view dismissal) lands as a `CancellationError`
    /// inside the `await` and the `defer` block runs the close.
    private func runConnectionLifecycle() async {
        guard let device else {
            status = .failed("Device \(deviceID) not found in the local store.")
            return
        }
        guard let host = device.primaryIP, !host.isEmpty else {
            status = .failed("Device has no primary IP configured in NetBox.")
            return
        }
        guard let credentialID = activeCredentialID,
              let credential = credentials.first(where: { $0.id == credentialID })
        else {
            status = .failed("Pick a credential to connect.")
            return
        }

        let port = device.preferredSSHPort ?? 22
        let username = device.defaultUsername ?? NSUserName()

        let knownHostStore = SwiftDataKnownHostStore(modelContainer: modelContext.container)
        let pemProvider: PortablePEMProvider = { [credentialID] in
            let pem = await Configuration.shared.sshPrivateKeyPEM(for: credentialID)
            return pem.map { Data($0.utf8) }
        }

        let client = SSHClient(
            transport: DirectTransport(),
            host: host,
            port: port,
            username: username,
            credentialID: credentialID,
            tier: credential.tier,
            certificateBlob: credential.certificate,
            pemProvider: pemProvider,
            knownHostStore: knownHostStore,
            deviceID: device.id,
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
            logger.error("SSH connect failed for device \(device.id, privacy: .public): \(String(describing: error), privacy: .public)")
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

        // Hold a continuation against the session's exit signal so the
        // outer task suspends until the connection ends.
        await session.setExitHandler { cause in
            Task { @MainActor in
                status = .disconnected("\(cause)")
            }
        }

        // pty-req + shell. The SwiftUI layout's first updateNSView/
        // updateUIView pass will report the real cols/rows and drive
        // a resize event via the surface; the initial 80x24 is a
        // reasonable default that gets refined immediately.
        await session.requestPTY(cols: 80, rows: 24)
        await session.requestShell()

        status = .connected
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
