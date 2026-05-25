//
//  SessionLogRetention.swift
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
import OSLog

// MARK: - SessionLogRetentionStore

/// Filesystem seam consumed by `SessionLogRetention`. Production
/// conformance walks the `Pulse/Sessions/` directory tree under
/// Application Support; tests inject an in-memory mock to drive
/// retention scenarios without touching the disk.
///
/// The protocol stays scoped to *retention* concerns — enumeration and
/// pair deletion — rather than reusing `SessionLogFileStore`'s
/// path-and-append shape. The two surfaces have non-overlapping
/// vocabularies (writer cares about a single session's URLs; retention
/// cares about every session's metadata) and conflating them would
/// blur both.
protocol SessionLogRetentionStore: Sendable {

    /// Enumerate every `.pulselog`/`.meta` pair currently on disk that
    /// retention is responsible for. Conformances skip entries whose
    /// `.meta` is missing or unreadable rather than guessing at the
    /// `opened_at`: a corrupted sidecar may indicate something an
    /// operator should investigate, so retention keeps it on disk.
    func enumerateSessions() throws -> [SessionLogRetentionEntry]

    /// Unlink both files of a session. Idempotent in the production
    /// conformance: a missing file is not an error.
    func deleteSession(_ entry: SessionLogRetentionEntry) throws
}

/// One session as seen by retention. Carries the URLs of both files
/// plus the parsed `opened_at` so the policy decision (delete vs keep)
/// doesn't pay for re-reading the `.meta`.
struct SessionLogRetentionEntry: Sendable, Equatable {
    let pulselogURL: URL
    let metaURL: URL
    let openedAt: Date
}

// MARK: - FileSystemSessionLogRetentionStore (production)

/// Walks `<ApplicationSupport>/Pulse/Sessions/**` and parses each
/// `.meta` sidecar's `opened_at`. The directory layout is
/// `Pulse/Sessions/dev-<Device.id>/<timestamp>_<sessionUUID>.{pulselog,meta}`
/// (or `Pulse/Sessions/unassigned/...` when the SSH connect path didn't
/// carry a `deviceID`), per the ADR §6 amendment.
///
/// On a non-sandboxed macOS dev build the path resolves to
/// `~/Library/Application Support/Pulse/Sessions/`; under App Sandbox
/// or on iOS, to the appropriate container path. `FileManager` does
/// the platform-specific resolution behind a single API surface.
struct FileSystemSessionLogRetentionStore: SessionLogRetentionStore {

    /// Matches the subpath used by `FileSystemSessionLogFileStore` so a
    /// future writer-side change to the subpath need only update one
    /// constant — but the constant is duplicated here on purpose
    /// rather than imported, because retention and writer have
    /// distinct lifecycles and one shouldn't be able to redirect the
    /// other by accident.
    static let rootSubpath = "Pulse/Sessions"

    init() {}

    func enumerateSessions() throws -> [SessionLogRetentionEntry] {
        let root = try recordingRoot()

        // Recording root may legitimately not exist on a fresh install
        // that has never enabled recording on any credential. Treat
        // missing root as "no sessions" rather than as an error.
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [SessionLogRetentionEntry] = []
        let decoder = JSONDecoder()

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "meta" else { continue }
            let pulselogURL = url.deletingPathExtension().appendingPathExtension("pulselog")

            // Parse opened_at out of the .meta. Skip on read or decode
            // failure — a corrupted sidecar is potentially evidence
            // and shouldn't be silently retention-purged.
            guard let data = try? Data(contentsOf: url),
                  let meta = try? decoder.decode(SessionMeta.self, from: data),
                  let openedAt = SessionLogRetention.parseISO8601(meta.opened_at) else {
                continue
            }

            entries.append(
                SessionLogRetentionEntry(
                    pulselogURL: pulselogURL,
                    metaURL: url,
                    openedAt: openedAt
                )
            )
        }
        return entries
    }

    func deleteSession(_ entry: SessionLogRetentionEntry) throws {
        // Order matters: delete .pulselog first. If we crash between
        // the two unlinks, the next launch sees a .meta without a
        // .pulselog — which `enumerateSessions` includes (the meta
        // parses) and which `deleteSession` will then attempt again,
        // succeeding on the meta and treating the missing pulselog as
        // a no-op. The reverse ordering would leave a `.pulselog`
        // without a `.meta`, which `enumerateSessions` does not
        // surface (no opened_at) — so it would orphan on disk.
        try? FileManager.default.removeItem(at: entry.pulselogURL)
        try FileManager.default.removeItem(at: entry.metaURL)
    }

    private func recordingRoot() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return root.appendingPathComponent(Self.rootSubpath, isDirectory: true)
    }
}

// MARK: - SessionLogRetention

