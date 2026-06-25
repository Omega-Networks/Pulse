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

    /// Bell forwarding. The contract: each `fireBell()` call invokes
    /// the registered `bellHandler` exactly once. A future change that
    /// buffered, coalesced, or rate-limited bells without surfacing
    /// that fact would break operator expectations (an `^G`-per-line
    /// log tail should produce a beep per line, not one beep per
    /// burst). The audible / visual response is the operator view's
    /// concern; the surface's job is to fire the closure faithfully.
    func testFireBellInvokesHandlerExactlyOnce() {
        let surface = PulseTerminalSurface()
        let counter = CallCounter()
        surface.bellHandler = { counter.increment() }

        surface.fireBell()
        surface.fireBell()
        surface.fireBell()

        XCTAssertEqual(counter.value, 3)
    }

    /// Operator-view teardown can race a server-initiated bell — the
    /// SwiftTerm coordinator can fire `bell` after `bellHandler` has
    /// been cleared (e.g. during view dismissal). The contract: a
    /// nil-handler bell is a clean no-op rather than a crash.
    func testFireBellWithoutHandlerIsNoop() {
        let surface = PulseTerminalSurface()
        // No handler set. Three calls; if the surface crashed on a
        // nil bell handler it would not return.
        surface.fireBell()
        surface.fireBell()
        surface.fireBell()
        XCTAssertNil(surface.bellHandler)
    }

    /// Audible bell rate-limit. A server sending BEL in a tight loop
    /// (`yes $'\a' | head -n 100`, a runaway script, or a malicious
    /// payload) would otherwise queue one `NSSound.beep()` per event
    /// — operator-disrupting at best, weaponisable against an open-
    /// plan ops room at worst. The 250 ms gate caps audible bells at
    /// ~4 Hz, faster than a human can distinguish individual beeps
    /// but slow enough to remain recognisable as a bell rather than
    /// a continuous tone. Pinned here because the gate is the
    /// structural enforcement; losing it would silently re-introduce
    /// the bell-storm hazard, which is the kind of regression that
    /// only surfaces in lab and looks like "the bell is just loud".
    @MainActor
    func testAudibleBellGateDropsRepeatedRequestsWithinWindow() {
        let controller = TerminalBellController()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)

        // Five rapid-fire bell requests inside the gate window. The
        // gate is 250 ms; spacing here is 50 ms (all well inside the
        // window). Only the first should fire.
        controller.requestAudibleBell(now: t0)
        controller.requestAudibleBell(now: t0.addingTimeInterval(0.05))
        controller.requestAudibleBell(now: t0.addingTimeInterval(0.10))
        controller.requestAudibleBell(now: t0.addingTimeInterval(0.15))
        controller.requestAudibleBell(now: t0.addingTimeInterval(0.20))
        XCTAssertEqual(controller.audibleBellFireCount, 1)

        // First request outside the window. The gate resets so this
        // one fires, then a follow-up inside the new window drops.
        controller.requestAudibleBell(now: t0.addingTimeInterval(0.30))
        XCTAssertEqual(controller.audibleBellFireCount, 2)
        controller.requestAudibleBell(now: t0.addingTimeInterval(0.40))
        XCTAssertEqual(controller.audibleBellFireCount, 2)

        // Far outside the window. Fires again. Pins that the gate is
        // a sliding 250 ms window from the *last fire*, not a fixed
        // global clock that would lock out an operator who connected
        // mid-storm.
        controller.requestAudibleBell(now: t0.addingTimeInterval(10.0))
        XCTAssertEqual(controller.audibleBellFireCount, 3)
    }

    /// Recording-status indicator lifecycle. The contract: when the
    /// active credential's `recordSessions` flag is on, the badge
    /// appears at session-open and clears at `signalExit`. The third
    /// `addExitHandler` registration is the seam that enforces this;
    /// `registerRecordingLifecycle` factors it out of the lifecycle
    /// wrapper so the bool-flip contract is testable here rather
    /// than only via an end-to-end SwiftUI run.
    ///
    /// The test exercises both the inline `onChange(true)` (after
    /// registration) and the deferred `onChange(false)` (via the
    /// MainActor Task hop on signalExit). Mirrors the SSHSession
    /// late-attach immediate-fire shape: the stub registrar captures
    /// the handler, lets the registration return, then fires it
    /// manually with a representative `ExitCause`.
    @MainActor
    func testRegisterRecordingLifecycleFlipsOnRegistrationAndExit() async {
        let collector = StateCollector()
        let registrar = ExitHandlerRegistrar()

        await SSHTerminalConnectionViewModel.registerRecordingLifecycle(
            register: { handler in await registrar.attach(handler) },
            onChange: { newValue in collector.append(newValue) }
        )

        // After registration, the indicator should be on (inline
        // `onChange(true)` from the helper). The exit handler has
        // not fired yet.
        XCTAssertEqual(collector.snapshot(), [true])
        XCTAssertNotNil(registrar.capturedHandler)

        // Fire the exit handler the way `SSHSession.signalExit`
        // would: synchronously, with the recorded cause. The helper
        // hops the false-flip through a MainActor Task; await the
        // task scheduler so the deferred call lands before assertion.
        registrar.fire(.channelError(reason: "lab"))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(collector.snapshot(), [true, false])
    }

    /// Font-size clamp. Operators stuck with a stale UserDefaults
    /// value outside the supported range (manual override, a future
    /// bound change, an imported settings dump) still get a sane
    /// terminal: the read path clamps to `[minFontSize, maxFontSize]`
    /// so the rendered size never falls outside the validated range.
    /// Pinned here because the clamp is the structural enforcement of
    /// the documented bound — losing it would silently let a stored
    /// `0.0` or `9999.0` reach SwiftTerm's font-size machinery.
    func testFontSizeClampBoundsValuesIntoSupportedRange() {
        XCTAssertEqual(PulseTerminalAdapter.clampFontSize(-5.0), PulseTerminalAdapter.minFontSize)
        XCTAssertEqual(PulseTerminalAdapter.clampFontSize(0.0), PulseTerminalAdapter.minFontSize)
        XCTAssertEqual(PulseTerminalAdapter.clampFontSize(PulseTerminalAdapter.minFontSize - 0.1), PulseTerminalAdapter.minFontSize)
        XCTAssertEqual(PulseTerminalAdapter.clampFontSize(PulseTerminalAdapter.minFontSize), PulseTerminalAdapter.minFontSize)
        XCTAssertEqual(PulseTerminalAdapter.clampFontSize(12.0), 12.0)
        XCTAssertEqual(PulseTerminalAdapter.clampFontSize(PulseTerminalAdapter.maxFontSize), PulseTerminalAdapter.maxFontSize)
        XCTAssertEqual(PulseTerminalAdapter.clampFontSize(PulseTerminalAdapter.maxFontSize + 0.1), PulseTerminalAdapter.maxFontSize)
        XCTAssertEqual(PulseTerminalAdapter.clampFontSize(9999.0), PulseTerminalAdapter.maxFontSize)
        XCTAssertEqual(PulseTerminalAdapter.clampFontSize(.infinity), PulseTerminalAdapter.maxFontSize)
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

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    /// Captures the recording-lifecycle onChange invocations in
    /// arrival order. The helper invokes onChange from MainActor
    /// (the inline true-flip) and from a deferred MainActor Task
    /// (the false-flip from the captured exit handler); both paths
    /// converge on this collector via the @MainActor isolation
    /// shared with the test.
    @MainActor
    private final class StateCollector {
        private var values: [Bool] = []
        func append(_ value: Bool) { values.append(value) }
        func snapshot() -> [Bool] { values }
    }

    /// Stub for the `RecordingLifecycleRegistrar` shape used by
    /// `registerRecordingLifecycle`. Captures the registered handler
    /// so the test can fire it manually with a representative
    /// `ExitCause`, exercising the same path `SSHSession.signalExit`
    /// would take in production. `@unchecked Sendable` because the
    /// registrar is invoked from a `@Sendable` async function-type
    /// parameter; the @MainActor isolation around the test keeps the
    /// usage single-threaded.
    @MainActor
    private final class ExitHandlerRegistrar {
        var capturedHandler: ((ExitCause) -> Void)?

        func attach(_ handler: @escaping @Sendable (ExitCause) -> Void) async {
            capturedHandler = handler
        }

        func fire(_ cause: ExitCause) {
            capturedHandler?(cause)
        }
    }
}
