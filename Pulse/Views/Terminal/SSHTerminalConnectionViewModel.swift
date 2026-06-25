//
//  SSHTerminalConnectionViewModel.swift
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

import Foundation
import Observation
import OSLog
import SwiftData

/// Owns the operator-facing SSH connection lifecycle, extracted from
/// `SSHTerminalView` (the extraction ADR 0001 §"Forward-looking
/// implementation discipline" deferred and a later pass landed). The view renders
/// `status`/`isRecording`; this type owns the connect → run → teardown
/// flow plus the pure mappings (`statusPillCopy`, `primaryActionShape`,
/// `autoFireAttempt`) and the device-defaults persistence helpers.
///
/// **Why a class driven by the view's `.task`, not its own `Task`.** The
/// view keeps `.task(id: connectionAttempt) { await vm.run(...) }` as the
/// driver, so SwiftUI's auto-cancel-on-dismissal still propagates into
/// `run`'s `await` chain and reaches the deferred `client.close()`. If the
/// VM spawned its own driver `Task`, that cancellation contract would
/// break. The inner `Task` in `run` (pty/shell setup) is a child of the
/// view's task, not a driver, and stays.
///
/// **Push-model injection.** The view-owned collaborators (`surface`,
/// `bellController`, `mismatchCoordinator`), the `@Query` results, and the
/// `ModelContext` cannot be property wrappers on a non-`View`, so they are
/// passed in per attempt via `LifecycleContext` rather than stored. The VM
/// holds only the observable lifecycle state.
@MainActor
@Observable
final class SSHTerminalConnectionViewModel {

    // MARK: Lifecycle contract types

    enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(String)
        case failed(String)
    }

    /// Snapshot of the operator's captured intent for one connection
    /// attempt. The `nonce` lets a repeated attempt with the same
    /// username + credential still re-fire the lifecycle (the view's
    /// `.task(id: connectionAttempt)` keys on `Hashable` equality, and
    /// changing only `nonce` is enough to invalidate). `saveAsDefault`
    /// participates in identity so toggling the form's checkbox between
    /// retries re-fires; auto-fire always produces `saveAsDefault: false`.
    struct ConnectionAttempt: Hashable, Sendable {
        let nonce: UUID
        let username: String
        let credentialID: UUID
        let saveAsDefault: Bool
    }

    /// Shape of the toolbar's context-sensitive primary action. Pure
    /// value type so the status → action mapping is testable without
    /// rendering the toolbar.
    enum PrimaryActionShape: Equatable, Sendable {
        case disconnect
        case reconnect
    }

    // MARK: Observable state

    /// Drives every status-dependent view surface (toolbar pill, endpoint
    /// strip, terminal area, primary action). Observed by `SSHTerminalView`.
    private(set) var status: ConnectionStatus = .idle

    /// Whether the recording badge should show. Flipped on by the
    /// recording-lifecycle registration and off by the session's exit
    /// handler.
    private(set) var isRecording = false

    /// The live client for the current attempt. Internal lifecycle state,
    /// not rendered, so excluded from observation.
    @ObservationIgnored private var sshClient: SSHClient?

    @ObservationIgnored private let logger = Logger(subsystem: "pulse", category: "ssh.session")

    // MARK: Injected per-attempt collaborators

    /// View-owned collaborators and SwiftData handles passed into `run`
    /// per attempt (push model — see the type doc). The VM holds
    /// references for the duration of the call but never owns their
    /// lifetime; the view's `@StateObject`/`@Query` still do.
    struct LifecycleContext {
        let connection: SSHTerminalView.Connection
        let device: Device?
        let credentials: [SSHCredential]
        let modelContext: ModelContext
        let surface: PulseTerminalSurface
        let bellController: TerminalBellController
        let mismatchCoordinator: HostKeyMismatchCoordinator
    }

    // MARK: Connection resolution (pure seam)

    /// Resolved connection parameters for a ready-to-connect attempt.
    struct ResolvedConnection {
        let host: String
        let port: Int
        let deviceID: Int64?
        let username: String
        let credential: SSHCredential
    }

    /// Outcome of resolving an attempt against the current device row and
    /// credential store. The four `.failed` reasons are the operator-facing
    /// guard messages the lifecycle surfaces before any network work.
    enum Resolution {
        case ready(ResolvedConnection)
        case failed(String)
    }

    /// Pure resolution + guard logic, lifted out of `run` so the
    /// operator-facing failure branches (device missing, no primary IP,
    /// credential deleted while the window was open) are testable against
    /// synthetic models without a network stack. Username comes from the
    /// captured attempt, not the device row or the macOS short-name
    /// fallback.
    nonisolated static func resolveConnection(
        connection: SSHTerminalView.Connection,
        attempt: ConnectionAttempt,
        device: Device?,
        credentials: [SSHCredential]
    ) -> Resolution {
        let resolvedHost: String
        let resolvedPort: Int
        let resolvedDeviceID: Int64?

        switch connection {
        case .device(let id):
            guard let device else {
                return .failed("Device \(id) not found in the local store.")
            }
            // `primaryIPAddress` strips the CIDR mask from NetBox's
            // IPAM-stored address (`172.17.255.1/32` → `172.17.255.1`)
            // so NIOSSH can resolve the host. The empty-string guard
            // catches a present-but-blank `primaryIP` and the malformed
            // `"/32"` shape (which strips to empty) uniformly.
            guard let host = device.primaryIPAddress, !host.isEmpty else {
                return .failed("Device has no primary IP configured in NetBox.")
            }
            resolvedHost = host
            resolvedPort = device.preferredSSHPort ?? 22
            resolvedDeviceID = device.id

        case .adHoc(let host, let port, _, _):
            resolvedHost = host
            resolvedPort = port
            resolvedDeviceID = nil
        }

        guard let credential = credentials.first(where: { $0.id == attempt.credentialID }) else {
            return .failed("Credential not found. It may have been deleted while the window was open. Pick another credential to retry.")
        }

        return .ready(
            ResolvedConnection(
                host: resolvedHost,
                port: resolvedPort,
                deviceID: resolvedDeviceID,
                username: attempt.username,
                credential: credential
            )
        )
    }

    // MARK: Connection lifecycle

    /// Drives the full connect → run → teardown lifecycle. Cancellation
    /// (window close, view dismissal, connection-target change) lands as a
    /// `CancellationError` inside the `await` and the `defer` block runs
    /// the close. The captured `attempt` is the operator's snapshot at
    /// Connect-click time; mutating the form while a lifecycle is in
    /// flight does not affect the current attempt.
    func run(attempt: ConnectionAttempt, context: LifecycleContext) async {
        let resolved: ResolvedConnection
        switch Self.resolveConnection(
            connection: context.connection,
            attempt: attempt,
            device: context.device,
            credentials: context.credentials
        ) {
        case .failed(let reason):
            status = .failed(reason)
            return
        case .ready(let value):
            resolved = value
        }

        let credentialID = resolved.credential.id
        let knownHostStore = SwiftDataKnownHostStore(modelContainer: context.modelContext.container)
        let pemProvider: PortablePEMProvider = { [credentialID] in
            let pem = await Configuration.shared.sshPrivateKeyPEM(for: credentialID)
            return pem.map { Data($0.utf8) }
        }

        let client = SSHClient(
            transport: DirectTransport(),
            host: resolved.host,
            port: resolved.port,
            username: resolved.username,
            credentialID: credentialID,
            tier: resolved.credential.tier,
            certificateBlob: resolved.credential.certificate,
            pemProvider: pemProvider,
            knownHostStore: knownHostStore,
            hostKeyMismatchProvider: context.mismatchCoordinator,
            deviceID: resolved.deviceID,
            recordSessions: resolved.credential.recordSessions
        )
        sshClient = client
        status = .connecting

        // Bind `surface` to a local so the defer and the @Sendable handlers
        // capture a Sendable value, not the @MainActor-isolated context.
        let surface = context.surface

        defer {
            // Window-closes-while-connected lands here via task
            // cancellation; the close drives the SSHClient's NIOSSH
            // teardown and the recording writer's finalisation.
            Task { await client.close() }
            sshClient = nil
            // Break the operator-surface retain edges: these closures
            // capture `session`. ADR Verification row 10 (no retain cycles).
            surface.sendHandler = nil
            surface.resizeHandler = nil
            surface.bellHandler = nil
        }

        let session: SSHSession
        do {
            session = try await client.connect()
        } catch {
            logger.error(
                "SSH connect failed for \(resolved.host, privacy: .public):\(resolved.port): \(String(describing: error), privacy: .public)"
            )
            status = .failed("Connection failed: \(error)")
            return
        }

        // Wire the byte pump. setOutputHandler is single-slot by contract;
        // the recording tap already sits in the channel pipeline, so this
        // consumer only sees server-to-operator bytes after the tap.
        await session.setOutputHandler { bytes in
            surface.feed(bytes)
        }
        surface.sendHandler = { bytes in
            Task { await session.write(bytes) }
        }
        surface.resizeHandler = { cols, rows in
            Task { await session.resize(cols: cols, rows: rows) }
        }

        // Bell handler. Reads operator preferences from UserDefaults at
        // fire time (not at wiring time) so a mid-session preference toggle
        // takes effect on the next bell. Both keys default to true.
        let controller = context.bellController
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

        // Recording-indicator off-flip. Registered after `connect`, so it
        // joins the multicast list alongside the audit emitter and the
        // continuation-resume handler below. `[weak self]` breaks the
        // client → session → handler → VM → client retain cycle that the
        // struct-based view never had; the cycle would otherwise only
        // break on close (ADR Verification row 10).
        if resolved.credential.recordSessions {
            await Self.registerRecordingLifecycle(
                register: { handler in await session.addExitHandler(handler) },
                onChange: { [weak self] newValue in self?.isRecording = newValue }
            )
        }

        status = .connected

        // Persist the operator's "Save as default" gesture iff the attempt
        // opted in and we are in device mode. Positioned **after**
        // `status = .connected` so a failed handshake never persists
        // incorrect defaults. Persistence failure does not fail the
        // connection: the session continues and the audit log carries the
        // error.
        await MainActor.run {
            if Self.applyDeviceDefaultsIfRequested(attempt: attempt, device: context.device) {
                do {
                    try context.modelContext.save()
                    logger.info("Saved device defaults (username + credential) for device id \(resolved.deviceID.map(String.init) ?? "ad-hoc", privacy: .public)")
                } catch {
                    logger.error("Failed to save device defaults: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Give SwiftUI a chance to complete its first layout pass for the
        // freshly-mounted PulseTerminalAdapter before reading the terminal
        // grid geometry. `Task.yield()` is not a synchronisation primitive:
        // if layout defers further, the read returns nil and we fall back
        // to 80x24, with the post-shell re-pump catching up. The yield just
        // maximises the probability the initial PTY is allocated at the
        // right size, avoiding the bash readline confusion that SIGWINCH
        // alone cannot fully clean up.
        await Task.yield()

        // Pump 1: read current geometry for the initial PTY allocation;
        // fall back to the SSH protocol default 80x24 if not yet laid out.
        let initialGeometry = await MainActor.run {
            surface.currentTerminalGeometry()
        } ?? (cols: 80, rows: 24)

        // Suspend for the session's lifetime. The exit handler resumes the
        // continuation exactly once; on cancellation the close drives the
        // channel down, `channelInactive` fires `signalExit`, and the
        // late-registration immediate-fire contract resumes the
        // continuation (see SSHSession.addExitHandler). The top-of-function
        // defer then runs the idempotent `client.close()`.
        let exitCause = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ExitCause, Never>) in
                Task {
                    // Register the lifecycle exit handler. A late
                    // registration (session already closed in the brief
                    // window between connect returning and this Task
                    // running) takes the immediate-fire path.
                    await session.addExitHandler { cause in
                        continuation.resume(returning: cause)
                    }
                    // Pump 2: re-read geometry after requestShell and send
                    // an explicit window-change if layout completed between
                    // pumps.
                    await session.requestPTY(
                        cols: initialGeometry.cols,
                        rows: initialGeometry.rows
                    )
                    await session.requestShell()

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
            // View dismissed. Close the client; the exit handler resumes
            // the continuation with a channelError cause and the function
            // returns through the defer.
            Task { await client.close() }
        }

        status = .disconnected("\(exitCause)")
    }

    // MARK: Toolbar copy mappings

    /// One-word status copy for the toolbar status pill. Pure mapping over
    /// `ConnectionStatus`; operator-facing copy is part of the window
    /// contract (pinned by tests) so silent edits land in review.
    nonisolated static func statusPillCopy(for status: ConnectionStatus) -> String {
        switch status {
        case .idle:         return "Idle"
        case .connecting:   return "Connecting"
        case .connected:    return "Connected"
        case .disconnected: return "Disconnected"
        case .failed:       return "Failed"
        }
    }

    /// Primary toolbar action for the given connection status, or nil when
    /// no primary action applies (`.idle`, `.connecting`).
    nonisolated static func primaryActionShape(for status: ConnectionStatus) -> PrimaryActionShape? {
        switch status {
        case .connected:                return .disconnect
        case .disconnected, .failed:    return .reconnect
        case .idle, .connecting:        return nil
        }
    }

    // MARK: Auto-fire gate

    /// Returns an attempt to auto-fire on first appear, or nil if the
    /// operator must fill the form first. For `.device`, requires both
    /// `Device.defaultUsername` and `Device.defaultCredentialID` set and
    /// the credential to exist in the local store. Auto-fired attempts
    /// always carry `saveAsDefault: false` (no silent persistence). Takes
    /// the device's two default fields plus a set of known credential IDs
    /// so it stays testable without standing up SwiftData.
    nonisolated static func autoFireAttempt(
        connection: SSHTerminalView.Connection,
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
            return ConnectionAttempt(
                nonce: UUID(),
                username: trimmed,
                credentialID: credentialID,
                saveAsDefault: false
            )

        case .adHoc(_, _, let username, let credentialID):
            return ConnectionAttempt(
                nonce: UUID(),
                username: username,
                credentialID: credentialID,
                saveAsDefault: false
            )
        }
    }

    // MARK: Recording lifecycle helper

    /// Function type for the exit-handler registrar shape that
    /// `SSHSession.addExitHandler` satisfies. Lets
    /// `registerRecordingLifecycle` accept either a real session call or a
    /// stub registrar in tests, without an `EmbeddedChannel`-backed
    /// `SSHSession`.
    typealias RecordingLifecycleRegistrar = (@escaping @Sendable (ExitCause) -> Void) async -> Void

    /// Wires the recording-status indicator to a session's exit handler.
    /// Calls `onChange(true)` after registration (badge appears) and
    /// `onChange(false)` when the session signals exit (badge clears). The
    /// false-flip is routed through a `Task { @MainActor in ... }` hop so
    /// the EventLoop-thread `signalExit` lands on the main actor. If the
    /// session already exited at registration time, the immediate-fire
    /// contract invokes the handler synchronously; the Task hop ensures the
    /// true-flip runs first, then the deferred false-flip.
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

    // MARK: Device-defaults persistence helpers

    /// Applies the operator's "Save as default" gesture to the device row,
    /// iff `attempt.saveAsDefault` is true and a device was supplied
    /// (ad-hoc connections pass nil and never persist). Returns whether a
    /// write occurred so callers can decide whether to save.
    @MainActor
    static func applyDeviceDefaultsIfRequested(
        attempt: ConnectionAttempt,
        device: Device?
    ) -> Bool {
        guard attempt.saveAsDefault, let device else { return false }
        device.defaultUsername = attempt.username
        device.defaultCredentialID = attempt.credentialID
        return true
    }

    /// Nils both Device default fields atomically. The "Clear saved
    /// defaults" gesture must be symmetric — a half-cleared row is its own
    /// footgun. `SSHCredentialsSettings.deleteCredential` mirrors this
    /// symmetry on credential deletion.
    @MainActor
    static func clearDeviceDefaults(device: Device) {
        device.defaultUsername = nil
        device.defaultCredentialID = nil
    }
}
