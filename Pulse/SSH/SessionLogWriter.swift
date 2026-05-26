//
//  SessionLogWriter.swift
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

import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import OSLog

// MARK: - SessionLogFileStore

/// Filesystem seam consumed by `SessionLogWriter`. Production conformance
/// (`FileSystemSessionLogFileStore`) writes to the user's Application
/// Support directory; tests inject an in-memory mock to verify the byte
/// stream that would land on disk without touching the filesystem.
///
/// The protocol stays minimal: resolve paths, append a JSONL line,
/// replace the `.meta` sidecar. Anything more elaborate (atomic
/// crash-safe append, write-ahead log) lives behind a different protocol
/// because that hardening is explicitly deferred (see ADR §6 "Out of
/// scope": WAL-style two-phase commit on mid-record crash is a future
/// concern).
protocol SessionLogFileStore: Sendable {

    /// Resolve and create-if-needed the `.pulselog` and `.meta` file
    /// URLs for a session. The conformance owns directory creation; the
    /// writer never calls `FileManager.createDirectory` directly.
    func paths(
        deviceID: Int64?,
        sessionID: UUID,
        openedAt: Date
    ) throws -> SessionLogFileStorePaths

    /// Append a single JSONL line — the caller's `data` payload plus a
    /// trailing newline — to the `.pulselog` file. Must be durable
    /// enough that a process exit immediately after the call returns
    /// preserves the line; on iOS App Sandbox and macOS this means
    /// `FileHandle.write(...)` is sufficient because the file is not
    /// opened with `O_DIRECT`-style buffering.
    func appendLine(to url: URL, data: Data) throws

    /// Replace the `.meta` sidecar at `url` with `data` atomically.
    /// "Atomically" here means the operator never observes a half-written
    /// `.meta` file on disk; the production conformance uses
    /// `Data.write(to:options:)` with `.atomic`.
    func writeMeta(to url: URL, data: Data) throws
}

struct SessionLogFileStorePaths: Sendable, Equatable {
    let pulselog: URL
    let meta: URL
    /// Path to `.pulselog` relative to the Application Support root,
    /// suitable for embedding in `SessionMeta.pulselog_path`. Computed
    /// by the store because the store owns the root.
    let pulselogRelativePath: String
}

// MARK: - FileSystemSessionLogFileStore (production)

/// Production conformance. Resolves paths under
/// `FileManager.default.url(for: .applicationSupportDirectory)`,
/// matching ADR §6's amended path scheme: macOS non-sandboxed
/// `~/Library/Application Support/Pulse/Sessions/...`; macOS sandboxed
/// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/Pulse/Sessions/...`;
/// iOS `<container>/Library/Application Support/Pulse/Sessions/...`.
///
/// On iOS, the parent directory carries `FileProtectionType.complete`
/// as defence-in-depth; on macOS the `setResourceValues` call is a no-op
/// (the platform has no per-file protection class) but is left in place
/// so the call site is platform-agnostic. The actual confidentiality
/// guarantee is the SE-wrapped per-session key, not the file-protection
/// class — see ADR §6 amendment.
struct FileSystemSessionLogFileStore: SessionLogFileStore {

    /// The "Pulse" subdirectory under Application Support. Pulled out
    /// so a future runbook step ("clear all recorded sessions on this
    /// device") has a single source of truth for the root.
    static let rootSubpath = "Pulse/Sessions"

