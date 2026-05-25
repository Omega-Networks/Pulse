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
/// Slice 3 commit 9 owns this surface as the verification artefact —
/// the operator-facing terminal lives in Slice 5 (SwiftTerm-backed
/// `WindowGroup("SSH Terminal", for: Device.ID.self)`); DebugSSHMenu
/// must not become the production path. The file's `#if DEBUG` gate
/// keeps that contract structural rather than conventional.
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

/// SwiftUI scene for the Slice 3 verification flow. Picks a credential
/// and a device with a `primaryIP`, opens an `SSHClient`, runs a one-shot
/// `ls -la /` (or operator-chosen command), captures the output to the
/// view, and emits the same `session.open` / `auth.success` /
/// `session.close` audit events that the production terminal will emit
/// in Slice 5.
struct DebugSSHWindow: View {

    static let windowID = "debug-ssh"

    @Environment(\.modelContext) private var modelContext
    // `@Query` without a fetch limit because credentials are operator-owned
    // and bounded in practice (<50); unlike the device picker that the slice
    // replaced with a free-form host field, this query won't grow with fleet
    // size. If credentials ever cross ~500 the picker UX needs rethinking.
    @Query(sort: \SSHCredential.label) private var credentials: [SSHCredential]

    @State private var selectedCredentialID: UUID?
    @State private var host: String = Self.defaultLoopbackV4
    @State private var username: String = NSUserName()
    @State private var port: Int = 22
    @State private var command: String = "ls -la /"
    @State private var output: String = ""
    @State private var status: String = "Ready"
    @State private var isConnecting: Bool = false
    @State private var replayStatus: String = ""
    @State private var isReplaying: Bool = false

    private static let defaultLoopbackV4 = "127.0.0.1"
    private static let defaultLoopbackV6 = "::1"

    private let logger = Logger(subsystem: "pulse", category: "ssh.debug")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            credentialPicker
            hostField
            connectionFields
            actionRow
            outputArea
            replaySection
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }

    // MARK: View sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Debug SSH (Slice 3 verification)", systemImage: "terminal.fill")
                .font(.title2.weight(.semibold))
            Text("Drives SSHClient end-to-end against a chosen device. Not the operator-facing terminal — that ships in Slice 5.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var credentialPicker: some View {
        Picker("Credential", selection: $selectedCredentialID) {
            Text("Select…").tag(UUID?.none)
            ForEach(credentials, id: \.id) { cred in
                Text("\(cred.label) (\(tierLabel(cred.tier)))")
                    .tag(UUID?.some(cred.id))
            }
        }
    }

    /// Free-form host field with quick-fill buttons for IPv4 and IPv6
    /// loopback. Defaults to `127.0.0.1` because Slice 3 verification runs
    /// against a throwaway sshd on the dev machine; any hostname or IP is
    /// accepted so the same window can drive against staging or a real
    /// device whose `Device.primaryIP` is known. No device picker — at
    /// scale that path runs against a million-row @Query and only the
    /// operator-facing Slice 5 surface justifies the rendering cost.
    /// `DirectTransport`'s `NIOTSConnectionBootstrap` resolves both
    /// stacks via Happy Eyeballs (ADR §8 dual-stack invariant), so the
    /// IPv6 quick-fill is functional rather than cosmetic.
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
            TextField("Port", value: $port, formatter: portFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 100)
            TextField("Command", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var actionRow: some View {
        HStack {
            Button(isConnecting ? "Connecting…" : "Connect & exec") {
                Task { await runOnce() }
            }
            .disabled(!canConnect)
            .keyboardShortcut(.defaultAction)

            Spacer()

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputArea: some View {
        ScrollView {
            Text(output.isEmpty ? "(no output)" : output)
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

    // MARK: Helpers

    private var canConnect: Bool {
        selectedCredentialID != nil
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && port > 0
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
            && !isConnecting
    }

    private var portFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 1
        f.maximum = 65535
        return f
    }

    private func tierLabel(_ tier: SSHCredentialTier) -> String {
        switch tier {
        case .secureEnclave: return "SE"
        case .portable: return "Legacy"
        }
    }

    // MARK: Connection flow

    /// Drives one SSHClient round-trip: connect, install output handler,
    /// exec the command, wait for the session to close, surface the result.
    /// All audit emissions (session.open, auth.success, cert.accepted,
    /// session.close) are produced by SSHClient itself — this method just
    /// drives the bytes and shows the operator-readable result.
    @MainActor
    private func runOnce() async {
        guard
            let credentialID = selectedCredentialID,
            let credential = credentials.first(where: { $0.id == credentialID })
        else {
            status = "Pick a credential first."
            return
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else {
            status = "Enter a host."
            return
        }

        isConnecting = true
        output = ""
        status = "Connecting to \(trimmedHost):\(port)…"
        defer { isConnecting = false }

        let knownHostStore = SwiftDataKnownHostStore(modelContainer: modelContext.container)
        let pemProvider: PortablePEMProvider = { [credentialID] in
            let pem = await Configuration.shared.sshPrivateKeyPEM(for: credentialID)
            return pem.map { Data($0.utf8) }
        }

        let client = SSHClient(
            transport: DirectTransport(),
            host: trimmedHost,
            port: port,
            username: username,
            credentialID: credentialID,
            tier: credential.tier,
            certificateBlob: credential.certificate,
            pemProvider: pemProvider,
            knownHostStore: knownHostStore,
            // Ad-hoc debug-menu connections aren't tied to a NetBox
            // Device row, so recorded sessions (if recording is
            // enabled on the credential) land under
            // Pulse/Sessions/unassigned/ per ADR §6 amendment. When
            // Slice 5 wires up device-row → SSH terminal navigation,
            // those call sites will pass the live `Device.id`.
            deviceID: nil,
            recordSessions: credential.recordSessions
        )

        let collected = OutputCollector()
        let cause: ExitCause
        do {
            let session = try await client.connect()
            await session.setOutputHandler { bytes in
                collected.append(bytes)
            }
            cause = await withCheckedContinuation { cont in
                Task {
                    await session.setExitHandler { resolvedCause in
                        cont.resume(returning: resolvedCause)
                    }
                    do {
                        try await client.exec(command)
                    } catch {
                        cont.resume(returning: .channelError(reason: "\(error)"))
                    }
                }
            }
            await client.close()
        } catch {
            status = "Failed: \(error)"
            logger.error("debug ssh failed: \(String(describing: error), privacy: .public)")
            return
        }

        output = collected.snapshotString()
        status = "Closed (\(cause))"
        logger.debug("debug ssh closed cause=\(String(describing: cause), privacy: .public)")
    }

    /// Find the most-recent recorded session, fire biometric to
    /// unwrap its session key, validate the chain, and render the
    /// recovered plaintext into the output panel. Used to verify
    /// ADR §6 verification step 7 end to end: recorded session is
    /// non-zero, opens to AES-GCM ciphertext, decrypts only via
    /// biometric, hash chain validates, tampering fails cleanly.
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

// MARK: - OutputCollector

/// Lock-backed sink for the bytes the session emits. Mirrors the
/// `LockedBox` pattern from SSHClientTests but with a Swift-side
/// UTF-8 append helper since the debug window renders the result
/// as a `String`.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    func append(_ chunk: ArraySlice<UInt8>) {
        lock.withLock { bytes.append(contentsOf: chunk) }
    }

    func snapshotString() -> String {
        let snapshot = lock.withLock { bytes }
        return String(bytes: snapshot, encoding: .utf8) ?? "<\(snapshot.count) non-UTF-8 bytes>"
    }
}

#endif
