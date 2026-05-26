//
//  PulseTerminalAdapterTests.swift
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
import XCTest
@testable import Pulse

/// Pins the non-obvious correctness properties of `PulseTerminalSurface`,
/// the binding object between SwiftTerm's `TerminalViewDelegate` and the
/// operator view's SSH session. Each test would be added back if deleted:
/// the byte-pump ordering contract and the resize-dedupe guards are
/// silent regressions that would otherwise only surface in lab.
///
/// SwiftTerm rendering, SwiftUI representable lifecycle, and AppKit /
/// UIKit view machinery are deliberately not exercised here. Those are
/// the framework's job and a unit test of them would be tautological.
final class PulseTerminalAdapterTests: XCTestCase {

    /// Keystroke ordering through the byte pump. The contract:
    /// `forwardKeystrokes` invocations reach `sendHandler` in arrival
    /// order with byte content unchanged. A future "optimisation" that
    /// buffered, coalesced, reordered, or deduplicated would silently
    /// break interactive shell fidelity (e.g. `:wq` in vim becoming
    /// `:` then `w` then `q` in the wrong order would corrupt the
    /// command stream). The recording-tap depends on this ordering for
    /// the on-disk `.pulselog` to replay correctly.
    func testForwardKeystrokesPreservesOrderAndContent() {
        let surface = PulseTerminalSurface()
        let received = ReceivedBytesCollector()
        surface.sendHandler = { bytes in received.append(Array(bytes)) }

        // Interleaved arrival shape: a single byte, a multi-byte slice,
        // a single byte, an empty slice. Each invocation lands as one
        // element in the collected array, in order.
        surface.forwardKeystrokes(ArraySlice([0x61]))                  // 'a'
        surface.forwardKeystrokes(ArraySlice([0x62, 0x63, 0x64]))      // "bcd"
        surface.forwardKeystrokes(ArraySlice([0x65]))                  // 'e'
        surface.forwardKeystrokes(ArraySlice([]))                      // empty

        XCTAssertEqual(received.snapshot(), [[0x61], [0x62, 0x63, 0x64], [0x65], []])
    }

    /// Resize dedupe. SwiftUI calls `updateNSView` / `updateUIView` on
    /// every render pass, not only on geometry changes; without dedupe
    /// each render would fire `SSHSession.resize(cols:rows:)` and
    /// flood the server with redundant `WindowChangeRequest` events.
    func testNotifyResizeFiresOnlyOnDimensionChange() {
        let surface = PulseTerminalSurface()
        let sizes = ResizeCollector()
        surface.resizeHandler = { cols, rows in sizes.append(cols: cols, rows: rows) }

        surface.notifyResize(cols: 80, rows: 24)
        surface.notifyResize(cols: 80, rows: 24)    // unchanged
        surface.notifyResize(cols: 80, rows: 24)    // unchanged
        surface.notifyResize(cols: 120, rows: 40)
        surface.notifyResize(cols: 120, rows: 40)   // unchanged

        XCTAssertEqual(sizes.snapshot(), [Size(cols: 80, rows: 24), Size(cols: 120, rows: 40)])
    }

    /// Zero-or-negative dimensions are ignored. Early SwiftUI render
    /// passes can report 0-sized geometry before layout completes;
    /// forwarding a `cols=0` resize would propagate as a degenerate
    /// `SSHSession.resize(cols: 0, rows: 0)` call, which is a valid
    /// SSH `window-change` packet but semantically meaningless (no
    /// renderable area). The server might honour it and clear the
    /// display.
    func testNotifyResizeIgnoresZeroOrNegativeDimensions() {
        let surface = PulseTerminalSurface()
        let sizes = ResizeCollector()
        surface.resizeHandler = { cols, rows in sizes.append(cols: cols, rows: rows) }

        surface.notifyResize(cols: 0, rows: 0)
        surface.notifyResize(cols: 0, rows: 24)
        surface.notifyResize(cols: 80, rows: 0)
        surface.notifyResize(cols: -1, rows: 24)
        surface.notifyResize(cols: 80, rows: -1)
        surface.notifyResize(cols: 80, rows: 24)    // only this one is valid

        XCTAssertEqual(sizes.snapshot(), [Size(cols: 80, rows: 24)])
    }

