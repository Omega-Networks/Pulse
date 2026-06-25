//
//  SSHSession.swift
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
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import OSLog

// MARK: - SSHSession

/// Byte pump for a single SSH session. Owns one SSH child channel for its
/// lifetime and exposes a closure-based stream surface that the
/// operator-facing SwiftTerm `NSViewRepresentable` hooks into without
/// reshaping the API.
///
/// **The hot-path concurrency model.** The SSHSession exposes an actor-isolated
/// public surface (`write`, `setOutputHandler`, `addExitHandler`, `resize`,
/// `close`) and a `nonisolated` companion for the inbound-data path that
/// dispatches output bytes from the EventLoop straight to the registered
/// handler. The handlers live in an `NIOLockedValueBox` so the EventLoop
/// thread can read them without an actor hop — important for terminal
/// responsiveness — and the actor methods can mutate them with the same
/// lock. Mixing models in one type is unusual but justified: the actor side
/// gives external callers Swift-native isolation, the lock-backed side keeps
/// per-byte delivery off the cooperative thread pool.
actor SSHSession {

    // MARK: Stored state

    /// SSH child channel, scoped to this session. Routed-through-EventLoop ops
    /// are safe because every NIOCore Channel operation dispatches to its
    /// `channel.eventLoop`; the access discipline is honoured by never
    /// touching the channel from the actor's executor directly. Same
    /// pattern as `SSHClient`.
    ///
    /// `internal` rather than `private` so the `requestExec` extension in
    /// `SSHClient.swift` can reach the channel without breaking the
    /// nonisolated-access seam. A Sendable `let` in an actor is implicitly
    /// nonisolated, so no `(unsafe)` is needed.
    nonisolated let childChannel: Channel

    /// Handlers callable from the EventLoop. Backed by an NIO-style locked
    /// box so the inbound data handler can deliver bytes synchronously to
    /// the operator's consumer (a `SwiftTerm.TerminalView` in the
    /// operator-facing terminal window, an `os_log`-backed sink in the
    /// debug verification menu) without paying for an actor hop per chunk.
    private nonisolated let handlers = NIOLockedValueBox<Handlers>(.init())

    let openedAt: Date
    private let logger = Logger(subsystem: "pulse", category: "ssh.session")

    /// Tracks whether `close()` has run so a second call is a no-op.
    private var closed = false

    // MARK: Init

    init(childChannel: Channel, openedAt: Date = .now) {
        self.childChannel = childChannel
        self.openedAt = openedAt
    }

    // MARK: Actor-isolated API

    /// Write a chunk of bytes to the server's stdin. The bytes are wrapped in
    /// an `SSHChannelData(.channel)` message and dispatched to the child
    /// channel's EventLoop. Errors during write are absorbed (the session's
    /// exit handler will fire when the channel closes); callers that need
    /// per-write feedback should observe the exit handler instead.
    func write(_ bytes: ArraySlice<UInt8>) async {
        guard !closed else { return }
        var buffer = childChannel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        _ = try? await childChannel.writeAndFlush(payload).get()
    }

    /// Installs the output handler. Called by the byte-pump consumer
    /// (`DebugSSHMenu` for the verification flow; the operator-facing
    /// SwiftTerm window in production). Replaces any previously-set
    /// handler; passing `nil` is equivalent to discarding output silently.
    func setOutputHandler(_ handler: (@Sendable (ArraySlice<UInt8>) -> Void)?) {
        handlers.withLockedValue { $0.output = handler }
    }

    /// Registers a handler to be invoked exactly once when the session
    /// transitions to inactive. Multiple handlers may be registered and fire
    /// in registration order; this is the multicast seam that lets the audit
    /// subsystem (`SSHClient.connect`), the lifecycle wrapper
    /// (`SSHTerminalView.runConnectionLifecycle`), and future consumers
    /// (recording-status indicator, metrics, compliance taps) attach without
    /// competing for a single slot.
    ///
    /// If the session has already exited at the time of registration, the
    /// handler is invoked synchronously on the calling thread with the
    /// recorded `ExitCause`. Without this immediate-fire path, a fast
    /// handshake-then-drop sequence between two registration sites would
    /// silently strand the second registrant (the lifecycle wrapper's
    /// continuation would suspend forever).
    ///
    /// Handlers must be cheap, must not throw, and must not block. Swift
    /// cannot catch synchronous traps from within the calling task, so the
    /// per-handler call boundary is the isolation seam, not a `do/catch`
    /// wrapper. Misbehaving handlers will affect subsequent registrants;
    /// keep them small.
    func addExitHandler(_ handler: @escaping @Sendable (ExitCause) -> Void) {
        let immediate: ExitCause? = handlers.withLockedValue { box in
            if box.exitDelivered {
                return box.deliveredCause
            }
            box.exitHandlers.append(handler)
            return nil
        }
        if let cause = immediate {
            handler(cause)
        }
    }

    /// Sends an `exec` channel request to the server. Called by `SSHClient`'s
    /// public `exec(_:)` after the session opens to run a one-shot command.
    /// The debug verification menu uses this path; the operator-facing
    /// SwiftTerm consumer switches to `pty-req` + `shell` instead.
    /// Errors during the request land on the inbound handler path (which
    /// signals the session's exit handler) so callers don't observe a
    /// separate failure.
    func requestExec(_ command: String) async {
        guard !closed else { return }
        let event = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        _ = try? await childChannel.triggerUserOutboundEvent(event).get()
    }

    /// Sends a `pty-req` SSH channel request to allocate a pseudo-
    /// terminal on the server. Operator-facing shell mode requires this
    /// before `requestShell()`; the debug verification menu's exec path
    /// does not. `term` controls the server's `TERM` environment
    /// variable and therefore which terminal-capabilities database
    /// (`terminfo`) the shell uses. `xterm-256color` matches what
    /// SwiftTerm emits for VT100 + 256-colour SGR support and pairs
    /// with the verified-coverage check in the slice plan.
    ///
    /// `wantReply: false` matches the shape of `requestExec` and
    /// `resize`: the SSH protocol replies with success or failure on a
    /// pty-req, but Pulse's v1 surface does not observe the reply.
    /// Servers that refuse pty-req leave the operator with an
    /// unresponsive terminal; in practice every real device this slice
    /// targets allocates a PTY for interactive shell. A future
    /// hardening would handle `ChannelSuccessEvent` /
    /// `ChannelFailureEvent` from NIOSSH and surface the rejection.
    func requestPTY(
        term: String = "xterm-256color",
        cols: Int,
        rows: Int
    ) async {
        guard !closed else { return }
        let event = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        _ = try? await childChannel.triggerUserOutboundEvent(event).get()
    }

    /// Sends a `shell` SSH channel request to launch the server's
    /// default login shell on the allocated PTY. Must follow a
    /// successful `requestPTY` call; without a PTY the server may
    /// silently degrade to a `dumb` terminal or refuse the request.
    /// `wantReply: false` for symmetry with the other channel-request
    /// methods; see `requestPTY` for the rationale and the rejection
    /// caveat.
    func requestShell() async {
        guard !closed else { return }
        let event = SSHChannelRequestEvent.ShellRequest(wantReply: false)
        _ = try? await childChannel.triggerUserOutboundEvent(event).get()
    }

    /// Sends a `window-change` SSH channel request to update the PTY
    /// dimensions. The debug verification menu doesn't drive resize; the
    /// method is shaped for the operator-facing terminal view, which calls
    /// this on every `GeometryReader` frame change.
    func resize(cols: Int, rows: Int) async {
        guard !closed else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        _ = try? await childChannel.triggerUserOutboundEvent(event).get()
    }

    /// Closes the session. Idempotent: a second call is a no-op. The child
    /// channel's close future drives the exit-handler invocation through the
    /// inbound handler's `channelInactive` callback, so callers don't need
    /// to coordinate close + exit ordering.
    func close() async {
        guard !closed else { return }
        closed = true
        // Drop the output handler so the session stops retaining the
        // operator's terminal surface (the `feed` closure captures it).
        // signalExit clears the exit handlers on its latch; clearing
        // output here closes the SSHSession -> PulseTerminalSurface edge on
        // teardown so the surface can deinit. ADR Verification row 10.
        handlers.withLockedValue { $0.output = nil }
        _ = try? await childChannel.close().get()
    }

    deinit {
        // ADR Verification row 10: observable deinit line confirms the
        // session actor is released on teardown.
        logger.notice("SSHSession deinit")
    }

    // MARK: Nonisolated hot path (called from the EventLoop)

    /// Delivers a chunk of output bytes to the registered handler. Called by
    /// `SSHSessionDataBridge` from the EventLoop on every inbound
    /// `SSHChannelData(.channel)` read. The lock-backed handler box lets us
    /// dispatch synchronously without paying for an actor hop per chunk.
    nonisolated func deliverOutput(_ buffer: ByteBuffer) {
        guard let handler = handlers.withLockedValue({ $0.output }) else { return }
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        handler(ArraySlice(bytes))
    }

    /// Stderr arrives as an `SSHChannelData(.stdErr)` message. For
    /// terminal use, stdout and stderr are typically merged into the same
    /// byte stream because the operator sees a single pty buffer. The
    /// recording tap and the debug verification menu follow the same
    /// convention; a future consumer can split if its use case demands it.
    nonisolated func deliverStderr(_ buffer: ByteBuffer) {
        deliverOutput(buffer)
    }

    /// Invoked by the inbound handler when the child channel closes. Picks
    /// up any recorded exit status (set by the inbound handler in response
    /// to an `SSHChannelRequestEvent.ExitStatus`), maps to an `ExitCause`,
    /// and invokes each registered exit handler exactly once in registration
    /// order. The `recordedExitStatus` snapshot lives in the same lock-backed
    /// box so the handlers can be resolved synchronously without an actor hop.
    ///
    /// Handlers fire outside the lock so a slow or misbehaving handler does
    /// not block subsequent `addExitHandler` calls — though those calls will
    /// take the late-registration immediate-fire path because `exitDelivered`
    /// is already set.
    nonisolated func signalExit(_ cause: ExitCause) {
        enum Resolution {
            case deliver([@Sendable (ExitCause) -> Void], ExitCause)
            case alreadyDelivered
        }
        let resolution = handlers.withLockedValue { box -> Resolution in
            // Latch: only the first signal fires the handlers.
            guard !box.exitDelivered else { return .alreadyDelivered }
            box.exitDelivered = true
            // If the channel went down with a generic close but the server
            // already reported an exit status, prefer the remote-exit cause.
            let chosenCause: ExitCause
            if case .channelError = cause, let status = box.recordedExitStatus {
                chosenCause = .remoteExit(status)
            } else {
                chosenCause = cause
            }
            box.deliveredCause = chosenCause
            let snapshot = box.exitHandlers
            // Drop the handler refs once delivery is latched. Late
            // registrants are served by the immediate-fire path on
            // `addExitHandler` reading `deliveredCause`.
            box.exitHandlers.removeAll()
            return .deliver(snapshot, chosenCause)
        }
        if case let .deliver(snapshot, chosenCause) = resolution {
            for handler in snapshot {
                handler(chosenCause)
            }
        }
    }

    /// Recorded by the inbound handler in response to
    /// `SSHChannelRequestEvent.ExitStatus`. `signalExit` reads it on close.
    nonisolated func recordExitStatus(_ status: Int32) {
        handlers.withLockedValue { $0.recordedExitStatus = status }
    }

    // MARK: Internal handler payload

    /// Lock-backed payload shared between the actor-isolated public API
    /// (which mutates the closures) and the EventLoop-side nonisolated
    /// methods (which read them on the hot path).
    private struct Handlers: Sendable {
        var output: (@Sendable (ArraySlice<UInt8>) -> Void)?
        /// Multicast list of exit handlers. Iterated in registration order
        /// on `signalExit`; cleared once the latch flips so late registrants
        /// take the immediate-fire path from `deliveredCause`.
        var exitHandlers: [@Sendable (ExitCause) -> Void] = []
        /// Records the cause delivered on the first `signalExit` call, so a
        /// handler registered after delivery can be invoked synchronously
        /// with the same cause.
        var deliveredCause: ExitCause?
        var recordedExitStatus: Int32?
        var exitDelivered: Bool = false
    }
}