/// Launch-time retention policy for session logs.
///
/// `purgeAtLaunch(maxAge:)` is called once from `PulseApp.init` (commit
/// 10 wires the hook). It walks every persisted session, deletes any
/// pair older than `maxAge`, and emits one of two audit events:
///
/// - `session.recording.purged` with the count and oldest-purged date,
///   on completion. Fires even on a clean walk that deleted zero
///   sessions, so the audit log carries a heartbeat that purge ran.
/// - `session.recording.purgeFailed` with the underlying error message,
///   if the enumeration itself fails. Per-entry deletion failures are
///   tolerated (the next launch retries); only an enumerator-level
///   failure tips the purge into the "failed" bucket.
///
/// Failures never block app launch — the function is `async` precisely
/// so the launch sequence can fire-and-forget into a `Task`.
enum SessionLogRetention {

    /// Default retention window — 1 year, per ADR §6.
    static let defaultMaxAge: TimeInterval = 365 * 24 * 60 * 60

    private static let logger = Logger(subsystem: "pulse", category: "ssh.recording")

    /// Walks the recording root and deletes any session whose
    /// `opened_at` is older than `maxAge` relative to `referenceDate`.
    /// `referenceDate` is injected so tests can drive deterministic
    /// scenarios; production callers omit it (defaults to `Date.now`).
    ///
    /// Returns a summary the caller can log or surface in tests. The
    /// production launch hook ignores the return value.
    @discardableResult
    static func purge(
        maxAge: TimeInterval = defaultMaxAge,
        referenceDate: Date = .now,
        store: SessionLogRetentionStore = FileSystemSessionLogRetentionStore()
    ) -> PurgeOutcome {
        let entries: [SessionLogRetentionEntry]
        do {
            entries = try store.enumerateSessions()
        } catch {
            let reason = String(describing: error)
            SessionRecordingAudit.purgeFailed(reason: reason)
            return .failed(reason: reason)
        }

        let threshold = referenceDate.addingTimeInterval(-maxAge)
        var oldestPurged: Date?
        var purgedCount = 0
        var perEntryErrors: [String] = []

        for entry in entries where entry.openedAt < threshold {
            do {
                try store.deleteSession(entry)
                purgedCount += 1
                if oldestPurged == nil || entry.openedAt < oldestPurged! {
                    oldestPurged = entry.openedAt
                }
            } catch {
                perEntryErrors.append(String(describing: error))
            }
        }

        SessionRecordingAudit.purged(count: purgedCount, oldestPurgedDate: oldestPurged)
        if !perEntryErrors.isEmpty {
            // Per-entry deletion failures are surfaced through the
            // PurgeOutcome's perEntryErrors field rather than the
            // audit log: they're a deployment-environment concern
            // (file locked, permission denied, disk full) rather than
            // a security-relevant event. A standalone log line keeps
            // them visible to operators inspecting `log show` without
            // multiplying the audit-event vocabulary.
            logger.error(
                "session.recording.purge: \(perEntryErrors.count, privacy: .public) per-entry deletion error(s) — \(perEntryErrors.joined(separator: " | "), privacy: .public)"
            )
        }
        return .completed(
            purgedCount: purgedCount,
            oldestPurgedDate: oldestPurged,
            perEntryErrors: perEntryErrors
        )
    }

    /// Async wrapper for the launch hook. Spawns the purge on a
    /// detached `Task` so the calling launch sequence can return
    /// immediately. The purge is not on the critical path for any UI
    /// rendering and a stuck purge must not delay launch.
    static func purgeAtLaunch(
        maxAge: TimeInterval = defaultMaxAge,
        store: SessionLogRetentionStore = FileSystemSessionLogRetentionStore()
    ) {
        Task.detached(priority: .utility) {
            _ = purge(maxAge: maxAge, store: store)
        }
    }

    /// Parse the `.meta.opened_at` ISO 8601 string. Tolerates both
    /// fractional-second and integer-second variants because Slice 4
    /// writes fractional but a future v2 may opt to drop them; the
    /// parser absorbs both shapes so retention doesn't gate on
    /// version churn.
    static func parseISO8601(_ string: String) -> Date? {
        let strategy = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        )
        if let date = try? strategy.parse(string) {
            return date
        }
        // Fall back to non-fractional.
        let plain = Date.ISO8601FormatStyle(timeZone: .gmt)
        return try? plain.parse(string)
    }
}

// MARK: - PurgeOutcome

/// Result type from `SessionLogRetention.purge`. Tests pin every
/// case; the production launch path discards the value (the audit
/// log carries the durable record).
enum PurgeOutcome: Equatable, Sendable {
    case completed(
        purgedCount: Int,
        oldestPurgedDate: Date?,
        perEntryErrors: [String]
    )
    case failed(reason: String)
}
