//
//  SessionLogRetentionTests.swift
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

import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import Pulse

/// Coverage for `SessionLogRetention`. Drives the policy through an
/// in-memory store so the threshold maths and per-entry deletion path
/// can be pinned without touching the filesystem.
final class SessionLogRetentionTests: XCTestCase {

    // MARK: - In-memory store

    /// Carries a mutable list of sessions plus failure-injection knobs.
    final class InMemoryRetentionStore: SessionLogRetentionStore, @unchecked Sendable {
        private let entries: NIOLockedValueBox<[SessionLogRetentionEntry]>
        private let enumerateError: Error?
        private let deleteErrorFor: Set<URL>

        init(
            entries: [SessionLogRetentionEntry],
            enumerateError: Error? = nil,
            deleteErrorFor: Set<URL> = []
        ) {
            self.entries = NIOLockedValueBox(entries)
            self.enumerateError = enumerateError
            self.deleteErrorFor = deleteErrorFor
        }

        func enumerateSessions() throws -> [SessionLogRetentionEntry] {
            if let err = enumerateError { throw err }
            return entries.withLockedValue { $0 }
        }

        func deleteSession(_ entry: SessionLogRetentionEntry) throws {
            if deleteErrorFor.contains(entry.metaURL) {
                throw NSError(domain: "deleteFault", code: 1)
            }
            entries.withLockedValue { list in
                list.removeAll { $0.metaURL == entry.metaURL }
            }
        }

        func remainingURLs() -> [URL] {
            entries.withLockedValue { list in list.map { $0.metaURL } }
        }
    }

    // MARK: - Helpers

    private func entry(_ id: String, openedAt: Date) -> SessionLogRetentionEntry {
        let pulselog = URL(fileURLWithPath: "/dev/null/\(id).pulselog")
        let meta = URL(fileURLWithPath: "/dev/null/\(id).meta")
        return SessionLogRetentionEntry(
            pulselogURL: pulselog,
            metaURL: meta,
            openedAt: openedAt
        )
    }

    // MARK: - Threshold maths

    func testDeletesEntriesOlderThanMaxAge() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oneDay: TimeInterval = 24 * 60 * 60
        let store = InMemoryRetentionStore(entries: [
            entry("oldest",  openedAt: now.addingTimeInterval(-10 * oneDay)),
            entry("borderline-older", openedAt: now.addingTimeInterval(-7 * oneDay - 1)),
            entry("borderline-younger", openedAt: now.addingTimeInterval(-7 * oneDay + 1)),
            entry("fresh",   openedAt: now.addingTimeInterval(-1 * oneDay))
        ])

        let outcome = SessionLogRetention.purge(
            maxAge: 7 * oneDay,
            referenceDate: now,
            store: store
        )

        guard case .completed(let count, let oldest, let errors) = outcome else {
            return XCTFail("Expected .completed, got \(outcome)")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(oldest, now.addingTimeInterval(-10 * oneDay))

        // Remaining sessions on disk: only the two within the window.
        let remaining = store.remainingURLs().map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(remaining, ["borderline-younger.meta", "fresh.meta"])
    }

    func testEmptyStoreReturnsZeroAndEmptyErrors() {
        let store = InMemoryRetentionStore(entries: [])
        let outcome = SessionLogRetention.purge(
            maxAge: 60,
            referenceDate: .now,
            store: store
        )
        XCTAssertEqual(outcome, .completed(purgedCount: 0, oldestPurgedDate: nil, perEntryErrors: []))
    }

    func testEntriesWithinWindowAreUntouched() {
        let now = Date()
        let store = InMemoryRetentionStore(entries: [
            entry("a", openedAt: now.addingTimeInterval(-60)),
            entry("b", openedAt: now)
        ])
        let outcome = SessionLogRetention.purge(
            maxAge: 3600,
            referenceDate: now,
            store: store
        )
        XCTAssertEqual(outcome, .completed(purgedCount: 0, oldestPurgedDate: nil, perEntryErrors: []))
        XCTAssertEqual(store.remainingURLs().count, 2)
    }

    // MARK: - Failure handling

    func testEnumerateFailureSurfacesAsFailedOutcome() {
        let store = InMemoryRetentionStore(
            entries: [],
            enumerateError: NSError(domain: "walkFault", code: 7)
        )
        let outcome = SessionLogRetention.purge(
            maxAge: 60,
            referenceDate: .now,
            store: store
        )
        guard case .failed(let reason) = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("walkFault"))
    }

    func testPerEntryDeletionFailureIsToleratedAndReported() {
        let now = Date()
        let oldA = entry("old-a", openedAt: now.addingTimeInterval(-1000))
        let oldB = entry("old-b", openedAt: now.addingTimeInterval(-2000))
        let store = InMemoryRetentionStore(
            entries: [oldA, oldB],
            deleteErrorFor: [oldA.metaURL]
        )
        let outcome = SessionLogRetention.purge(
            maxAge: 100,
            referenceDate: now,
            store: store
        )
        guard case .completed(let count, _, let errors) = outcome else {
            return XCTFail("Expected .completed, got \(outcome)")
        }
        XCTAssertEqual(count, 1, "Only the deletable entry should be counted")
        XCTAssertEqual(errors.count, 1, "The failing entry should produce one error")

        // oldA persists (delete failed); oldB unlinked.
        let remaining = store.remainingURLs().map { $0.lastPathComponent }
        XCTAssertEqual(remaining, ["old-a.meta"])
    }

    // MARK: - Idempotence

    func testPurgeIsIdempotent() {
        let now = Date()
        let store = InMemoryRetentionStore(entries: [
            entry("old", openedAt: now.addingTimeInterval(-3600)),
            entry("fresh", openedAt: now)
        ])

        let first = SessionLogRetention.purge(maxAge: 60, referenceDate: now, store: store)
        let second = SessionLogRetention.purge(maxAge: 60, referenceDate: now, store: store)

        // First call deletes the old entry; second call sees only the
        // fresh entry remaining and does nothing.
        guard case .completed(let firstCount, _, _) = first,
              case .completed(let secondCount, _, _) = second else {
            return XCTFail("Both purges should complete")
        }
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0)
        XCTAssertEqual(store.remainingURLs().count, 1)
    }

    // MARK: - ISO8601 parser

    func testParseISO8601AcceptsFractionalAndPlain() {
        XCTAssertNotNil(SessionLogRetention.parseISO8601("2026-05-26T03:41:12.184Z"))
        XCTAssertNotNil(SessionLogRetention.parseISO8601("2026-05-26T03:41:12Z"))
    }

    func testParseISO8601RejectsGibberish() {
        XCTAssertNil(SessionLogRetention.parseISO8601("not a date"))
        XCTAssertNil(SessionLogRetention.parseISO8601(""))
    }
}