// MARK: - SSHSessionDataBridge

/// `ChannelDuplexHandler` installed on the SSH child channel by `SSHClient`
/// at session-open. Forwards inbound `SSHChannelData` to the `SSHSession`'s
/// nonisolated delivery surface and converts exit-status + close events into
/// `ExitCause` signals.
///
/// Pattern modeled on swift-nio-ssh's `ExampleExecHandler`, simplified
/// because Pulse doesn't need the per-handler `EventLoopPromise<Int>`
/// scaffold — `SSHSession` owns the lifecycle directly via the exit handler
/// closure.
final class SSHSessionDataBridge: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    /// Outbound payload type matches what `SSHSession.write` actually
    /// emits: a fully-wrapped `SSHChannelData(.channel, .byteBuffer)`.
    /// The earlier `ByteBuffer` declaration was a latent type mismatch:
    /// NIO's `unwrapOutboundIn` force-casts, so the first call to
    /// `SSHSession.write` would have crashed the byte pump.
    /// Currently dormant because no production path drives outbound
    /// writes (the debug menu uses `triggerUserOutboundEvent` for
    /// `exec`); the operator-facing terminal's keystroke path will be
    /// the first caller, and this declaration keeps it safe.
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let session: SSHSession

    init(session: SSHSession) {
        self.session = session
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        switch channelData.type {
        case .channel:
            session.deliverOutput(buffer)
        case .stdErr:
            session.deliverStderr(buffer)
        default:
            // Unknown channel-data type; drop. SSH protocol only defines
            // .channel and .stdErr so this branch is defensive.
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exit as SSHChannelRequestEvent.ExitStatus:
            session.recordExitStatus(Int32(exit.exitStatus))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // The child channel went down. SSHSession picks the right ExitCause
        // based on whether an exit status was recorded earlier.
        session.signalExit(.channelError(reason: "child channel inactive"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        session.signalExit(.channelError(reason: String(describing: error)))
        context.close(promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // `SSHSession.write` already builds the `SSHChannelData(.channel, .byteBuffer)`
        // payload; the bridge just forwards. The previous implementation
        // rewrapped a `ByteBuffer` into `SSHChannelData`, which made the
        // `OutboundIn = ByteBuffer` declaration consistent on paper but
        // never matched what `SSHSession.write` actually emits. The
        // forward-only shape is correct for either direction of future
        // call site.
        context.write(data, promise: promise)
    }
}
