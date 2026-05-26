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
/// lifetime and exposes a closure-based stream surface that the Slice 5
/// SwiftTerm `NSViewRepresentable` will hook into without reshaping the API.
///
/// **The hot-path concurrency model.** The SSHSession exposes an actor-isolated
/// public surface (`write`, `setOutputHandler`, `setExitHandler`, `resize`,
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
    /// `channel.eventLoop`; the `@unchecked Sendable` contract is honoured by
    /// never touching the channel from the actor's executor directly. Same
    /// pattern as `SSHClient` (commit ea34d22 reminder).
    ///
    /// `internal` rather than `private` so the `requestExec` extension in
    /// `SSHClient.swift` can reach the channel without breaking the
    /// nonisolated-access seam.
    nonisolated(unsafe) let childChannel: Channel

    /// Handlers callable from the EventLoop. Backed by an NIO-style locked
    /// box so the inbound data handler can deliver bytes synchronously to
    /// the operator's consumer (a `SwiftTerm.TerminalView` in Slice 5, an
    /// `os_log` callback in Slice 3's debug menu) without paying for an
    /// actor hop per chunk.
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
    /// (`DebugSSHMenu` in Slice 3; SwiftTerm in Slice 5). Replaces any
    /// previously-set handler; passing `nil` is equivalent to discarding
    /// output silently.
    func setOutputHandler(_ handler: (@Sendable (ArraySlice<UInt8>) -> Void)?) {
        handlers.withLockedValue { $0.output = handler }
    }

    /// Installs the exit handler. Invoked exactly once per session when the
    /// child channel closes, with the `ExitCause` reflecting the close
    /// reason (clean remote exit, transport drop, etc.).
    func setExitHandler(_ handler: (@Sendable (ExitCause) -> Void)?) {
        handlers.withLockedValue { $0.exit = handler }
    }

    /// Sends an `exec` channel request to the server. Called by `SSHClient`'s
    /// public `exec(_:)` after the session opens to run a one-shot command
    /// (Slice 3's debug-menu path uses this; Slice 5's SwiftTerm consumer
    /// will switch to `pty-req` + `shell` instead). Errors during the
    /// request land on the inbound handler path (which signals the session's
    /// exit handler) so callers don't observe a separate failure.
    func requestExec(_ command: String) async {
        guard !closed else { return }
        let event = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        _ = try? await childChannel.triggerUserOutboundEvent(event).get()
    }

    /// Sends a `window-change` SSH channel request to update the PTY
    /// dimensions. Slice 3's debug menu doesn't drive resize; the method is
    /// shaped for Slice 5's terminal view, which will call this on every
    /// `GeometryReader` frame change.
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
        _ = try? await childChannel.close().get()
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

    /// Stderr arrives as an `SSHChannelData(.stdErr)` message. For terminal
    /// use (Slice 5 SwiftTerm), stdout and stderr are typically merged into
    /// the same byte stream because the operator sees a single pty buffer.
    /// Slice 3 follows the same convention; downstream slices can split if
    /// the use case demands it.
    nonisolated func deliverStderr(_ buffer: ByteBuffer) {
        deliverOutput(buffer)
    }

    /// Invoked by the inbound handler when the child channel closes. Picks
    /// up any recorded exit status (set by the inbound handler in response
    /// to an `SSHChannelRequestEvent.ExitStatus`), maps to an `ExitCause`,
    /// and invokes the exit handler exactly once. The `recordedExitStatus`
    /// snapshot lives in the same lock-backed box so the handler can read
    /// it synchronously without an actor hop.
    nonisolated func signalExit(_ cause: ExitCause) {
        struct Resolution {
            let cause: ExitCause
            let handler: (@Sendable (ExitCause) -> Void)?
        }
        let resolution = handlers.withLockedValue { box -> Resolution in
            // Latch: only the first signal fires the handler.
            guard !box.exitDelivered else {
                return Resolution(cause: cause, handler: nil)
            }
            box.exitDelivered = true
            // If the channel went down with a generic close but the server
            // already reported an exit status, prefer the remote-exit cause.
            let chosenCause: ExitCause
            if case .channelError = cause, let status = box.recordedExitStatus {
                chosenCause = .remoteExit(status)
            } else {
                chosenCause = cause
            }
            return Resolution(cause: chosenCause, handler: box.exit)
        }
        resolution.handler?(resolution.cause)
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
        var exit: (@Sendable (ExitCause) -> Void)?
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
