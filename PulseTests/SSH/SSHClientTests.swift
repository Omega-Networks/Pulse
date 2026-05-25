//
//  SSHClientTests.swift
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
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import NIOCore
import NIOEmbedded
import XCTest
@testable import Pulse

// MARK: - SSHSession structural tests

final class SSHSessionTests: XCTestCase {

    private func makeSession() -> (SSHSession, EmbeddedChannel, EmbeddedEventLoop) {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        let session = SSHSession(childChannel: channel)
        return (session, channel, loop)
    }

    /// `deliverOutput` (called from the EventLoop in production) hands the
    /// bytes to the registered handler synchronously, without an actor hop.
    /// The lock-backed handler box guarantees both the read and the dispatch
    /// happen on the calling thread.
    func testDeliverOutputInvokesRegisteredHandler() async throws {
        let (session, _, loop) = makeSession()
        defer { try? loop.syncShutdownGracefully() }

        let received = LockedBox<[UInt8]>([])
        await session.setOutputHandler { bytes in
            received.modify { $0.append(contentsOf: bytes) }
        }

        var buffer = ByteBufferAllocator().buffer(capacity: 5)
        buffer.writeBytes([0x68, 0x65, 0x6C, 0x6C, 0x6F])  // "hello"
        session.deliverOutput(buffer)

        XCTAssertEqual(received.snapshot(), [0x68, 0x65, 0x6C, 0x6C, 0x6F])
    }

    /// stderr arrives on a separate `SSHChannelData(.stdErr)` path but
    /// merges into the same byte stream for terminal use (Slice 5
    /// SwiftTerm). Verifies the bridge keeps the merge.
    func testDeliverStderrMergesIntoOutputHandler() async throws {
        let (session, _, loop) = makeSession()
        defer { try? loop.syncShutdownGracefully() }

        let received = LockedBox<[UInt8]>([])
        await session.setOutputHandler { bytes in
            received.modify { $0.append(contentsOf: bytes) }
        }

        var buffer = ByteBufferAllocator().buffer(capacity: 3)
        buffer.writeBytes([0xEE, 0xEE, 0xEE])
        session.deliverStderr(buffer)

        XCTAssertEqual(received.snapshot(), [0xEE, 0xEE, 0xEE])
    }

    /// The exit handler fires exactly once even on repeated `signalExit`
    /// calls. The latch prevents the SwiftTerm consumer from seeing a
    /// double-dismissal when both `channelInactive` and `errorCaught` fire
    /// in close succession.
    func testSignalExitFiresHandlerExactlyOnce() async throws {
        let (session, _, loop) = makeSession()
        defer { try? loop.syncShutdownGracefully() }

        let count = LockedBox<Int>(0)
        await session.setExitHandler { _ in
            count.modify { $0 += 1 }
        }

        session.signalExit(.clientInitiated)
        session.signalExit(.clientInitiated)
        session.signalExit(.transportDropped)

        XCTAssertEqual(count.snapshot(), 1)
    }

    /// When the server emits `SSHChannelRequestEvent.ExitStatus` before the
    /// channel closes, `signalExit(.channelError)` is upgraded to
    /// `.remoteExit(status)` so the audit trail records the actual exit
    /// status rather than the generic close.
    func testRecordedExitStatusUpgradesChannelErrorToRemoteExit() async throws {
        let (session, _, loop) = makeSession()
        defer { try? loop.syncShutdownGracefully() }

        let observed = LockedBox<ExitCause?>(nil)
        await session.setExitHandler { cause in
            observed.modify { $0 = cause }
        }

        session.recordExitStatus(42)
        session.signalExit(.channelError(reason: "child channel inactive"))

        XCTAssertEqual(observed.snapshot(), .remoteExit(42))
    }

    /// Explicit non-channelError causes (e.g., `.transportDropped`) are
    /// passed through unchanged; the exit-status upgrade only applies to
    /// the generic close path.
    func testExplicitExitCauseIsNotOverridden() async throws {
        let (session, _, loop) = makeSession()
        defer { try? loop.syncShutdownGracefully() }

        let observed = LockedBox<ExitCause?>(nil)
        await session.setExitHandler { cause in
            observed.modify { $0 = cause }
        }

        session.recordExitStatus(7)
        session.signalExit(.transportDropped)

        XCTAssertEqual(observed.snapshot(), .transportDropped)
    }

    /// `close()` is idempotent: calling it twice does not throw and does
    /// not write twice to the channel.
    func testCloseIsIdempotent() async throws {
        let (session, _, loop) = makeSession()
        defer { try? loop.syncShutdownGracefully() }

        await session.close()
        await session.close()
        // No assertion needed beyond "didn't throw / hang."
    }
}

// MARK: - SSHClient structural tests

final class SSHClientTests: XCTestCase {

    /// A transport that returns a failed future regardless of input. Used to
    /// drive `SSHClient.connect()` down its transport-failure path so the
    /// error mapping (`transportConnectFailed`) is exercised without a real
    /// network round-trip.
    private struct FailingTransport: PulseTransport {
        let error: Error
        func connect(
            to host: String,
            port: Int,
            on eventLoop: EventLoop
        ) -> EventLoopFuture<Channel> {
            eventLoop.makeFailedFuture(error)
        }
    }

    private actor StubKnownHostStore: KnownHostStore {
        func trust(forHost host: String, port: Int) async throws -> HostTrust? { nil }
        func recordPinned(host: String, port: Int, fingerprintSHA256: String, algorithm: String) async throws {}
        func touchLastVerified(forHost host: String, port: Int) async throws {}
    }

    private struct StubError: Error, CustomStringConvertible {
        let description = "stub transport error"
    }

    private func makeClient(transport: PulseTransport) -> SSHClient {
        SSHClient(
            transport: transport,
            host: "10.0.0.99",
            port: 22,
            username: "alice",
            credentialID: UUID(),
            tier: .portable,
            certificateBlob: nil,
            pemProvider: { nil },
            knownHostStore: StubKnownHostStore()
        )
    }

    /// Transport failure surfaces as a typed `SSHClientError` so the debug
    /// menu / SwiftTerm view can render a clear message instead of a raw
    /// NIO error.
    func testConnectTransportFailureMapsToTypedError() async throws {
        let client = makeClient(transport: FailingTransport(error: StubError()))
        do {
            _ = try await client.connect()
            XCTFail("expected SSHClientError.transportConnectFailed")
        } catch let error as SSHClientError {
            guard case .transportConnectFailed(let reason) = error else {
                return XCTFail("expected transportConnectFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("stub transport error"))
        }
        await client.close()
    }
}

// MARK: - LockedBox helper

/// Tiny `NSLock`-backed box used in tests where a closure captured by a
/// `@Sendable` callback needs to write back to a value the test will read.
/// `XCTest`'s `XCTAssert*` runs synchronously after the closure invocations,
/// so the snapshot read sees all preceding writes.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { self.value = initial }

    func modify(_ body: (inout Value) -> Void) {
        lock.withLock { body(&value) }
    }

    func snapshot() -> Value {
        lock.withLock { value }
    }
}
