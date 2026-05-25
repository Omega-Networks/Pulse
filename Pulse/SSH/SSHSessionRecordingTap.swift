//
//  SSHSessionRecordingTap.swift
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

/// `ChannelDuplexHandler` that mirrors a session's byte traffic into a
/// `SessionLogWriter` while passing every read and every write through
/// unchanged to the next handler in the pipeline.
///
/// **Placement.** Installed in the SSH child channel pipeline by
/// `SSHClient` immediately before `SSHSessionDataBridge`:
///
///     head → SSHSessionRecordingTap → SSHSessionDataBridge → tail
///
/// In NIO terms: inbound reads enter the tap first (it sees server→client
/// bytes before `SSHSessionDataBridge.deliverOutput` fires); outbound
/// writes from `SSHSession.write` enter the tap last (it sees the same
/// `SSHChannelData(.channel)` payload the wire will carry). Inbound
/// passes through via `context.fireChannelRead`, outbound passes through
/// via `context.write` — the tap is a pure observer of the byte stream.
///
/// **Why this lives separately from `SSHSession`.** The byte pump must
/// stay consumer-agnostic per ADR §6: the next consumer (compliance
/// audit, replay, metrics) shouldn't have to widen `SSHSession`'s
/// surface to attach. The tap is the structural enforcement of that —
/// `grep -n "SessionLogWriter\|RecordingTap" Pulse/SSH/SSHSession.swift`
/// must return empty.
///
/// **Failure semantics.** The tap never blocks the byte pump on a
/// recording failure. Calls to `writer.tryEnqueue(...)` return
/// immediately (synchronous, nonisolated, bounded) and their boolean
/// return is intentionally discarded: a `false` return means the
/// writer has stopped, but the session byte pump must continue
/// delivering bytes to the operator's consumer regardless. The audit
/// signal carries the recording-side failure separately.
///
/// **Direction mapping.** ADR §6's record envelope uses the operator's
/// perspective: `.in` for bytes the server sent back, `.out` for bytes
/// the operator typed and sent to the server. The tap maps NIO's
/// inbound/outbound channel directions onto that vocabulary
/// accordingly.
final class SSHSessionRecordingTap: ChannelDuplexHandler {

    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData

    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    /// Writer the tap mirrors bytes into. Carried via the actor's
    /// nonisolated entry point (`tryEnqueue`) so the EventLoop thread
    /// never hops onto a cooperative-pool worker for the hot path.
    private let writer: SessionLogWriter

    /// Default exit cause description the tap supplies to `close()`
    /// when the channel goes down before any explicit close is invoked
    /// on the writer. The integration in `SSHClient` may instead drive
    /// `close()` directly with the SSHSession's `ExitCause` mapped to
    /// a richer string; this default is the fallback for the
    /// channel-inactive-without-explicit-close path.
    private static let defaultChannelInactiveDescription = "channel_inactive"

    init(writer: SessionLogWriter) {
        self.writer = writer
    }

    // MARK: - Inbound (server → operator)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        recordIfApplicable(channelData: channelData, direction: .in)
        context.fireChannelRead(data)
    }

    // MARK: - Outbound (operator → server)

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let channelData = self.unwrapOutboundIn(data)
        recordIfApplicable(channelData: channelData, direction: .out)
        context.write(data, promise: promise)
    }

    // MARK: - Lifecycle

    func channelInactive(context: ChannelHandlerContext) {
        // The actor's `close()` is `async` and waits to flush the
        // .meta sidecar; we can't await it from this EventLoop thread
        // without blocking the loop, and the channel-inactive
        // lifecycle here is best-effort cleanup. The SSHClient
        // integration in commit 8 may close() the writer directly
        // with a richer `ExitCause`-derived description before the
        // channel goes inactive, in which case this call is a no-op
        // (close is idempotent).
        //
        // Explicit `[writer]` capture rather than implicit `self`
        // keeps the closure region-isolation analysis simple under
        // Swift 6 strict-concurrency: only the actor reference
        // (Sendable) is captured, not the handler.
        let writer = self.writer
        let description = Self.defaultChannelInactiveDescription
        Task {
            await writer.close(exitCauseDescription: description)
        }
        context.fireChannelInactive()
    }

    // MARK: - Helpers

    private func recordIfApplicable(
        channelData: SSHChannelData,
        direction: SessionLogRecord.Direction
    ) {
        // SSH's channel-data type discriminates between `.channel`
        // (stdout) and `.stdErr`. ADR §6 records both directions but
        // doesn't separately track stdout vs stderr in the envelope —
        // operators viewing a replay see the merged stream because
        // the original session would have rendered them into the same
        // pty buffer. SSHSession follows the same merge convention.
        // The tap discards channel-data types it doesn't recognise
        // (none exist in the current SSH wire protocol, but the
        // discriminator is open-ended).
        switch channelData.type {
        case .channel, .stdErr:
            break
        default:
            return
        }

        guard case .byteBuffer(let buffer) = channelData.data else { return }
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        // tryEnqueue is nonisolated and synchronous; the bool return
        // tells us whether the writer accepted, dropped (overflow), or
        // is already stopped. The session byte pump continues
        // regardless — the audit event carries the recording-side
        // failure if any.
        _ = writer.tryEnqueue(direction: direction, bytes: ArraySlice(bytes))
    }
}
