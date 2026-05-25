//
//  SessionLogWriterTests.swift
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
import NIOConcurrencyHelpers
import XCTest
@testable import Pulse

/// Tests for `SessionLogWriter`. Uses an in-memory
/// `SessionLogFileStore` conformance so we can drive the writer at full
/// speed without touching the filesystem and inspect the byte stream
/// that would have landed on disk.
///
/// The biometric unwrap path is not exercised here — the writer never
/// calls `unwrap()`. Wrap is software-equivalent (both SE and software
/// P256 share the algebra), so we substitute a software wrapping public
/// key. Production runs use `SessionLogWrappingKey.publicKey()`.
final class SessionLogWriterTests: XCTestCase {

    // MARK: - In-memory store

    /// Captures the byte stream the writer would have written to disk.
    /// Thread-safe via `NIOLockedValueBox` because the writer's actor
    /// may call into it from any cooperative-pool thread.
    final class InMemoryStore: SessionLogFileStore, @unchecked Sendable {
        struct Snapshot: Sendable {
            var pulselogLines: [Data] = [] // each entry is one JSONL line without trailing newline
            var meta: Data? = nil
        }

        private let storage = NIOLockedValueBox<[URL: Snapshot]>([:])

        // Failure injection
        private let failOnAppendAfter: Int?
        private let appendCount = NIOLockedValueBox<Int>(0)

        init(failOnAppendAfter: Int? = nil) {
            self.failOnAppendAfter = failOnAppendAfter
        }

        func snapshot(of url: URL) -> Snapshot {
            storage.withLockedValue { $0[url] ?? Snapshot() }
        }

        func paths(deviceID: Int64?, sessionID: UUID, openedAt: Date) throws -> SessionLogFileStorePaths {
            let deviceComponent = deviceID.map { "dev-\($0)" } ?? "unassigned"
            let base = URL(fileURLWithPath: "/dev/null/InMemory/\(deviceComponent)")
            let pulselog = base.appendingPathComponent("\(sessionID.uuidString).pulselog")
            let meta = base.appendingPathComponent("\(sessionID.uuidString).meta")
            return SessionLogFileStorePaths(
                pulselog: pulselog,
                meta: meta,
                pulselogRelativePath: "Pulse/Sessions/\(deviceComponent)/\(sessionID.uuidString).pulselog"
            )
        }

        func appendLine(to url: URL, data: Data) throws {
            let count = appendCount.withLockedValue { value -> Int in
                value += 1
                return value
            }
            if let threshold = failOnAppendAfter, count > threshold {
                throw NSError(domain: "InMemoryStoreFault", code: 1)
            }
            storage.withLockedValue { dict in
                var snap = dict[url] ?? Snapshot()
                // Strip the trailing newline the writer appends.
                var stripped = data
                if stripped.last == 0x0A { stripped.removeLast() }
                snap.pulselogLines.append(stripped)
                dict[url] = snap
            }
        }

        func writeMeta(to url: URL, data: Data) throws {
            storage.withLockedValue { dict in
                var snap = dict[url] ?? Snapshot()
                snap.meta = data
                dict[url] = snap
            }
        }
    }

    /// Slow store that signals first-write start, then blocks until
    /// released. Used for back-pressure tests where the actor must be
    /// busy on a record so subsequent enqueues pile up.
    final class BlockingStore: SessionLogFileStore, @unchecked Sendable {
        let firstAppendBegan = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let didReleaseFirst = NIOLockedValueBox<Bool>(false)
        private let appendCount = NIOLockedValueBox<Int>(0)

        func paths(deviceID: Int64?, sessionID: UUID, openedAt: Date) throws -> SessionLogFileStorePaths {
            let base = URL(fileURLWithPath: "/dev/null/Blocking")
            return SessionLogFileStorePaths(
                pulselog: base.appendingPathComponent("\(sessionID.uuidString).pulselog"),
                meta: base.appendingPathComponent("\(sessionID.uuidString).meta"),
                pulselogRelativePath: "Pulse/Sessions/blocking/\(sessionID.uuidString).pulselog"
            )
        }

        func appendLine(to url: URL, data: Data) throws {
            let count = appendCount.withLockedValue { value -> Int in
                value += 1
                return value
            }
            // The header is appended at open() time, before any record
            // — skip the block for that. Only block on the first
            // record-line append, which is count == 2.
            if count == 2 {
                firstAppendBegan.signal()
                release.wait()
            }
        }

        func writeMeta(to url: URL, data: Data) throws {}

        func releaseAppend() {
            let already = didReleaseFirst.withLockedValue { value -> Bool in
                if value { return true }
                value = true
                return false
            }
            if !already { release.signal() }
        }
    }

    // MARK: - Helpers

    private func makeWriter(
        store: SessionLogFileStore,
        deviceID: Int64? = 42
    ) async throws -> SessionLogWriter {
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        return try await SessionLogWriter.open(
            deviceID: deviceID,
            credentialID: UUID(),
            username: "operator",
            host: "lab.example",
            port: 22,
            store: store,
            wrappingPublicKey: { wrappingPriv.publicKey }
        )
    }

