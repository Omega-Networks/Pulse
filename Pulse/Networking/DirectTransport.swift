//
//  DirectTransport.swift
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
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import NIOCore
import NIOTransportServices

/// The v1 `PulseTransport` implementation. Opens a TCP connection through
/// Apple's Network framework via `NIOTSConnectionBootstrap`, which provides
/// Happy Eyeballs, interface transitions, proxy support, and TLS without
/// any of those concerns leaking into SSH or web code.
///
/// A future `TunnelTransport` returns a `Channel` whose I/O is forwarded
/// through Pulse's in-app tunnel; conformance to the same `PulseTransport`
/// protocol means SSH and web code do not change when the tunnel ships.
///
/// Per ADR 0001 §8 this implementation stays small. Connection pooling,
/// retry policy, and host pre-resolution all belong in the caller.
struct DirectTransport: PulseTransport {
    /// Shared event-loop group for direct TCP transport. Network.framework
    /// owns per-connection lifecycles underneath, so a single loop suffices
    /// and explicit shutdown is unnecessary.
    static let sharedEventLoopGroup = NIOTSEventLoopGroup(loopCount: 1)

    func connect(
        to host: String,
        port: Int,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Channel> {
        // 10s default; tunnel callers needing slow-first-hop tolerance must wrap or pass channel options.
        NIOTSConnectionBootstrap(group: eventLoop)
            .connectTimeout(.seconds(10))
            .connect(host: host, port: port)
    }
}