    /// FIFO coalesce of inbound server bytes. The contract:
    /// `feed(_:)` calls arriving in close succession (between MainActor
    /// drain hops) accumulate into a single pending buffer in arrival
    /// order, and exactly one drain hop is scheduled per burst.
    ///
    /// This is the load-bearing replacement for the slice-5 Task-per-chunk
    /// pattern, which (a) starved the run loop on bursty output and (b)
    /// relied on a FIFO ordering guarantee Swift's concurrency runtime
    /// does not promise for unstructured `Task` dispatches. Mirrors
    /// `SessionLogWriter.drainQueue`'s single-flight shape.
    ///
    /// Single-producer framing keeps the test deterministic: we are
    /// pinning what the lock observes under sequential calls, not what
    /// the Swift runtime promises for cross-Task arrival ordering
    /// (which it doesn't).
    ///
    /// The test runs on the MainActor so the `Task { @MainActor ... }`
    /// drain hop scheduled by `feed(_:)` queues behind the synchronous
    /// test body and cannot run before the assertions observe the
    /// pre-drain state. Off-MainActor the test would race the drain.
    @MainActor
    func testFeedCoalescesMultipleChunksBeforeMainActorDrain() {
        let surface = PulseTerminalSurface()

        // Three feeds in succession, no awaits between them. Each
        // append is under the lock; the second and third see
        // `hopScheduled == true` and skip the Task dispatch.
        surface.feed(ArraySlice([0x01, 0x02]))
        surface.feed(ArraySlice([0x03]))
        surface.feed(ArraySlice([0x04, 0x05, 0x06]))

        // All bytes are pending in arrival order, exactly one drain
        // hop is scheduled. The scheduled Task is queued behind this
        // synchronous test body because we are on MainActor.
        XCTAssertEqual(surface.pendingByteCount, 6)
        XCTAssertTrue(surface.isDrainHopScheduled)

        // Drain via the synchronous test seam. This is the same swap
        // the MainActor drain would perform; whichever fires first
        // gets the bytes, the other gets an empty snapshot.
        let drained = surface.consumePendingBytes()
        XCTAssertEqual(drained, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        XCTAssertEqual(surface.pendingByteCount, 0)
        XCTAssertFalse(surface.isDrainHopScheduled)
    }

    /// After a drain, the next `feed` call schedules a fresh hop. The
    /// `hopScheduled` latch resets cleanly so a follow-up burst does
    /// not stall.
    @MainActor
    func testFeedReschedulesAfterDrain() {
        let surface = PulseTerminalSurface()

        surface.feed(ArraySlice([0x10]))
        _ = surface.consumePendingBytes()
        XCTAssertFalse(surface.isDrainHopScheduled)

        surface.feed(ArraySlice([0x20]))
        XCTAssertTrue(surface.isDrainHopScheduled)
        XCTAssertEqual(surface.pendingByteCount, 1)
    }

    // MARK: - Test helpers

    /// Lock-protected byte-list collector. `sendHandler` is a
    /// `@Sendable` closure so the captured collector must also be safe
    /// to mutate from any context; an `Array` capture would otherwise
    /// trip Swift 6 strict-concurrency.
    private final class ReceivedBytesCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [[UInt8]] = []
        func append(_ chunk: [UInt8]) {
            lock.lock(); defer { lock.unlock() }
            bytes.append(chunk)
        }
        func snapshot() -> [[UInt8]] {
            lock.lock(); defer { lock.unlock() }
            return bytes
        }
    }

    private struct Size: Equatable {
        let cols: Int
        let rows: Int
    }

    private final class ResizeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [Size] = []
        func append(cols: Int, rows: Int) {
            lock.lock(); defer { lock.unlock() }
            sizes.append(Size(cols: cols, rows: rows))
        }
        func snapshot() -> [Size] {
            lock.lock(); defer { lock.unlock() }
            return sizes
        }
    }
}