    // MARK: - Happy path

    func testOpenWritesHeaderAndInitialMeta() async throws {
        let store = InMemoryStore()
        let writer = try await makeWriter(store: store)
        await writer.close(exitCauseDescription: "test_close")

        let pulelog = store.snapshot(of: writer.fileStorePaths.pulselog)
        XCTAssertEqual(pulelog.pulselogLines.count, 1, "Header line must be present after open with no records")

        let header = try JSONDecoder().decode(PulselogHeader.self, from: pulelog.pulselogLines[0])
        XCTAssertEqual(header.v, 1)
        XCTAssertEqual(header.alg, SessionLogCrypto.algorithmIdentifier)
        XCTAssertFalse(header.wrapped_key_b64.isEmpty)

        let metaSnapshot = store.snapshot(of: writer.fileStorePaths.meta)
        XCTAssertNotNil(metaSnapshot.meta)
        let meta = try JSONDecoder().decode(SessionMeta.self, from: metaSnapshot.meta!)
        XCTAssertEqual(meta.device_id, 42)
        XCTAssertEqual(meta.username, "operator")
        XCTAssertEqual(meta.host, "lab.example")
        XCTAssertEqual(meta.port, 22)
        XCTAssertEqual(meta.exit_cause, "test_close")
        XCTAssertNotNil(meta.closed_at)
        XCTAssertNotNil(meta.duration_ms)
    }

    func testRoundTripRecordsAreRecoverableViaChainValidator() async throws {
        let store = InMemoryStore()

        // Use a deterministic wrapping key so we can derive the same
        // session key after reading the header and unwrapping.
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        let writer = try await SessionLogWriter.open(
            deviceID: 7,
            credentialID: UUID(),
            username: "op",
            host: "h",
            port: 22,
            store: store,
            wrappingPublicKey: { wrappingPriv.publicKey }
        )

        let chunks: [(SessionLogRecord.Direction, [UInt8])] = [
            (.out, Array("ls -la\n".utf8)),
            (.in,  Array("total 0\ndrwx... .\n".utf8)),
            (.out, Array("exit\n".utf8)),
            (.in,  Array("logout\n".utf8))
        ]
        for (dir, bytes) in chunks {
            _ = writer.tryEnqueue(direction: dir, bytes: ArraySlice(bytes))
        }
        await writer.__drainForTests()
        await writer.close(exitCauseDescription: "remote_exit_0")

        // Read header, recover the session key, validate the chain.
        let pulselog = store.snapshot(of: writer.fileStorePaths.pulselog)
        XCTAssertEqual(pulselog.pulselogLines.count, 1 + chunks.count, "Header + one line per record")
        let header = try JSONDecoder().decode(PulselogHeader.self, from: pulselog.pulselogLines[0])
        let wrappedData = Data(base64Encoded: header.wrapped_key_b64)!
        let wrapped = try WrappedSessionKey.decode(wrappedData)
        let sessionKey = try SessionLogCrypto.unwrap(wrapped, with: wrappingPriv)

        // Recover the sealed-combined bytes for each record line.
        var combined: [Data] = []
        for line in pulselog.pulselogLines.dropFirst() {
            let lineString = String(data: line, encoding: .utf8)!
            combined.append(Data(base64Encoded: lineString)!)
        }
        let validation = SessionLogCrypto.validateChain(records: combined, using: sessionKey)
        guard case .valid(let count, _) = validation else {
            return XCTFail("Expected valid chain, got \(validation)")
        }
        XCTAssertEqual(count, UInt64(chunks.count))

        // Spot-check decoded bytes for the first record.
        let firstRecord = try SessionLogCrypto.open(
            encrypted: EncryptedRecord(sealedCombined: combined[0]),
            using: sessionKey
        )
        XCTAssertEqual(firstRecord.seq, 0)
        XCTAssertEqual(firstRecord.dir, .out)
        XCTAssertEqual(Data(base64Encoded: firstRecord.bytes), Data("ls -la\n".utf8))

        // Meta should reflect the count and chain head.
        let metaSnapshot = store.snapshot(of: writer.fileStorePaths.meta)
        let meta = try JSONDecoder().decode(SessionMeta.self, from: metaSnapshot.meta!)
        XCTAssertEqual(meta.record_count, UInt64(chunks.count))
        XCTAssertEqual(meta.chain_head_hash, SessionLogCrypto.chainHash(of: combined.last!))
        XCTAssertEqual(meta.exit_cause, "remote_exit_0")
    }

    func testUnassignedDevicePathPrefix() async throws {
        let store = InMemoryStore()
        let writer = try await makeWriter(store: store, deviceID: nil)
        await writer.close(exitCauseDescription: "test")

        let paths = writer.fileStorePaths
        XCTAssertTrue(paths.pulselogRelativePath.contains("/unassigned/"))
        XCTAssertFalse(paths.pulselogRelativePath.contains("/dev-"))

        let metaSnap = store.snapshot(of: paths.meta)
        let meta = try JSONDecoder().decode(SessionMeta.self, from: metaSnap.meta!)
        XCTAssertNil(meta.device_id)
    }

