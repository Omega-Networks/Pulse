//
//  DebugSSHMenu.swift
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

#if DEBUG

import Foundation
import OSLog
import SwiftData
import SwiftUI

// MARK: - DebugSSHCommands

/// Debug-only menu command that opens the SSH verification window.
/// Compiled out of Release builds via the `#if DEBUG` gate on the whole
/// file; the matching `.commands { DebugSSHCommands() }` modifier in
/// `PulseApp.swift` is also `#if DEBUG`-gated so Release builds carry
/// neither the symbol nor the menu entry.
///
/// The window is a thin verification surface: it takes a free-form
/// host (loopback by default), a port, and a credential, then opens
/// the same operator-facing `SSHTerminalView` inline in ad-hoc mode.
/// Recordings driven from here land under
/// `Pulse/Sessions/unassigned/...` because the connection is not
/// tied to a NetBox `Device`. The Replay action surfaces the
/// most-recent recording for visual inspection.
struct DebugSSHCommands: Commands {

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Open SSH Test Window…") {
                openWindow(id: DebugSSHWindow.windowID)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift, .option])
        }
    }
}

// MARK: - DebugSSHWindow

/// Debug-only window that wires a free-form host + port + credential
/// into the operator-facing `SSHTerminalView` in ad-hoc mode. The
/// terminal renders inline (replacing the form pane) once connected
/// so the window itself is the verification surface — no separate
/// per-connection scene needed for the lab path. The Replay action
/// stays available in form mode.
///
/// For loopback testing: type `127.0.0.1` (or click the IPv4 / IPv6
/// quick-fill), pick a credential, click Open SSH Terminal. The
/// terminal connects against `Remote Login` on the dev Mac. Back
/// returns to the form so a fresh test can be set up against
/// different parameters.
struct DebugSSHWindow: View {

