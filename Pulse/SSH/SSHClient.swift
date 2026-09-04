//
//  SSHClient.swift
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
import NIOCore
import NIOSSH
import NIOTransportServices
import OSLog

// MARK: - Errors

enum SSHClientError: Error, CustomStringConvertible, Equatable {
    case transportConnectFailed(reason: String)
    case sshHandshakeFailed(reason: String)
    case sessionChannelOpenFailed(reason: String)
    case execRequestFailed(reason: String)
    case alreadyConnected

    var description: String {
        switch self {
        case .transportConnectFailed(let reason):
            return "SSH transport connect failed: \(reason)"
        case .sshHandshakeFailed(let reason):
            return "SSH handshake failed: \(reason)"
        case .sessionChannelOpenFailed(let reason):
            return "SSH session channel open failed: \(reason)"
        case .execRequestFailed(let reason):
            return "SSH exec request failed: \(reason)"
        case .alreadyConnected:
            return "SSHClient is single-use and has already been connected."
        }
    }
}

// MARK: - SSHClient

/// Owns the lifecycle of a single SSH session from TCP connect through
/// session-channel open. Stitches `PulseTransport` to NIOSSH's
/// `NIOSSHHandler`, installing both the auth delegate and the host-key
/// delegate on the pipeline.
///
/// **Per-session, not per-device.** One `SSHClient` instance maps to one
/// SSH session. Operators that open multiple sessions to the same device
/// construct multiple `SSHClient`s. There's no pooling: the per-session
/// memory cost is small (a few KB), the connection-setup cost is bounded by
/// the handshake, and pooling would introduce state-machine complexity the
/// v1 surface doesn't need.
///
/// **Channel concurrency.** NIOCore's `Channel` is non-Sendable but its
/// methods dispatch internally to the channel's `EventLoop`. The actor
/// stores the channel as `nonisolated(unsafe)` and reaches it through
/// EventLoopFuture chains that return Sendable snapshots
/// (`SSHSession` itself, error values) across the actor boundary. Do not
/// "optimise" by inlining channel work onto the actor's executor: that would
/// race with the EventLoop's dispatcher. Same pattern as `SSHHostKeyDelegate`.
actor SSHClient {

    // MARK: Configuration

    private let transport: PulseTransport
    private let host: String
    private let port: Int
    private let username: String
    private let credentialID: UUID
    private let tier: SSHCredentialTier
    private let certificateBlob: Data?
    private let pemProvider: PortablePEMProvider
    private let knownHostStore: any KnownHostStore

    /// Optional UI-side provider that surfaces a sheet when the
    /// presented host key differs from the stored TOFU pin. `nil`
    /// (the default) means the delegate falls back to the
    /// reject-unconditionally legacy behaviour; the connecting
    /// view (`SSHTerminalView`) sets a `HostKeyMismatchCoordinator`
    /// here to enable the operator-decision flow.
    private let hostKeyMismatchProvider: (any HostKeyMismatchDecisionProvider)?

    /// `Device.id` of the NetBox device this connection is attached
    /// to, or `nil` for ad-hoc connections (debug menu, devices not
    /// imported from NetBox). Required — no default — so call sites
    /// have to pass `nil` deliberately and visibly rather than
    /// silently landing recorded logs under `unassigned/`. See ADR §6
    /// amendment.
    private let deviceID: Int64?

    /// Whether to record this session to a `.pulselog` + `.meta` pair
    /// per ADR §6. Driven by the credential's `recordSessions` flag at
    /// the call site (a snapshot rather than a SwiftData lookup
    /// because `SSHClient` is the byte-pump layer, not the model
    /// layer).
    private let recordSessions: Bool

    // MARK: State

    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    private var session: SSHSession?
    private var authDelegate: SSHAuthDelegate?
    private var connectStartedAt: Date?

    /// Session-log writer for this connection, populated when
    /// `recordSessions == true` and the writer opened successfully.
    /// `close()` finalises it; the recording tap installed in the
    /// child-channel pipeline also calls `close()` on
    /// `channelInactive` (idempotent) so the .meta sidecar always
    /// gets finalised whichever path the disconnect runs through.
    private var sessionLogWriter: SessionLogWriter?

    private let sessionLogger = Logger(subsystem: "pulse", category: "ssh.session")
    private let authLogger = Logger(subsystem: "pulse", category: "ssh.auth")
    private let certLogger = Logger(subsystem: "pulse", category: "ssh.certificates")

    // MARK: Init

    init(
        transport: PulseTransport,
        host: String,
        port: Int,
        username: String,
        credentialID: UUID,
        tier: SSHCredentialTier,
        certificateBlob: Data? = nil,
        pemProvider: @escaping PortablePEMProvider,
        knownHostStore: any KnownHostStore,
        hostKeyMismatchProvider: (any HostKeyMismatchDecisionProvider)? = nil,
        deviceID: Int64?,
        recordSessions: Bool
    ) {
        self.transport = transport
        self.host = host
        self.port = port
        self.username = username
        self.credentialID = credentialID
        self.tier = tier
        self.certificateBlob = certificateBlob
        self.pemProvider = pemProvider
        self.knownHostStore = knownHostStore
        self.hostKeyMismatchProvider = hostKeyMismatchProvider
        self.deviceID = deviceID
        self.recordSessions = recordSessions
    }

    // MARK: Connect

    /// Opens the SSH session and returns the byte pump ready for the consumer
    /// to install handlers and write commands.
    ///
    /// Sequence:
    /// 1. Acquire a Channel via `PulseTransport`.
    /// 2. Add `NIOSSHHandler` to the pipeline with the user-auth and
    ///    server-auth delegates.
    /// 3. Wait for the SSH handshake to complete by opening a session child
    ///    channel via `NIOSSHHandler.createChannel`. Success implies the
    ///    handshake succeeded (host key accepted, auth completed).
    /// 4. Install `SSHSessionDataBridge` on the child channel so inbound
    ///    `SSHChannelData` flows to the `SSHSession`'s handler.
    /// 5. Emit `session.open` and `auth.success` (with `cert.accepted`
    ///    qualifier if the delegate offered a cert).
    /// 6. Return the `SSHSession` to the caller, who installs output / exit
    ///    handlers and starts writing.
    func connect() async throws -> SSHSession {
        guard channel == nil else {
            throw SSHClientError.alreadyConnected
        }
        connectStartedAt = .now

        // 1. Build the EventLoopGroup. Pulse's v1 default transport uses
        // Apple's Network.framework under the hood, so we hand it a matching
        // NIO-TransportServices event-loop group. Future TunnelTransport
        // implementations may need a different group type; if/when that
        // lands the group becomes a constructor parameter. For now the
        // coupling stays inside `connect()` so callers don't have to know.
        let group = NIOTSEventLoopGroup(loopCount: 1)
        eventLoopGroup = group
        let eventLoop = group.next()

        // 2. Connect via the transport seam.
        let openedChannel: Channel
        do {
            openedChannel = try await transport.connect(to: host, port: port, on: eventLoop).get()
        } catch {
            sessionLogger.warning(
                "session.open user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port) result=transport-failed reason=\(String(describing: error), privacy: .public)"
            )
            try? await group.shutdownGracefully()
            throw SSHClientError.transportConnectFailed(reason: String(describing: error))
        }

        // 3. Construct the two delegates. The host-key delegate consults
        // SwiftData-backed KnownHost rows for TOFU + HostTrust evaluation;
        // the auth delegate drives the user-auth state machine and emits
        // the cert.*/auth.* audit events from §7.
        let hostKeyDelegate = SSHHostKeyDelegate(
            host: host,
            port: port,
            store: knownHostStore,
            mismatchDecisionProvider: hostKeyMismatchProvider
        )
        let authDelegate = SSHAuthDelegate(
            username: username,
            host: host,
            port: port,
            credentialID: credentialID,
            tier: tier,
            certificateBlob: certificateBlob,
            pemProvider: pemProvider
        )
        self.authDelegate = authDelegate

        // 4. Install NIOSSHHandler on the pipeline. Modeled on the
        // swift-nio-ssh client example (Sources/NIOSSHClient/main.swift).
        let sshHandler = NIOSSHHandler(
            role: .client(.init(
                userAuthDelegate: authDelegate,
                serverAuthDelegate: hostKeyDelegate
            )),
            allocator: openedChannel.allocator,
            inboundChildChannelInitializer: nil
        )
        do {
            // NIOSSHHandler is not Sendable. It was created on this
            // channel and is added on the same event loop; it is not
            // shared across tasks.
            nonisolated(unsafe) let handler = sshHandler
            try await openedChannel.pipeline.addHandler(handler).get()
        } catch {
            try? await openedChannel.close().get()
            try? await group.shutdownGracefully()
            sessionLogger.warning(
                "session.open user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port) result=pipeline-failed reason=\(String(describing: error), privacy: .public)"
            )
            throw SSHClientError.sshHandshakeFailed(reason: String(describing: error))
        }
        channel = openedChannel

        // 4.5. Open the session-log writer if recording is enabled for
        // this credential. Open before the session so the writer's
        // own audit-trail (session.recording.opened) lands inside the
        // surrounding session.open context, and so a wrap-side
        // failure can be surfaced without bringing down the byte
        // pump. Per ADR §6 ("recording failure never propagates into
        // the byte pump") a failure here logs and continues with no
        // recording attached — the session itself proceeds normally.
        if recordSessions {
            do {
                self.sessionLogWriter = try await SessionLogWriter.open(
                    deviceID: deviceID,
                    credentialID: credentialID,
                    username: username,
                    host: host,
                    port: port
                )
            } catch {
                sessionLogger.error(
                    "session.recording.open failed; session continues without recording: \(String(describing: error), privacy: .public)"
                )
                self.sessionLogWriter = nil
            }
        }

        // 5. Open the session child channel. NIOSSH performs the handshake
        // (key exchange, host-key validation via the host-key delegate, user
        // auth via the auth delegate) before this future resolves.
        let session = try await openSessionChildChannel(parent: openedChannel)
        self.session = session

        // 6. Audit-trail emissions. session.open + auth.success once each
        // per attempt (ADR §7); the auth delegate already emitted
        // cert.accepted at offer time if a cert was presented, but on
        // session-open we know the server accepted it — log the post-hoc
        // confirmation under ssh.certificates with the additional context.
        sessionLogger.info(
            "session.open user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port) credential=\(self.credentialID, privacy: .public)"
        )
        authLogger.info(
            "auth.success user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port) credential=\(self.credentialID, privacy: .public)"
        )
        if authDelegate.didOfferCertificate {
            // Post-hoc cert acceptance: the delegate emitted `cert.offered`
            // at presentation time; this `cert.accepted` confirms the
            // server actually accepted the offered cert (we'd be in a
            // different code path on rejection — see `cert.rejected`).
            certLogger.info(
                "cert.accepted user=\(self.username, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port)"
            )
        }

        // Wire up close-time auditing through the session's exit handler so
        // session.close lands whatever path the channel closes through.
        let host = self.host
        let port = self.port
        let username = self.username
        let credentialID = self.credentialID
        let openedAt = self.connectStartedAt ?? .now
        let sessionLogger = self.sessionLogger
        await session.addExitHandler { cause in
            let durationMs = Int(Date().timeIntervalSince(openedAt) * 1000)
            sessionLogger.info(
                "session.close user=\(username, privacy: .public) host=\(host, privacy: .public) port=\(port) credential=\(credentialID, privacy: .public) cause=\(String(describing: cause), privacy: .public) durationMs=\(durationMs)"
            )
        }

        return session
    }

    /// Asks the upstream `NIOSSHHandler` to open a child channel of type
    /// `.session`. The child carries the SSH session's command-line +
    /// PTY traffic; `SSHSessionDataBridge` routes data to / from the
    /// `SSHSession` actor.
    private func openSessionChildChannel(parent: Channel) async throws -> SSHSession {
        let promise = parent.eventLoop.makePromise(of: SSHSession.self)

        // Look up the handler we just installed. The closure runs on the
        // parent's EventLoop. NIOSSHHandler is not Sendable; it is not
        // stored or shared across tasks.
        let sshHandler: NIOSSHHandler
        do {
            nonisolated(unsafe) let fetched = try await parent.pipeline.handler(
                type: NIOSSHHandler.self
            ).get()
            sshHandler = fetched
        } catch {
            throw SSHClientError.sshHandshakeFailed(
                reason: "NIOSSHHandler missing from pipeline: \(String(describing: error))"
            )
        }

        // Capture the writer (if any) for the child-channel-side
        // closure. The closure runs on the child's EventLoop off the
        // actor; an actor reference is Sendable so the capture is
        // safe under Swift 6 strict-concurrency.
        let writer = self.sessionLogWriter

        // Build the child channel + (optional tap) + bridge. The init
        // closure runs on the child's EventLoop and configures the
        // pipeline before NIOSSH returns the new channel to us.
        sshHandler.createChannel(nil) { childChannel, channelType in
            guard channelType == .session else {
                return childChannel.eventLoop.makeFailedFuture(
                    SSHClientError.sessionChannelOpenFailed(reason: "unexpected channel type: \(channelType)")
                )
            }
            return childChannel.eventLoop.makeCompletedFuture {
                let session = SSHSession(childChannel: childChannel)

                // Install the recording tap BEFORE the bridge if
                // recording is enabled. Pipeline order from head to
                // tail: [head, tap, bridge, tail]. Inbound flows
                // head→tail, so the tap sees server bytes first and
                // forwards via fireChannelRead to the bridge. Outbound
                // flows tail→head, so the tap sees outgoing bytes
                // last on their way to the wire. The tap is a pure
                // observer — it forwards every read and write
                // unchanged, only mirroring into the writer.
                if let writer {
                    let tap = SSHSessionRecordingTap(writer: writer)
                    try childChannel.pipeline.syncOperations.addHandler(tap)
                }

                let bridge = SSHSessionDataBridge(session: session)
                try childChannel.pipeline.syncOperations.addHandler(bridge)
                promise.succeed(session)
            }
        }

        do {
            return try await promise.futureResult.get()
        } catch {
            throw SSHClientError.sessionChannelOpenFailed(reason: String(describing: error))
        }
    }

    /// Triggers an `exec` channel request against the open session. Used
    /// by `DebugSSHMenu` to run a one-shot command (e.g., `ls -la /`)
    /// without setting up a full PTY. The operator-facing SwiftTerm
    /// surface uses a `pty-req` + `shell` pair instead.
    func exec(_ command: String) async throws {
        guard let session else {
            throw SSHClientError.execRequestFailed(reason: "session not yet open")
        }
        await session.requestExec(command)
    }

    // MARK: Close

    /// Closes the SSH session and tears down the underlying channel +
    /// EventLoopGroup. Idempotent.
    ///
    /// If a recording is active, finalises the writer with a generic
    /// "client_close" exit description. The recording tap's
    /// `channelInactive` may also fire close (when the channel goes
    /// down before this method runs) — close is idempotent, so
    /// whichever path completes first wins and the second is a
    /// no-op. .meta carries the truth.
    func close() async {
        await session?.close()
        if let writer = sessionLogWriter {
            await writer.close(exitCauseDescription: "client_close")
        }
        if let channel {
            _ = try? await channel.close().get()
        }
        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        session = nil
        channel = nil
        eventLoopGroup = nil
        sessionLogWriter = nil
    }

    deinit {
        // ADR Verification row 10: an observable deinit line confirms the
        // client actor is released on window close, not held by a stray
        // closure. Filter with `category BEGINSWITH "ssh"`.
        sessionLogger.notice("SSHClient deinit")
    }
}