    // MARK: - Idempotent close

    func testCloseIsIdempotent() async throws {
        let store = InMemoryStore()
        let writer = try await makeWriter(store: store)
        await writer.close(exitCauseDescription: "first")
        await writer.close(exitCauseDescription: "second-should-be-ignored")

        let metaSnap = store.snapshot(of: writer.fileStorePaths.meta)
        let meta = try JSONDecoder().decode(SessionMeta.self, from: metaSnap.meta!)
        XCTAssertEqual(meta.exit_cause, "first", "Second close must be a no-op")
    }

    // MARK: - Mid-session failure → terminal stop

    func testWriteFailureTransitionsToTerminalStop() async throws {
        // Allow the header to write, but fail on the first record-line
        // append. The writer should transition to .recordingStopped
        // with reason .writeFailure and finalise .meta with
        // exit_cause = "recording_failed_midstream".
        let store = InMemoryStore(failOnAppendAfter: 1)
        let writer = try await makeWriter(store: store)

        _ = writer.tryEnqueue(direction: .out, bytes: ArraySlice([0x41, 0x42, 0x43]))
        _ = writer.tryEnqueue(direction: .out, bytes: ArraySlice([0x44, 0x45, 0x46]))
        await writer.__drainForTests()

        let stop = writer.__stopReasonForTests()
        guard case .writeFailure = stop else {
            return XCTFail("Expected .writeFailure, got \(String(describing: stop))")
        }

        // Subsequent enqueues are silent no-ops.
        let acceptedAfterStop = writer.tryEnqueue(direction: .out, bytes: ArraySlice([0x47]))
        XCTAssertFalse(acceptedAfterStop)

        // .meta carries the structural-failure cause even if the
        // operator never calls close.
        // Wait briefly for the finaliseAfterStructuralStop Task to run.
        for _ in 0..<20 {
            let snap = store.snapshot(of: writer.fileStorePaths.meta)
            if let data = snap.meta,
               let meta = try? JSONDecoder().decode(SessionMeta.self, from: data),
               meta.exit_cause == "recording_failed_midstream" {
                XCTAssertNotNil(meta.closed_at)
                XCTAssertNotNil(meta.duration_ms)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Meta was not finalised with recording_failed_midstream within timeout")
    }

    // MARK: - Back-pressure overflow

    func testBackPressureOverflowTransitionsToStopAfterBound() async throws {
        let store = BlockingStore()
        let writer = try await makeWriter(store: store)

        // Synchronous tight loop on this thread. The first tryEnqueue
        // spawns a Task that suspends inside the actor and eventually
        // calls store.appendLine, which blocks on the semaphore. Every
        // subsequent enqueue runs synchronously on this thread and
        // increments pendingRecords. Because this thread never yields,
        // the actor's executor cannot drain anything, so pendingRecords
        // grows monotonically.
        var acceptedCount = 0
        var droppedCount = 0
        let attempts = SessionLogWriter.maxPendingRecords + 50
        for _ in 0..<attempts {
            if writer.tryEnqueue(direction: .out, bytes: ArraySlice([0x41])) {
                acceptedCount += 1
            } else {
                droppedCount += 1
            }
        }

        XCTAssertGreaterThan(droppedCount, 0, "Some enqueues must have been dropped past the bound")
        XCTAssertLessThanOrEqual(acceptedCount, SessionLogWriter.maxPendingRecords + 1,
                                 "At most maxPendingRecords + the in-flight record can have been accepted")

        // Writer has stopped with back_pressure_overflow.
        let stop = writer.__stopReasonForTests()
        XCTAssertEqual(stop, .backPressureOverflow)

        // Subsequent enqueues are silent no-ops.
        XCTAssertFalse(writer.tryEnqueue(direction: .in, bytes: ArraySlice([0x42])))

        // Release the blocked appendLine so the in-flight Task can
        // complete; otherwise the test leaks a stuck cooperative-pool
        // worker. The writer was already stopped, so the subsequent
        // record-processing path inside the actor will short-circuit.
        store.releaseAppend()
        await writer.__drainForTests()
    }

    func testBytePressureOverflowTransitionsToStop() async throws {
        // 5 MB of plaintext in a single record exceeds the 4 MiB byte
        // bound on first enqueue, so the writer should transition
        // immediately to back_pressure_overflow even without record
        // count pressure.
        let store = BlockingStore()
        let writer = try await makeWriter(store: store)

        let huge = ArraySlice<UInt8>(repeating: 0x41, count: SessionLogWriter.maxPendingBytes + 1024)
        let accepted = writer.tryEnqueue(direction: .out, bytes: huge)
        XCTAssertFalse(accepted, "A single record larger than maxPendingBytes must be rejected")
        XCTAssertEqual(writer.__stopReasonForTests(), .backPressureOverflow)

        store.releaseAppend()
        await writer.__drainForTests()
    }
}
