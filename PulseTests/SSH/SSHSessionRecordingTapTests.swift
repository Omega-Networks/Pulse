//
//  SSHSessionRecordingTapTests.swift
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

import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest
@testable import Pulse

/// Coverage for `SSHSessionRecordingTap`. Uses `EmbeddedChannel` to
/// drive inbound and outbound `SSHChannelData` and asserts:
///
/// - The byte stream the writer observes matches what the channel
///   actually saw.
/// - The pipeline forwarding is pure pass-through (downstream handlers
///   see the data unchanged, with no copies or transformations from
///   the tap).
/// - Channel-data type discrimination is correct: stdout and stderr
///   are recorded (merged in the operator-facing replay convention),
///   unknown types are skipped silently.
final class SSHSessionRecordingTapTests: XCTestCase {

    // MARK: - Helpers

    /// Build a writer backed by the in-memory `InMemoryStore` from
    /// `SessionLogWriterTests`. Software P256 wrapping key so no
    /// biometric prompt fires.
    private func makeWriter() async throws -> (
        writer: SessionLogWriter,
        store: SessionLogWriterTests.InMemoryStore
    ) {
        let store = SessionLogWriterTests.InMemoryStore()
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        let writer = try await SessionLogWriter.open(
            deviceID: 7,
            credentialID: UUID(),
            username: "ops",
            host: "lab",
            port: 22,
            store: store,
            wrappingPublicKey: { wrappingPriv.publicKey }
        )
        return (writer, store)
    }

    /// Recovers the byte chunks the writer encrypted from the
    /// in-memory store, decrypting them with the wrapping key the
    /// caller knows.
    private func recoverChunks(
        from store: SessionLogWriterTests.InMemoryStore,
        pulselogURL: URL,
        wrappingPriv: P256.KeyAgreement.PrivateKey
    ) throws -> [(direction: SessionLogRecord.Direction, bytes: Data)] {
        let snapshot = store.snapshot(of: pulselogURL)
        guard snapshot.pulselogLines.count >= 1 else { return [] }
        let header = try JSONDecoder().decode(PulselogHeader.self, from: snapshot.pulselogLines[0])
        guard let wrappedData = Data(base64Encoded: header.wrapped_key_b64) else {
            throw NSError(domain: "RecoveryFault", code: 1)
        }
        let wrapped = try WrappedSessionKey.decode(wrappedData)
        let sessionKey = try SessionLogCrypto.unwrap(wrapped, with: wrappingPriv)

        var out: [(SessionLogRecord.Direction, Data)] = []
        for line in snapshot.pulselogLines.dropFirst() {
            let s = String(data: line, encoding: .utf8) ?? ""
            guard let combined = Data(base64Encoded: s) else { continue }
            let record = try SessionLogCrypto.open(
                encrypted: EncryptedRecord(sealedCombined: combined),
                using: sessionKey
            )
            guard let bytes = Data(base64Encoded: record.bytes) else { continue }
            out.append((record.dir, bytes))
        }
        return out
    }

    /// Drives a writer + tap through an EmbeddedChannel scenario,
    /// returning the writer and the wrapping private key for
    /// decryption. The caller's `body` runs the actual `writeInbound`
    /// / `writeOutbound` interactions.
    private func runTapScenario(
        body: (EmbeddedChannel) throws -> Void
    ) async throws -> (
        writer: SessionLogWriter,
        store: SessionLogWriterTests.InMemoryStore,
        wrappingPriv: P256.KeyAgreement.PrivateKey
    ) {
        let store = SessionLogWriterTests.InMemoryStore()
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        let writer = try await SessionLogWriter.open(
            deviceID: 13,
            credentialID: UUID(),
            username: "u",
            host: "h",
            port: 22,
            store: store,
            wrappingPublicKey: { wrappingPriv.publicKey }
        )
        let tap = SSHSessionRecordingTap(writer: writer)
        let channel = EmbeddedChannel(handler: tap)
        defer { _ = try? channel.finish() }

        try body(channel)

        await writer.__drainForTests()
        await writer.close(exitCauseDescription: "test")
        return (writer, store, wrappingPriv)
    }

    // MARK: - Inbound recording