    static let windowID = "debug-ssh"

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \SSHCredential.label) private var credentials: [SSHCredential]

    @State private var host: String = Self.defaultLoopbackV4
    @State private var port: Int = 22
    @State private var username: String = NSUserName()
    @State private var selectedCredentialID: UUID?
    @State private var activeTarget: SSHTerminalView.Connection?
    @State private var seats = LicenseSeatStore()

    @State private var output: String = ""
    @State private var replayStatus: String = ""
    @State private var isReplaying: Bool = false

    private static let defaultLoopbackV4 = "127.0.0.1"
    private static let defaultLoopbackV6 = "::1"

    private let logger = Logger(subsystem: "pulse", category: "ssh.debug")

    var body: some View {
        Group {
            if let target = activeTarget {
                inlineTerminal(for: target)
            } else {
                formPane
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    // MARK: Form pane

    private var formPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            hostField
            connectionFields
            openButton
            outputArea
            replaySection
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("SSH connection test", systemImage: "terminal.fill")
                .font(.title2.weight(.semibold))
            Text("Opens the operator-facing terminal against a typed host. Either IPv4 or IPv6 works; the default is the IPv4 loopback. Recordings driven from here land under Pulse/Sessions/unassigned/.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Free-form host field with quick-fill buttons for IPv4 and IPv6
    /// loopback. Any hostname or IP is accepted; `DirectTransport`'s
    /// `NIOTSConnectionBootstrap` resolves both stacks via Happy
    /// Eyeballs (ADR §8 dual-stack invariant), so the IPv6 quick-fill
    /// is functional rather than cosmetic.
    private var hostField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Host", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("IPv4") { host = Self.defaultLoopbackV4 }
                    .help("Fill with the IPv4 loopback (127.0.0.1).")
                Button("IPv6") { host = Self.defaultLoopbackV6 }
                    .help("Fill with the IPv6 loopback (::1).")
            }
            Text("Default is the loopback address. Any hostname or IP is accepted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionFields: some View {
        HStack(spacing: 12) {
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
            TextField("Port", value: $port, formatter: portFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 100)
            credentialPicker
            Spacer()
        }
    }

    @ViewBuilder
    private var credentialPicker: some View {
        if credentials.isEmpty {
            Text("No credentials in the local store.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Credential", selection: $selectedCredentialID) {
                Text("Select…").tag(UUID?.none)
                ForEach(credentials, id: \.id) { credential in
                    Text("\(credential.label) (\(credential.tier.label))")
                        .tag(UUID?.some(credential.id))
                }
            }
        }
    }

    private var openButton: some View {
        HStack {
            Button("Open SSH Terminal") {
                guard canOpen,
                      let credentialID = selectedCredentialID
                else { return }
                let trimmedHost = host.trimmingCharacters(in: .whitespaces)
                let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
                activeTarget = .adHoc(
                    host: trimmedHost,
                    port: port,
                    username: trimmedUsername,
                    credentialID: credentialID
                )
            }
            .disabled(!canOpen)
            .keyboardShortcut(.defaultAction)

            Spacer()
        }
    }

    private var canOpen: Bool {
        selectedCredentialID != nil
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && port > 0
            && port <= 65535
    }

    private var portFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 1
        f.maximum = 65535
        return f
    }

    private var outputArea: some View {
        ScrollView {
            Text(output.isEmpty ? "(no replay output)" : output)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .textSelection(.enabled)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// Replay surface. Loads the most-recent session log, fires
    /// biometric to unwrap the per-session AES key, validates the
    /// chain, and renders the recovered plaintext back into the
    /// output panel above. Confirms the recording→encryption→replay
    /// loop is intact for ADR §6 verification step 7.
    ///
    /// Tamper detection: if the chain validator reports a break, the
    /// replay surface renders only the verified prefix and flags the
    /// break in the status line. No plaintext from the tampered
    /// record (or anything after it) reaches the operator —
    /// `SessionLogReplay.load` enforces the cutoff.
    private var replaySection: some View {
        HStack(spacing: 8) {
            Button("Replay last recorded session") {
                Task { await replayLatest() }
            }
            .disabled(isReplaying)
            Spacer()
            if !replayStatus.isEmpty {
                Text(replayStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Inline terminal pane

    /// Replaces the form pane with the operator-facing terminal in
    /// ad-hoc mode. The same byte pump, recording stack, and host-key
    /// mismatch flow as the device-row gesture; only the connection
    /// params come from the form rather than from a SwiftData
    /// `Device` row.
    @ViewBuilder
    private func inlineTerminal(for target: SSHTerminalView.Connection) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("← Back to form") {
                    activeTarget = nil
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            SSHTerminalView(connection: target)
                .environment(seats)
        }
    }

    // MARK: Replay

    /// Loads the most-recent recording on disk, drives the biometric
    /// unwrap path, validates the chain, and renders the recovered
    /// plaintext. ADR §6 verification step 7: the recording→
    /// encryption→replay loop must round-trip cleanly and tamper
    /// detection must withhold post-break plaintext.
    @MainActor
    private func replayLatest() async {
        isReplaying = true
        replayStatus = "Locating most-recent recording…"
        defer { isReplaying = false }

        let entries: [SessionLogRetentionEntry]
        do {
            entries = try FileSystemSessionLogRetentionStore().enumerateSessions()
        } catch {
            replayStatus = "Could not enumerate recordings: \(error)"
            return
        }
        guard let latest = entries.max(by: { $0.openedAt < $1.openedAt }) else {
            replayStatus = "No recordings on disk yet. Connect with a credential whose recordSessions flag is on, then try again."
            return
        }

        // Pull session UUID out of the filename so the audit events
        // get the right identifier. The writer's basename format is
        // `<timestamp>_<sessionUUID>.pulselog`.
        let basename = latest.pulselogURL.deletingPathExtension().lastPathComponent
        let sessionID = basename.split(separator: "_").last.flatMap { UUID(uuidString: String($0)) } ?? UUID()

        replayStatus = "Unwrapping session key (biometric)…"

        let loaded: SessionLogReplay.LoadedSession
        do {
            loaded = try await SessionLogReplay.load(
                pulselogURL: latest.pulselogURL,
                sessionID: sessionID
            )
        } catch {
            replayStatus = "Replay failed: \(error)"
            logger.error("debug replay failed: \(String(describing: error), privacy: .public)")
            return
        }

        // Render recovered plaintext. Direction markers (`>` operator
        // → server, `<` server → operator) so the operator can
        // distinguish what they typed from what came back even when
        // both directions are dense.
        var rendered = ""
        for record in loaded.plaintextRecords {
            guard let payload = Data(base64Encoded: record.bytes),
                  let text = String(data: payload, encoding: .utf8) else {
                continue
            }
            let marker: String
            switch record.dir {
            case .out: marker = "> "
            case .in:  marker = "< "
            }
            rendered.append(marker)
            rendered.append(text)
            if !text.hasSuffix("\n") { rendered.append("\n") }
        }
        output = rendered.isEmpty ? "(empty recording)" : rendered

        switch loaded.validation {
        case .valid(let count, let head):
            replayStatus = "Replayed \(count) record(s); chain head \(head.prefix(12))…"
        case .brokenAt(let seq, let reason):
            replayStatus = "Chain broken at seq \(seq) (\(reason)). Plaintext for records before the break was rendered; everything from the break onward is withheld."
        }
    }
}

#endif