    /// Filesystem-safe ISO 8601 variant: no colons (some filesystems
    /// object), no fractional seconds (the sessionUUID disambiguates
    /// within the same second). `Date.ISO8601FormatStyle` is a value
    /// type and `Sendable`, so it can live in a `Sendable`-conforming
    /// struct without ceremony — unlike `FileManager` or
    /// `ISO8601DateFormatter`, which we deliberately keep out of the
    /// struct's stored properties.
    private static let filenameTimestampStyle: Date.ISO8601FormatStyle =
        Date.ISO8601FormatStyle(timeZone: .gmt)
            .year().month().day()
            .dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: false)
            .timeSeparator(.omitted)
            .timeZone(separator: .omitted)

    init() {}

    func paths(
        deviceID: Int64?,
        sessionID: UUID,
        openedAt: Date
    ) throws -> SessionLogFileStorePaths {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let deviceComponent: String
        if let id = deviceID {
            deviceComponent = "dev-\(id)"
        } else {
            deviceComponent = "unassigned"
        }

        let sessionDir = root
            .appendingPathComponent(Self.rootSubpath, isDirectory: true)
            .appendingPathComponent(deviceComponent, isDirectory: true)

        try FileManager.default.createDirectory(
            at: sessionDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        Self.applyIOSFileProtection(to: sessionDir)

        let stamp = Self.filenameTimestampStyle.format(openedAt)
        let basename = "\(stamp)_\(sessionID.uuidString)"
        let pulselog = sessionDir.appendingPathComponent("\(basename).pulselog", isDirectory: false)
        let meta = sessionDir.appendingPathComponent("\(basename).meta", isDirectory: false)

        let relativePath = "\(Self.rootSubpath)/\(deviceComponent)/\(basename).pulselog"

        return SessionLogFileStorePaths(
            pulselog: pulselog,
            meta: meta,
            pulselogRelativePath: relativePath
        )
    }

    func appendLine(to url: URL, data: Data) throws {
        var payload = data
        payload.append(0x0A) // '\n'

        if !FileManager.default.fileExists(atPath: url.path) {
            // Create file with first write. Subsequent writes append.
            try payload.write(to: url, options: [])
            Self.applyIOSFileProtection(to: url)
            return
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }

    func writeMeta(to url: URL, data: Data) throws {
        try data.write(to: url, options: [.atomic])
        Self.applyIOSFileProtection(to: url)
    }

    // MARK: - iOS file-protection helper

    /// Applies `FileProtectionType.complete` to the given URL on iOS.
    /// No-op on macOS — there is no per-file protection class on macOS;
    /// at-rest confidentiality there is FileVault (whole-volume). The
    /// actual recording-confidentiality guarantee on both platforms is
    /// the SE-wrapped per-session key. See ADR §6 amendment.
    ///
    /// `URL.setResourceValues(...)` would be the modern surface but
    /// `URLResourceValues.fileProtection` is get-only on iOS. The
    /// settable surface is `FileManager.setAttributes` with
    /// `FileAttributeKey.protectionKey`. Best-effort: failures are
    /// silently ignored because the SE-wrapping guarantee is the
    /// load-bearing one; file protection is defence-in-depth.
    static func applyIOSFileProtection(to url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }
}

// MARK: - Header + meta sidecar

/// First line of every `.pulselog` file. Unencrypted JSON; reveals no
/// session metadata beyond what the unencrypted `.meta` sidecar already
/// exposes (algorithm identifier, format version, session UUID, wrapped
/// AES key blob). The wrapped key blob is biometric-protected: reading
/// the bytes is non-biometric, recovering the session key requires
/// biometric on the SE-resident wrapping key.
struct PulselogHeader: Codable, Equatable, Sendable {
    /// Format version. Bumped if the on-disk envelope shape changes.
    /// Ships v=1.
    let v: Int

    /// UUID stringified. Pairs with the `.meta` sidecar's identity for
    /// integrity-cross-checking; if a `.pulselog` and `.meta` end up
    /// matched against the wrong UUID the chain validator will still
    /// reject because the wrapped key won't unwrap.
    let session_id: String

    /// Algorithm identifier (`SessionLogCrypto.algorithmIdentifier`).
    /// Recorded so a future v2 reader can dispatch on it.
    let alg: String

    /// Base64-encoded `WrappedSessionKey.encode()` output. 65-byte
    /// ephemeral public key followed by the AES.GCM sealed session key.
    let wrapped_key_b64: String
}

/// Unencrypted searchable metadata for the session browser. Readable
/// without biometric; the `chain_head_hash` and `record_count` are
/// nil-until-close and are the off-device attestation surface deferred
/// to v2.
///
/// `device_id` is the Pulse `Device.id` (`Int64`, NetBox primary key)
/// or `nil` for ad-hoc connections. The schema matches the path scheme
/// in ADR §6: same identity carries through SwiftData, the filesystem,
/// and the JSON metadata.
struct SessionMeta: Codable, Equatable, Sendable {
    var device_id: Int64?
    var credential_id: UUID
    var username: String
    var host: String
    var port: Int
    var opened_at: String
    var closed_at: String?
    var duration_ms: Int?
    var exit_cause: String?
    var record_count: UInt64?
    var chain_head_hash: String?
    /// Path to the `.pulselog` relative to Application Support root.
    /// Lets a future browser locate the encrypted file without
    /// re-deriving the path scheme.
    var pulselog_path: String
}

// MARK: - SessionLogWriter

/// Encrypts session bytes and writes them as JSONL records to a
/// per-session `.pulselog` file, alongside an unencrypted `.meta`
/// sidecar.
///
/// **State machine.** A writer is in one of two states for its lifetime:
///
/// - `.recording` — the steady state from `open()` until `close()` or
///   a structural failure.
/// - `.recordingStopped(reason:)` — entered exactly once when the
///   writer encounters a failure that prevents further recording: a
///   seal/write error, a queue overflow, or close. Once stopped, every
///   subsequent `tryEnqueue(...)` returns false without emitting any
///   further audit signal.
///
/// This is the ADR §6 "terminal stop, no gap records" guarantee made
/// concrete. The `.pulselog` ends at the last successful record; the
/// `.meta` sidecar carries `exit_cause: "recording_failed_midstream"`
/// when the cause was structural rather than session-level.
///
/// **Concurrency model.** The writer is an actor — record processing
/// serialises on the actor's executor, which gives ordered sealing,
/// monotonic `seq`, and a coherent prev-hash chain without explicit
/// locks. The `tryEnqueue(...)` entry point is `nonisolated` so the
/// EventLoop-side recording tap can synchronously check whether a
/// record fits within the back-pressure bound without paying for an
/// actor hop on the hot path. The bound itself (1024 records or 4 MiB
/// pending plaintext bytes, whichever is reached first) is maintained
/// in a `NIOLockedValueBox` so the nonisolated check and the
/// actor-side decrement share the same source of truth.
actor SessionLogWriter {

    // MARK: Configuration

    /// Maximum number of pending records the writer will buffer before
    /// transitioning to the terminal stop state. Matches ADR §6's
    /// stated bound. A future tunable could thread this through `open`;
    /// the current build ships the static value.
    static let maxPendingRecords = 1024

    /// Maximum total pending plaintext bytes. 4 MiB — matches ADR §6.
    static let maxPendingBytes = 4 * 1024 * 1024

    // MARK: Errors

    enum WriterError: Error, CustomStringConvertible, Equatable {
        case headerEncodeFailed(String)
        case metaEncodeFailed(String)
        case headerWriteFailed(String)
        case metaWriteFailed(String)
        case wrapFailed(String)
        case alreadyClosed

        var description: String {
            switch self {
            case .headerEncodeFailed(let reason):
                return "Failed to encode .pulselog header: \(reason)"
            case .metaEncodeFailed(let reason):
                return "Failed to encode .meta sidecar: \(reason)"
            case .headerWriteFailed(let reason):
                return "Failed to write .pulselog header: \(reason)"
            case .metaWriteFailed(let reason):
                return "Failed to write .meta sidecar: \(reason)"
            case .wrapFailed(let reason):
                return "Failed to wrap the per-session AES key to the SE log wrapping key: \(reason)"
            case .alreadyClosed:
                return "SessionLogWriter has already transitioned to the terminal state; refusing to re-open."
            }
        }
    }

    /// Reason the writer transitioned to `.recordingStopped`. Surfaces in
    /// the `session.recording.failed` audit event's `reason` field and,
    /// for structural failures, in `.meta.exit_cause`.
    enum StopReason: Sendable, Equatable {
        /// Normal `close(exitCause:)` invocation. The `.meta.exit_cause`
        /// is the SSH session's own `ExitCause`, not a recording-failure
        /// marker.
        case closedNormally
        /// AES.GCM seal failed (CryptoKit-internal error, vanishingly
        /// rare in practice).
        case sealFailure(String)
        /// `SessionLogFileStore.appendLine` threw.
        case writeFailure(String)
        /// Pending queue exceeded 1024 records or 4 MiB of plaintext.
        /// Session bytes continue flowing to the consumer; only the
        /// recording stops.
        case backPressureOverflow
        /// Couldn't encode an envelope (extremely unlikely given the
        /// envelope contents are all `String`/`UInt64`, but kept distinct
        /// so the audit signal is precise if it ever fires).
        case encodeFailure(String)

        /// Maps to the `reason` field in the `session.recording.failed`
        /// audit event. Stable string values so SIEM rules can match
        /// without parsing.
        var auditReason: String {
            switch self {
            case .closedNormally: return "closed_normally"
            case .sealFailure: return "seal_failure"
            case .writeFailure: return "write_failure"
            case .backPressureOverflow: return "back_pressure_overflow"
            case .encodeFailure: return "encode_failure"
            }
        }

        /// Whether this stop reason represents a *recording* failure
        /// (rather than normal close). Drives `.meta.exit_cause` between
        /// `recording_failed_midstream` and the SSH session's own
        /// exit-cause string.
        var isStructuralFailure: Bool {
            switch self {
            case .closedNormally: return false
            default: return true
            }
        }
    }

    // MARK: Stored state

    private let sessionID: UUID
    private let openedAt: Date
    private let paths: SessionLogFileStorePaths
    private let store: SessionLogFileStore
    private let sessionKey: SymmetricKey

    /// Mutable `.meta` snapshot. The writer updates this in-place on
    /// `close()`, then serialises and asks the store to replace the
    /// sidecar atomically.
    private var meta: SessionMeta

    /// Monotonic sequence counter for records. The first record after
    /// the header has `seq = 0`.
    private var nextSeq: UInt64 = 0

    /// Hash of the previous record's `SealedBox.combined`, hex-lowercase.
    /// `""` for the first record.
    private var previousChainHash: String = ""

    /// True once `close()` has run; second close is a no-op.
    private var closed: Bool = false

    /// Logger. Direct os_log emission stays inline here so
    /// the structural-failure paths are visible; the audit-event
    /// surface is consolidated elsewhere in the recording stack.
    private static let logger = Logger(subsystem: "pulse", category: "ssh.recording")

    // MARK: Bounded pending queue (nonisolated)

    /// Shared state between the nonisolated `tryEnqueue(...)` (called
    /// from the recording tap on the EventLoop) and the actor-side
    /// processing path. The lock holds for nanoseconds; the actual
    /// sealing happens after the lock is released.
    private nonisolated let pendingState = NIOLockedValueBox<PendingState>(.init())

    struct PendingState: Sendable, Equatable {
        var pendingRecords: Int = 0
        var pendingBytes: Int = 0
        var stopped: Bool = false
        var stopReason: StopReason?
        /// Queue of records the actor has not yet sealed. Maintains
        /// FIFO order across the EventLoop-side `tryEnqueue` calls.
        ///
        /// Why a queue rather than fire-and-forget Tasks: Swift's
        /// concurrency runtime does not guarantee that two
        /// independently-spawned `Task { await actor.method(...) }`
        /// calls enter the actor in spawn order. Each Task races
        /// independently for actor entry. With N tasks queued from a
        /// single EventLoop thread we want strict FIFO so the
        /// recording's byte order matches the wire order; the queue
        /// + drain shape gives us that without an `AsyncStream`
        /// channel-shaped dependency.
        var queue: [PendingRecord] = []
        /// Whether a drain task is currently active. The actor kicks
        /// at most one drain at a time; subsequent `tryEnqueue` calls
        /// append to the queue and the drain picks them up.
        var draining: Bool = false
    }

    struct PendingRecord: Sendable, Equatable {
        let direction: SessionLogRecord.Direction
        let bytes: Data
    }

    // MARK: Lifecycle

    /// Opens a new session-log writer. Generates a fresh per-session
    /// AES-256 key, wraps it to the SE log wrapping key (`wrappingPublicKey`
    /// — defaults to the device's resident key), writes the `.pulselog`
    /// header line, and writes the initial `.meta` sidecar with
    /// `opened_at` populated and the close-time fields nil.
    ///
    /// Throws on header encode/write failure or wrap failure. Either
    /// throws before any persistent state lands, so the caller can fall
    /// back cleanly to "recording disabled for this session".
    static func open(
        deviceID: Int64?,
        credentialID: UUID,
        username: String,
        host: String,
        port: Int,
        openedAt: Date = .now,
        sessionID: UUID = UUID(),
        store: SessionLogFileStore = FileSystemSessionLogFileStore(),
        wrappingPublicKey resolveWrappingPublicKey: () throws -> P256.KeyAgreement.PublicKey = {
            try SessionLogWrappingKey.publicKey()
        }
    ) async throws -> SessionLogWriter {
        let paths = try store.paths(
            deviceID: deviceID,
            sessionID: sessionID,
            openedAt: openedAt
        )

        // 1. Generate the per-session AES-256 key.
        let sessionKey = SymmetricKey(size: .bits256)

        // 2. Wrap it to the SE wrapping key. The public-key side is
        //    non-biometric; the unwrap on replay will fire biometric.
        let wrappingPub = try resolveWrappingPublicKey()
        let wrapped: WrappedSessionKey
        do {
            wrapped = try SessionLogCrypto.wrap(
                sessionKey: sessionKey,
                to: wrappingPub
            )
        } catch {
            throw WriterError.wrapFailed(String(describing: error))
        }

        // 3. Build and write the .pulselog header.
        let header = PulselogHeader(
            v: 1,
            session_id: sessionID.uuidString,
            alg: SessionLogCrypto.algorithmIdentifier,
            wrapped_key_b64: wrapped.encode().base64EncodedString()
        )
        let headerData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            headerData = try encoder.encode(header)
        } catch {
            throw WriterError.headerEncodeFailed(String(describing: error))
        }
        do {
            try store.appendLine(to: paths.pulselog, data: headerData)
        } catch {
            throw WriterError.headerWriteFailed(String(describing: error))
        }

        // 4. Build and write the initial .meta sidecar.
        let openedAtISO = SessionLogTimestamp.iso8601(from: openedAt)
        let meta = SessionMeta(
            device_id: deviceID,
            credential_id: credentialID,
            username: username,
            host: host,
            port: port,
            opened_at: openedAtISO,
            closed_at: nil,
            duration_ms: nil,
            exit_cause: nil,
            record_count: nil,
            chain_head_hash: nil,
            pulselog_path: paths.pulselogRelativePath
        )
        let metaData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            metaData = try encoder.encode(meta)
        } catch {
            throw WriterError.metaEncodeFailed(String(describing: error))
        }
        do {
            try store.writeMeta(to: paths.meta, data: metaData)
        } catch {
            throw WriterError.metaWriteFailed(String(describing: error))
        }

        SessionRecordingAudit.recordingOpened(
            sessionID: sessionID,
            credentialID: credentialID,
            deviceID: deviceID,
            pulselogRelativePath: paths.pulselogRelativePath
        )

        return SessionLogWriter(
            sessionID: sessionID,
            openedAt: openedAt,
            paths: paths,
            store: store,
            sessionKey: sessionKey,
            initialMeta: meta
        )
    }

    private init(
        sessionID: UUID,
        openedAt: Date,
        paths: SessionLogFileStorePaths,
        store: SessionLogFileStore,
        sessionKey: SymmetricKey,
        initialMeta: SessionMeta
    ) {
        self.sessionID = sessionID
        self.openedAt = openedAt
        self.paths = paths
        self.store = store
        self.sessionKey = sessionKey
        self.meta = initialMeta
    }

    // MARK: Nonisolated entry point

    /// Synchronously decides whether to accept the record for queueing
    /// against the back-pressure bound. Called from the recording tap
    /// on the EventLoop; returns immediately. The actual seal-and-write
    /// happens in a `Task` spawned by this method when the decision is
    /// "accepted".
    ///
    /// Returns `true` if the record was queued, `false` if dropped
    /// (writer already stopped, or this call triggered the overflow
    /// transition).
    @discardableResult
    nonisolated func tryEnqueue(
        direction: SessionLogRecord.Direction,
        bytes: ArraySlice<UInt8>
    ) -> Bool {
        let byteCount = bytes.count
        // Materialise the byte slice now — the underlying buffer is
        // owned by the SSH channel and may be recycled before the
        // actor processes the record.
        let captured = Data(bytes)

        enum EnqueueDecision {
            case accepted(needsDrainKick: Bool)
            case alreadyStopped
            case overflowJustStopped
        }

        // Decision computed under the lock, acted on outside.
        let decision: EnqueueDecision = pendingState.withLockedValue { state in
            if state.stopped {
                return .alreadyStopped
            }
            if state.pendingRecords >= Self.maxPendingRecords
                || state.pendingBytes &+ byteCount > Self.maxPendingBytes {
                state.stopped = true
                state.stopReason = .backPressureOverflow
                return .overflowJustStopped
            }
            state.queue.append(PendingRecord(direction: direction, bytes: captured))
            state.pendingRecords += 1
            state.pendingBytes += byteCount
            // Kick a drain task only if none is currently running.
            // Once kicked, the drain loop will pick up subsequent
            // enqueues until the queue empties.
            let kick = !state.draining
            if kick { state.draining = true }
            return .accepted(needsDrainKick: kick)
        }

        switch decision {
        case .alreadyStopped:
            return false
        case .overflowJustStopped:
            SessionRecordingAudit.recordingFailed(
                sessionID: sessionID,
                reason: .backPressureOverflow
            )
            Task { await self.finaliseAfterStructuralStop() }
            return false
        case .accepted(let needsDrainKick):
            if needsDrainKick {
                Task { await self.drainQueue() }
            }
            return true
        }
    }

    // MARK: Actor-isolated processing

    /// Drains the pending-record queue serially in FIFO order, sealing
    /// and writing each record. Continues until the queue is empty,
    /// then releases the `draining` flag so the next `tryEnqueue` can
    /// kick a fresh drain. Runs on the actor's executor — record
    /// processing strictly serial within a drain, and the
    /// single-flighting via `draining` means at most one drain runs
    /// at a time.
    ///
    /// FIFO guarantee: each iteration pops the queue's front element
    /// under the lock, processes it (sealing + writing), then loops.
    /// The lock holds for the pop only; sealing happens unlocked but
    /// strictly serial because we're inside the actor.
    private func drainQueue() async {
        while let next = pendingState.withLockedValue({ state -> PendingRecord? in
            // If the writer has stopped (either via close() or a
            // structural failure from a previous record), abandon
            // the queue. The decrement happens below for whatever
            // records were already past the lock when stop fired.
            guard !state.stopped else { return nil }
            return state.queue.isEmpty ? nil : state.queue.removeFirst()
        }) {
            await sealAndWriteRecord(next)
        }

        // Queue drained (or writer stopped). Release the drain flag
        // so the next enqueue can kick a fresh drain. If the queue is
        // non-empty at this point it's because a stop fired mid-loop;
        // the records left behind decrement out of pending via the
        // best-effort path in `finaliseAfterStructuralStop`.
        pendingState.withLockedValue { state in
            state.draining = false
            if state.stopped {
                // Best-effort: zero out pending counters for any
                // records still queued at stop time. They will never
                // be sealed; leaving them counted would mislead any
                // test or audit consumer reading pendingRecords.
                state.pendingRecords -= state.queue.count
                state.pendingBytes -= state.queue.reduce(0) { $0 + $1.bytes.count }
                state.queue.removeAll()
            }
        }
    }

    /// Seals one record under the per-session key, writes it as a
    /// JSONL line, advances the seq counter and chain hash, and
    /// decrements pending counters. Called from the drain loop.
    private func sealAndWriteRecord(_ pending: PendingRecord) async {
        defer {
            pendingState.withLockedValue { state in
                state.pendingRecords = max(0, state.pendingRecords - 1)
                state.pendingBytes = max(0, state.pendingBytes - pending.bytes.count)
            }
        }

        let record = SessionLogRecord(
            seq: nextSeq,
            ts: SessionLogTimestamp.iso8601(from: .now),
            dir: pending.direction,
            prev: previousChainHash,
            bytes: pending.bytes.base64EncodedString()
        )

        let sealed: EncryptedRecord
        do {
            sealed = try SessionLogCrypto.seal(record: record, using: sessionKey)
        } catch {
            transitionToStopped(.sealFailure(String(describing: error)))
            return
        }

        let line = sealed.sealedCombined.base64EncodedString()
        guard let lineData = line.data(using: .utf8) else {
            transitionToStopped(.encodeFailure("base64 utf8 encoding failed"))
            return
        }

        do {
            try store.appendLine(to: paths.pulselog, data: lineData)
        } catch {
            transitionToStopped(.writeFailure(String(describing: error)))
            return
        }

        previousChainHash = SessionLogCrypto.chainHash(of: sealed.sealedCombined)
        nextSeq &+= 1
        if let count = meta.record_count {
            meta.record_count = count &+ 1
        } else {
            meta.record_count = 1
        }
        meta.chain_head_hash = previousChainHash
    }

    /// Marks the writer stopped and emits the audit event. Idempotent:
    /// only the first transition emits. Called by `sealAndWriteRecord` on a
    /// seal/write failure; the overflow path uses a different code path
    /// (`tryEnqueue` sets the flag directly because it's nonisolated).
    private func transitionToStopped(_ reason: StopReason) {
        let alreadyStopped = pendingState.withLockedValue { state -> Bool in
            if state.stopped { return true }
            state.stopped = true
            state.stopReason = reason
            return false
        }
        guard !alreadyStopped else { return }
        SessionRecordingAudit.recordingFailed(
            sessionID: sessionID,
            reason: reason.toAuditFailureReason()
        )
        // Already actor-isolated (transitionToStopped is private and
        // only called from processRecord); call directly rather than
        // spawning a Task. The nonisolated overflow path in
        // tryEnqueue still needs the Task wrapper because it cannot
        // synchronously enter the actor.
        finaliseAfterStructuralStop()
    }

    /// Common .meta finalisation when the writer stopped for a
    /// structural reason (not a regular close). Sets
    /// `exit_cause = "recording_failed_midstream"`, `closed_at = now`,
    /// `duration_ms`, and best-effort writes the sidecar. A failure
    /// to write the .meta at this point is logged but does not produce
    /// a further audit event — the recording is already in the
    /// terminal stop state and chaining failures here would only
    /// obscure the original cause.
    private func finaliseAfterStructuralStop() {
        if closed { return }
        closed = true
        let closedAt = Date.now
        meta.closed_at = SessionLogTimestamp.iso8601(from: closedAt)
        meta.duration_ms = Int(closedAt.timeIntervalSince(openedAt) * 1000)
        meta.exit_cause = "recording_failed_midstream"

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(meta)
            try store.writeMeta(to: paths.meta, data: data)
        } catch {
            Self.logger.error(
                "session.recording: failed to finalise .meta after structural stop: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: Public actor surface

    /// Close the writer, finalising the `.meta` sidecar with the given
    /// `exitCauseDescription` (typically a `String(describing: ExitCause)`
    /// from `SSHSession`). Idempotent — a second call is a no-op.
    ///
    /// Closing waits for any in-flight `processRecord` calls already
    /// queued before this call to drain via the actor's serial executor —
    /// records that were enqueued *after* `close()` was invoked from
    /// another path race against the actor's serialisation and the
    /// stopped-flag check inside `processRecord` will pick up the close.
    /// Callers wanting a strict pre-close drain should invoke `close()`
    /// and then `await drainForTests()` (DEBUG-only) before reading the
    /// final `.meta`.
    func close(exitCauseDescription: String) async {
        if closed { return }
        closed = true

        let alreadyStopped = pendingState.withLockedValue { state -> Bool in
            if state.stopped { return true }
            state.stopped = true
            state.stopReason = .closedNormally
            return false
        }

        let closedAt = Date.now
        meta.closed_at = SessionLogTimestamp.iso8601(from: closedAt)
        meta.duration_ms = Int(closedAt.timeIntervalSince(openedAt) * 1000)
        meta.exit_cause = alreadyStopped ? "recording_failed_midstream" : exitCauseDescription

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(meta)
            try store.writeMeta(to: paths.meta, data: data)
            // Only emit the closed audit event on a normal close path.
            // If the writer was already structurally-stopped, the
            // corresponding `session.recording.failed` event has
            // already fired and a `closed` event here would
            // double-count in any downstream consumer.
            if !alreadyStopped {
                SessionRecordingAudit.recordingClosed(
                    sessionID: sessionID,
                    recordCount: meta.record_count ?? 0,
                    chainHeadHash: previousChainHash,
                    durationMs: meta.duration_ms ?? 0
                )
            }
        } catch {
            Self.logger.error(
                "session.recording: failed to write .meta on close: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: Read-only accessors (for testing and audit cross-checks)

    /// The on-disk paths for this writer's pulselog and meta files.
    nonisolated var fileStorePaths: SessionLogFileStorePaths {
        paths
    }

    /// Snapshot of pending state for callers (tests and the future
    /// audit/Op surface) that want to inspect the back-pressure
    /// situation without disturbing the writer.
    nonisolated func currentPendingState() -> PendingState {
        pendingState.withLockedValue { $0 }
    }
}

// MARK: - Test seam

#if DEBUG

extension SessionLogWriter {

    /// Wait until every pending record currently queued in the actor's
    /// mailbox has been processed. Tests call this between driving
    /// `tryEnqueue` and asserting on the on-disk state so the
    /// fire-and-forget Tasks complete before the assertion runs.
    func __drainForTests() async {
        // Each tryEnqueue spawns a fire-and-forget Task; reaching
        // zero pendingRecords means every spawned Task has run its
        // actor-isolated work to completion. `Task.yield()` alone is
        // insufficient under load (it's a scheduler hint, not a
        // guarantee), so we mix yields with short sleeps. Up to ~1s
        // wallclock total — far longer than any sealed record's
        // processing time, but a hard cap so a stuck actor doesn't
        // hang the test runner indefinitely.
        for _ in 0..<200 {
            let pending = pendingState.withLockedValue { $0.pendingRecords }
            if pending == 0 { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    /// Whether the writer's state machine has transitioned to the
    /// terminal stop, and if so, the reason. Lets tests assert both
    /// the back-pressure path and the structural-failure path without
    /// reading os_log.
    nonisolated func __stopReasonForTests() -> StopReason? {
        pendingState.withLockedValue { $0.stopReason }
    }

    /// Snapshot of the meta sidecar as it would be written next.
    /// Reading via the actor's isolation; tests await it.
    func __currentMetaForTests() -> SessionMeta {
        meta
    }
}

#endif

// MARK: - StopReason → audit FailureReason

extension SessionLogWriter.StopReason {
    /// Maps an internal `StopReason` to the public audit
    /// `FailureReason` shape. Only the structural-failure cases map;
    /// `.closedNormally` is never paired with a
    /// `session.recording.failed` event and triggering this case
    /// is a programmer error.
    func toAuditFailureReason() -> SessionRecordingAudit.FailureReason {
        switch self {
        case .sealFailure(let detail):
            return .sealFailure(detail: detail)
        case .writeFailure(let detail):
            return .writeFailure(detail: detail)
        case .encodeFailure(let detail):
            return .encodeFailure(detail: detail)
        case .backPressureOverflow:
            return .backPressureOverflow
        case .closedNormally:
            preconditionFailure("StopReason.closedNormally must never be emitted as a session.recording.failed audit event")
        }
    }
}