    func testInboundChannelDataRecordsAsInDirection() async throws {
        let (writer, store, wrappingPriv) = try await runTapScenario { channel in
            var buffer = channel.allocator.buffer(capacity: 8)
            buffer.writeBytes("output-A".utf8)
            try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
        }

        let chunks = try recoverChunks(
            from: store,
            pulselogURL: writer.fileStorePaths.pulselog,
            wrappingPriv: wrappingPriv
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].direction, .in)
        XCTAssertEqual(chunks[0].bytes, Data("output-A".utf8))
    }

    func testInboundStderrRecordsAsInDirection() async throws {
        let (writer, store, wrappingPriv) = try await runTapScenario { channel in
            var buffer = channel.allocator.buffer(capacity: 4)
            buffer.writeBytes("errA".utf8)
            try channel.writeInbound(SSHChannelData(type: .stdErr, data: .byteBuffer(buffer)))
        }
        let chunks = try recoverChunks(
            from: store,
            pulselogURL: writer.fileStorePaths.pulselog,
            wrappingPriv: wrappingPriv
        )
        XCTAssertEqual(chunks.count, 1)
        // Per the ADR §6 convention, stderr is merged into the operator-
        // visible stream and records as the same .in direction.
        XCTAssertEqual(chunks[0].direction, .in)
        XCTAssertEqual(chunks[0].bytes, Data("errA".utf8))
    }

    // MARK: - Outbound recording

    func testOutboundChannelDataRecordsAsOutDirection() async throws {
        let (writer, store, wrappingPriv) = try await runTapScenario { channel in
            var buffer = channel.allocator.buffer(capacity: 6)
            buffer.writeBytes("input1".utf8)
            try channel.writeOutbound(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
        }
        let chunks = try recoverChunks(
            from: store,
            pulselogURL: writer.fileStorePaths.pulselog,
            wrappingPriv: wrappingPriv
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].direction, .out)
        XCTAssertEqual(chunks[0].bytes, Data("input1".utf8))
    }

    // MARK: - Bidirectional ordering

    func testBothDirectionsPreserveTemporalOrder() async throws {
        let (writer, store, wrappingPriv) = try await runTapScenario { channel in
            var b1 = channel.allocator.buffer(capacity: 1)
            b1.writeBytes([0x4F]) // O
            try channel.writeOutbound(SSHChannelData(type: .channel, data: .byteBuffer(b1)))

            var b2 = channel.allocator.buffer(capacity: 1)
            b2.writeBytes([0x49]) // I
            try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(b2)))

            var b3 = channel.allocator.buffer(capacity: 1)
            b3.writeBytes([0x21]) // !
            try channel.writeOutbound(SSHChannelData(type: .channel, data: .byteBuffer(b3)))
        }
        let chunks = try recoverChunks(
            from: store,
            pulselogURL: writer.fileStorePaths.pulselog,
            wrappingPriv: wrappingPriv
        )
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].direction, .out)
        XCTAssertEqual(chunks[1].direction, .in)
        XCTAssertEqual(chunks[2].direction, .out)
        XCTAssertEqual(chunks[0].bytes, Data([0x4F]))
        XCTAssertEqual(chunks[1].bytes, Data([0x49]))
        XCTAssertEqual(chunks[2].bytes, Data([0x21]))
    }

    // MARK: - Pass-through

    func testInboundIsForwardedToNextHandlerUnchanged() async throws {
        // Drive an EmbeddedChannel where the tap is followed by a
        // capture handler. Verify the capture sees the same
        // SSHChannelData (byte-identical) that we wrote.
        let store = SessionLogWriterTests.InMemoryStore()
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        let writer = try await SessionLogWriter.open(
            deviceID: 1,
            credentialID: UUID(),
            username: "u",
            host: "h",
            port: 22,
            store: store,
            wrappingPublicKey: { wrappingPriv.publicKey }
        )
        defer {
            Task.detached { await writer.close(exitCauseDescription: "test") }
        }
        let tap = SSHSessionRecordingTap(writer: writer)
        let capture = InboundCaptureHandler()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(tap)
        try channel.pipeline.syncOperations.addHandler(capture)
        defer { _ = try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 5)
        buffer.writeBytes("ABCDE".utf8)
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))

        XCTAssertEqual(capture.received.count, 1)
        guard case .byteBuffer(let captured) = capture.received[0].data else {
            return XCTFail("Capture should have received a byteBuffer-shaped channel data")
        }
        let capturedBytes = captured.getBytes(at: captured.readerIndex, length: captured.readableBytes)
        XCTAssertEqual(capturedBytes, Array("ABCDE".utf8))
    }

    // MARK: - Lifecycle

    func testChannelInactiveTriggersWriterClose() async throws {
        let (writer, store, _) = try await runTapScenario { channel in
            // Trigger inactive directly. The EmbeddedChannel cleanup
            // in finish() would also fire it, but doing so explicitly
            // lets us assert the writer ran its close.
            try channel.close().wait()
        }
        // The tap's channelInactive spawns a Task.detached for close;
        // give it a beat to land. close() is idempotent so the
        // explicit close inside runTapScenario doesn't double-count.
        for _ in 0..<20 {
            let snap = store.snapshot(of: writer.fileStorePaths.meta)
            if let data = snap.meta,
               let meta = try? JSONDecoder().decode(SessionMeta.self, from: data),
               meta.closed_at != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Meta was never finalised after channelInactive")
    }
}

/// Records inbound `SSHChannelData` for assertion. Pure observer.
private final class InboundCaptureHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private(set) var received: [SSHChannelData] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = self.unwrapInboundIn(data)
        received.append(value)
        context.fireChannelRead(data)
    }
}
