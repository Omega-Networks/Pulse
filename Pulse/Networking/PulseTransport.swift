//
//  PulseTransport.swift
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

/// The single outbound seam for byte-level operator traffic to managed infrastructure.
///
/// Both the SSH client and the in-app web companion acquire their underlying `Channel`
/// through this protocol. The default implementation is `DirectTransport`, which opens
/// a TCP connection via `NIOTSConnectionBootstrap` (Apple Network framework). A future
/// `TunnelTransport` substitutes a `Channel` whose I/O is forwarded through Pulse's
/// controlled tunnel, without any change to SSH or web code.
///
/// Per ADR 0001 §8, this protocol stays minimal. If it grows beyond `connect` the
/// abstraction has failed and should be reviewed before extending.
protocol PulseTransport: Sendable {
    /// Opens a connection to `host:port` and returns the resulting `Channel`.
    /// Caller owns the channel lifecycle thereafter; close, error handling, and
    /// channel-pipeline configuration are not this protocol's concern.
    func connect(
        to host: String,
        port: Int,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Channel>
}
