//
//  DirectTransportTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
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

import NIOConcurrencyHelpers
import NIOCore
import NIOTransportServices
import XCTest
@testable import Pulse

final class DirectTransportTests: XCTestCase {

    /// End-to-end loopback round trip. Binds `NIOTSListenerBootstrap` on
    /// `127.0.0.1` at an ephemeral port, installs an echo handler, opens
    /// a connection through `DirectTransport`, writes a known payload, and
    /// confirms the listener-side echo arrives intact. Exercises that
    /// `PulseTransport.connect` returns a usable `Channel` driven by
    /// Apple's Network framework.
    func testLoopbackRoundTrip() throws {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        defer { try? group.syncShutdownGracefully() }

        let listenerChannel = try NIOTSListenerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(EchoHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer { try? listenerChannel.close().wait() }

        guard let port = listenerChannel.localAddress?.port else {
            return XCTFail("Listener did not report a bound port")
        }

        let payload = Array("pulse-transport-roundtrip\n".utf8)
        let received = ReceivedBytes(expecting: payload.count)

        let clientChannel = try DirectTransport()
            .connect(to: "127.0.0.1", port: port, on: group.next())
            .flatMap { channel in
                channel.pipeline.addHandler(CollectorHandler(into: received))
                    .map { channel }
            }
            .wait()
        defer { try? clientChannel.close().wait() }

        var buffer = clientChannel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        try clientChannel.writeAndFlush(buffer).wait()

        wait(for: [received.expectation], timeout: 2.0)
        XCTAssertEqual(received.snapshot(), payload)
    }
}

// MARK: - Handlers

private final class EchoHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}

private final class CollectorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private let received: ReceivedBytes

    init(into received: ReceivedBytes) {
        self.received = received
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received.append(unwrapInboundIn(data))
    }
}

private final class ReceivedBytes: @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NIOLock()
    private var bytes: [UInt8] = []
    private let target: Int

    init(expecting target: Int) {
        self.expectation = XCTestExpectation(description: "received \(target) bytes")
        self.target = target
    }

    func append(_ buffer: ByteBuffer) {
        lock.withLock {
            bytes.append(contentsOf: buffer.readableBytesView)
            if bytes.count >= target {
                expectation.fulfill()
            }
        }
    }

    func snapshot() -> [UInt8] {
        lock.withLock { bytes }
    }
}
