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
/// The window is a thin verification surface: it picks a `Device`
/// from the SwiftData store and routes through the same
/// `openWindow(value: device.id)` gesture the device-row context
/// menu uses, plus a replay action for inspecting the most-recent
/// recording on disk. There is no separate exec/byte-pump path here;
/// the operator-facing terminal is the single byte-pump entry point
/// and the debug window only delegates to it. Operators doing
/// loopback verification register a `Device` row with
/// `primaryIP = 127.0.0.1` once and reuse it.
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

/// Debug-only window that opens the operator-facing terminal for a
/// chosen `Device` and offers a replay action for the most-recent
/// recording on disk. Replaces the earlier free-form
/// host/credential/exec form that drove the byte pump directly: now
/// every connection path (operator gesture, lab verification) goes
/// through the same SwiftUI terminal scene, so a regression there
/// surfaces in lab regardless of how the operator started the
/// session.
struct DebugSSHWindow: View {

    static let windowID = "debug-ssh"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    /// Devices the operator can target with a terminal session.
    /// Filtered to rows with a non-nil `primaryIP` because the
    /// connect path needs a routable host; sorted by name for a
    /// stable picker. The fetch is unbounded but the operator-curated
    /// device list is small in practice; if a real fleet reaches
    /// thousands the debug menu's picker UX gets revisited at that
    /// time.
    @Query(filter: #Predicate<Device> { $0.primaryIP != nil }, sort: \Device.name)
    private var devices: [Device]

    @State private var selectedDeviceID: Device.ID?
    @State private var output: String = ""
    @State private var replayStatus: String = ""
    @State private var isReplaying: Bool = false

    private let logger = Logger(subsystem: "pulse", category: "ssh.debug")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            devicePicker
            openTerminalButton
            outputArea
            replaySection
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
    }

    // MARK: View sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("SSH connection test", systemImage: "terminal.fill")
                .font(.title2.weight(.semibold))
            Text("Opens the operator-facing terminal for a chosen device, and replays the most-recent recorded session. For loopback verification, register a device with primaryIP = 127.0.0.1.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var devicePicker: some View {
        if devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No devices with a primary IP are in the local store.")
                    .font(.callout)
                Text("Sync devices from NetBox or add a row with primaryIP set (Settings → Devices) to enable the connection test.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("Device", selection: $selectedDeviceID) {
                Text("Select…").tag(Device.ID?.none)
                ForEach(devices) { device in
                    Text("\(device.name ?? "Device \(device.id)") · \(device.primaryIP ?? "")")
                        .tag(Device.ID?.some(device.id))
                }
            }
        }
    }

    private var openTerminalButton: some View {
        HStack {
            Button("Open SSH Terminal") {
                if let id = selectedDeviceID {
                    openWindow(value: id)
                }
            }
            .disabled(selectedDeviceID == nil)
            .keyboardShortcut(.defaultAction)

            Spacer()
        }
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
