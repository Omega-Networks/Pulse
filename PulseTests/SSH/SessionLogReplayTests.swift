//
//  SessionLogReplayTests.swift
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
import XCTest
@testable import Pulse

/// End-to-end coverage for the replay path: write a recording with
/// `SessionLogWriter`, read it back with `SessionLogReplay.load`, and
/// verify the chain-validation + audit-event contracts.
///
/// Uses temporary files rather than an in-memory store because the
/// replay path reads via `Data(contentsOf:)` on a URL — the
/// production load contract. Cleanup happens in `tearDown`.
final class SessionLogReplayTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseReplayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// File store that writes into `tempDir` rather than the real
    /// Application Support directory. Lets the writer produce a
    /// `.pulselog` we can read back via the replay helper.
    private final class TempDirStore: SessionLogFileStore, @unchecked Sendable {
        let baseDir: URL
        init(baseDir: URL) { self.baseDir = baseDir }

        func paths(deviceID: Int64?, sessionID: UUID, openedAt: Date) throws -> SessionLogFileStorePaths {
            let pulselog = baseDir.appendingPathComponent("\(sessionID.uuidString).pulselog")
            let meta = baseDir.appendingPathComponent("\(sessionID.uuidString).meta")
            return SessionLogFileStorePaths(
                pulselog: pulselog,
                meta: meta,
                pulselogRelativePath: "tmp/\(sessionID.uuidString).pulselog"
            )
        }

        func appendLine(to url: URL, data: Data) throws {
            var payload = data
            payload.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: url)
            }
        }

        func writeMeta(to url: URL, data: Data) throws {
            try data.write(to: url, options: [.atomic])
        }
    }

    /// Drive a writer over `chunks`, close it, and return the
    /// pulselog URL + the wrapping private key the replay path
    /// needs to unwrap the session key.
    private func writeRecording(
        chunks: [(SessionLogRecord.Direction, [UInt8])]
    ) async throws -> (pulselogURL: URL, sessionID: UUID, wrappingPriv: P256.KeyAgreement.PrivateKey) {
        let store = TempDirStore(baseDir: tempDir)
        let wrappingPriv = P256.KeyAgreement.PrivateKey()
        let sessionID = UUID()
        let writer = try await SessionLogWriter.open(
            deviceID: 1,
            credentialID: UUID(),
            username: "ops",
            host: "lab",
            port: 22,
            sessionID: sessionID,
            store: store,
            wrappingPublicKey: { wrappingPriv.publicKey }
        )
        for (dir, bytes) in chunks {
            _ = writer.tryEnqueue(direction: dir, bytes: ArraySlice(bytes))
        }
        await writer.__drainForTests()
        await writer.close(exitCauseDescription: "test")
        return (writer.fileStorePaths.pulselog, sessionID, wrappingPriv)
    }

    /// Software-key unwrap closure to inject into
    /// `SessionLogReplay.load` so tests don't fire biometric.
    private func softwareUnwrap(
        priv: P256.KeyAgreement.PrivateKey
    ) -> (WrappedSessionKey) throws -> SymmetricKey {
        return { wrapped in
            try SessionLogCrypto.unwrap(wrapped, with: priv)
        }
    }

    // MARK: - Happy path

    func testLoadRecoversAllRecordsWithValidChain() async throws {
        let chunks: [(SessionLogRecord.Direction, [UInt8])] = [
            (.out, Array("ls\n".utf8)),
            (.in,  Array("file1 file2\n".utf8)),
            (.out, Array("exit\n".utf8))
        ]
        let (url, sessionID, priv) = try await writeRecording(chunks: chunks)

        let result = try await SessionLogReplay.load(
            pulselogURL: url,
            sessionID: sessionID,
            unwrapSessionKey: softwareUnwrap(priv: priv)
        )

        guard case .valid(let count, _) = result.validation else {
            return XCTFail("Expected .valid validation, got \(result.validation)")
        }
        XCTAssertEqual(count, UInt64(chunks.count))
        XCTAssertEqual(result.plaintextRecords.count, chunks.count)
        XCTAssertEqual(result.plaintextRecords[0].dir, .out)
        XCTAssertEqual(Data(base64Encoded: result.plaintextRecords[0].bytes), Data("ls\n".utf8))
        XCTAssertEqual(result.plaintextRecords[1].dir, .in)
        XCTAssertEqual(Data(base64Encoded: result.plaintextRecords[1].bytes), Data("file1 file2\n".utf8))
        XCTAssertEqual(result.plaintextRecords[2].dir, .out)
        XCTAssertEqual(Data(base64Encoded: result.plaintextRecords[2].bytes), Data("exit\n".utf8))
    }

    // MARK: - Tamper detection

    func testTamperedRecordYieldsPrefixOnlyAndEmitsChainBroken() async throws {
        let chunks: [(SessionLogRecord.Direction, [UInt8])] = [
            (.out, Array("a".utf8)),
            (.in,  Array("b".utf8)),
            (.out, Array("c".utf8)),
            (.in,  Array("d".utf8))
        ]
        let (url, sessionID, priv) = try await writeRecording(chunks: chunks)

        // Flip a byte in record index 2 (seq=2). The .pulselog file
        // layout is: header line, then one base64 line per record,
        // each separated by '\n'. We rewrite the file with the
        // tampered byte in the right position.
        var data = try Data(contentsOf: url)
        // Find newlines to locate lines.
        var newlineIndices: [Int] = []
        for (i, byte) in data.enumerated() where byte == 0x0A {
            newlineIndices.append(i)
        }
        // newlineIndices[0] is end of header line. Record 0 starts at
        // newlineIndices[0]+1, ends at newlineIndices[1]. Record N
        // starts at newlineIndices[N]+1, ends at newlineIndices[N+1].
        // Tamper byte: within record 2's payload.
        XCTAssertGreaterThan(newlineIndices.count, 3, "expected at least 4 newlines in a 4-record .pulselog")
        let record2Start = newlineIndices[2] + 1
        let record2End = newlineIndices[3]
        let tamperOffset = (record2Start + record2End) / 2
        data[tamperOffset] = data[tamperOffset] ^ 0x01
        try data.write(to: url)

        let capture = SessionRecordingAudit.TestObserver.shared.startCapturing()

        let result = try await SessionLogReplay.load(
            pulselogURL: url,
            sessionID: sessionID,
            unwrapSessionKey: softwareUnwrap(priv: priv)
        )

        // Chain breaks at seq=2; plaintext exposed for records [0, 2).
        guard case .brokenAt(let seq, let reason) = result.validation else {
            return XCTFail("Expected .brokenAt, got \(result.validation)")
        }
        // Single-byte-flip in base64 may produce either an
        // authentication-tag failure (most common) or an envelope-
        // decode failure (rarer, if the flip happens to land in the
        // base64 alphabet so the cipher decodes to invalid JSON).
        // Both are acceptable signals.
        XCTAssertTrue(
            reason == .ciphertextAuthenticationFailed || reason == .envelopeDecodeFailed,
            "Unexpected reason: \(reason)"
        )
        XCTAssertEqual(seq, 2)
        XCTAssertEqual(result.plaintextRecords.count, 2, "Only records before the break should be exposed")
        XCTAssertEqual(Data(base64Encoded: result.plaintextRecords[0].bytes), Data("a".utf8))
        XCTAssertEqual(Data(base64Encoded: result.plaintextRecords[1].bytes), Data("b".utf8))

        // Both audit events should have fired: replayUnwrapped (biometric
        // succeeded — the operator now has access), and replayChainBroken
        // (validation failed mid-stream).
        let unwrapped = capture.events.contains { event in
            if case .replayUnwrapped(let id) = event { return id == sessionID }
            return false
        }
        let broken = capture.events.contains { event in
            if case .replayChainBroken(let id, let brokenSeq) = event {
                return id == sessionID && brokenSeq == 2
            }
            return false
        }
        XCTAssertTrue(unwrapped, "replayUnwrapped should fire on biometric success regardless of chain state")
        XCTAssertTrue(broken, "replayChainBroken should fire with the correct brokenAtSeq")
    }

    // MARK: - Audit on clean replay

    func testCleanReplayFiresUnwrappedButNotChainBroken() async throws {
        let chunks: [(SessionLogRecord.Direction, [UInt8])] = [
            (.out, Array("hello".utf8))
        ]
        let (url, sessionID, priv) = try await writeRecording(chunks: chunks)

        let capture = SessionRecordingAudit.TestObserver.shared.startCapturing()

        _ = try await SessionLogReplay.load(
            pulselogURL: url,
            sessionID: sessionID,
            unwrapSessionKey: softwareUnwrap(priv: priv)
        )

        let unwrappedCount = capture.events.filter {
            if case .replayUnwrapped = $0 { return true }
            return false
        }.count
        let brokenCount = capture.events.filter {
            if case .replayChainBroken = $0 { return true }
            return false
        }.count

        XCTAssertEqual(unwrappedCount, 1)
        XCTAssertEqual(brokenCount, 0)
    }

    // MARK: - Failure surfaces

    func testMissingFileThrowsPulselogReadFailed() async throws {
        let bogus = tempDir.appendingPathComponent("nonexistent.pulselog")
        do {
            _ = try await SessionLogReplay.load(
                pulselogURL: bogus,
                sessionID: UUID(),
                unwrapSessionKey: { _ in SymmetricKey(size: .bits256) }
            )
            XCTFail("Expected ReplayError")
        } catch SessionLogReplay.ReplayError.pulselogReadFailed {
            // expected
        }
    }

    func testEmptyFileThrowsHeaderLineMissing() async throws {
        let empty = tempDir.appendingPathComponent("empty.pulselog")
        try Data().write(to: empty)
        do {
            _ = try await SessionLogReplay.load(
                pulselogURL: empty,
                sessionID: UUID(),
                unwrapSessionKey: { _ in SymmetricKey(size: .bits256) }
            )
            XCTFail("Expected ReplayError")
        } catch SessionLogReplay.ReplayError.headerLineMissing {
            // expected
        }
    }

    func testUnwrapClosureThrowSurfacesAsSessionKeyUnwrapFailed() async throws {
        let chunks: [(SessionLogRecord.Direction, [UInt8])] = [(.out, [0x41])]
        let (url, sessionID, _) = try await writeRecording(chunks: chunks)

        struct UnwrapDeniedError: Error {}

        do {
            _ = try await SessionLogReplay.load(
                pulselogURL: url,
                sessionID: sessionID,
                unwrapSessionKey: { _ in throw UnwrapDeniedError() }
            )
            XCTFail("Expected sessionKeyUnwrapFailed")
        } catch SessionLogReplay.ReplayError.sessionKeyUnwrapFailed {
            // expected
        }
    }
}
