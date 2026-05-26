//
//  PulseTerminalAdapter.swift
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

import SwiftUI
import SwiftTerm
import NIOConcurrencyHelpers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - PulseTerminalSurface

/// Binding object between the SwiftUI adapter and the operator-facing
/// view. Holds the closures that move bytes in and out of SwiftTerm:
///
/// - `feed(_:)` accepts server bytes (called from
///   `SSHSession.setOutputHandler` on the EventLoop thread) and hands
///   them to the live `Terminal` instance on the main actor via
///   `Terminal.feed(buffer: ArraySlice<UInt8>)`, the zero-copy slice
///   overload at `Sources/SwiftTerm/Terminal.swift:4890`.
/// - `sendHandler` is invoked when the terminal emits keystrokes
///   (`TerminalViewDelegate.send`). The operator view sets this to
///   forward into `SSHSession.write(_:)`.
/// - `resizeHandler` is invoked when the terminal's column / row count
///   changes. The operator view sets this to forward into
///   `SSHSession.resize(cols:rows:)`.
///
/// **Why a separate class.** SwiftUI's `NSViewRepresentable` /
/// `UIViewRepresentable` value-type structs cannot hold a reference to
/// the platform view; that reference lives on the `Coordinator`. The
/// operator view's connection state (the `SSHClient`, the SwiftData
/// `Device`) lives on the view's own `@State`. The surface is the
/// stable identity that lets the operator view's lifecycle reach
/// across to the live view without coupling SwiftUI value semantics
/// to AppKit / UIKit reference semantics.
///
/// **Concurrency.** Mirrors the `SSHSession` pattern: state lives in
/// an `NIOLockedValueBox` so the surface can be touched from the
/// EventLoop (`feed`), from the main thread (handler setup, resize
/// dispatch), and from any actor that owns the operator view, all
/// without requiring a single isolation domain. The weak view
/// reference is `nonisolated(unsafe)` because every access path
/// (`makeNSView`, `makeUIView`, the main-actor hop inside `feed`) is
/// disciplined to run on the main thread.
final class PulseTerminalSurface: ObservableObject, @unchecked Sendable {

    private struct State {
        var sendHandler: (@Sendable (ArraySlice<UInt8>) -> Void)?
        var resizeHandler: (@Sendable (Int, Int) -> Void)?
        var lastCols: Int = 0
        var lastRows: Int = 0
        /// Inbound bytes that arrived between hops. All mutation flows
        /// through `state.withLockedValue`; see `feed` and
        /// `drainPendingFeed`.
        var pendingBytes: [UInt8] = []
        /// True between scheduling a drain hop and the drain reading the
        /// pending bytes back out. Coalesces bursts so the main run loop
        /// is not starved by a Task-per-chunk storm.
        var hopScheduled: Bool = false
    }

    private let state = NIOLockedValueBox<State>(.init())

    /// The platform `TerminalView` instance. Set in `makeNSView` /
    /// `makeUIView` (main thread), read in `feed`'s main-actor hop
    /// (also main thread). `nonisolated(unsafe)` keeps the compiler
    /// quiet about the cross-context store without paying for a lock
    /// on the hot path; the discipline is enforced at the call sites.
    nonisolated(unsafe) fileprivate weak var view: PulseTerminalAdapter.PlatformTerminalView?

    init() {}

    /// Operator view sets this to `{ bytes in await session.write(bytes) }`
    /// or equivalent. `@Sendable` because keystrokes flow into
    /// `SSHSession`, which is actor-isolated; the closure crosses the
    /// boundary.
    var sendHandler: (@Sendable (ArraySlice<UInt8>) -> Void)? {
        get { state.withLockedValue { $0.sendHandler } }
        set { state.withLockedValue { $0.sendHandler = newValue } }
    }

    /// Operator view sets this to forward into
    /// `SSHSession.resize(cols:rows:)`.
    var resizeHandler: (@Sendable (Int, Int) -> Void)? {
        get { state.withLockedValue { $0.resizeHandler } }
        set { state.withLockedValue { $0.resizeHandler = newValue } }
    }

    /// Feed bytes from the server into the terminal. Called from the
    /// SSH session's `setOutputHandler` closure, which fires on the
    /// EventLoop thread on every inbound `SSHChannelData(.channel)` read.
    ///
    /// **Single-flight coalesce.** Bytes are appended to a pending buffer
    /// under the lock; a single `Task { @MainActor ... }` hop is scheduled
    /// at the first append in a burst, and subsequent appends piggy-back
    /// on the same hop. The drain reads the pending buffer out under the
    /// lock and calls the view's `feed(byteArray:)` exactly once per hop.
    /// The shape mirrors `SessionLogWriter.drainQueue` and replaces the
    /// prior Task-per-chunk pattern, which (a) starved the run loop on
    /// bursty output and (b) relied on a FIFO ordering guarantee Swift's
    /// concurrency runtime does not promise for unstructured `Task`
    /// dispatches.
    ///
    /// Forwards through SwiftTerm's `TerminalView.feed(byteArray: ArraySlice<UInt8>)`
    /// at `Sources/SwiftTerm/Apple/AppleTerminalView.swift:1910`. The
    /// view-level call wraps `Terminal.feed(buffer:)` (the engine; same
    /// zero-copy slice path) with `feedPrepare()` and `feedFinish()`,
    /// the latter of which calls `queuePendingDisplay()` to schedule an
    /// AppKit/UIKit `setNeedsDisplay` cycle. Calling only
    /// `Terminal.feed(buffer:)` would update the grid model but never
    /// mark the platform view dirty; the operator would see no output
    /// until something else (a click, a keystroke, a resize) triggered
    /// a redraw. The view-level wrapper is what makes terminal output
    /// realtime under SwiftTerm's coalesced display-update model.
    /// The slice's backing storage comes from
    /// `SSHSession.deliverOutput`'s `getBytes`-materialised `[UInt8]`,
    /// not from a shared ByteBuffer, so cross-thread capture is safe.
    func feed(_ bytes: ArraySlice<UInt8>) {
        let needsHop = state.withLockedValue { state -> Bool in
            state.pendingBytes.append(contentsOf: bytes)
            if state.hopScheduled { return false }
            state.hopScheduled = true
            return true
        }
        guard needsHop else { return }
        Task { @MainActor [weak self] in
            self?.drainPendingFeed()
        }
    }

    /// Main-actor drain for the coalesced byte pump. Swaps the pending
    /// buffer out under the lock, clears `hopScheduled`, and (if the
    /// snapshot is non-empty) calls the view-level
    /// `TerminalView.feed(byteArray:)` exactly once. The view-level
    /// call is required (not the engine-level `Terminal.feed(buffer:)`)
    /// because SwiftTerm's `feedFinish` is what queues the AppKit /
    /// UIKit display update via `queuePendingDisplay()`. Held capacity
    /// is preserved across drains so the bursty hot path does not
    /// thrash the allocator.
    @MainActor
    private func drainPendingFeed() {
        let snapshot = consumePendingBytes()
        guard !snapshot.isEmpty else { return }
        view?.feed(byteArray: ArraySlice(snapshot))
    }

    /// Atomic swap of the pending buffer. Returns the accumulated bytes
    /// in arrival order and clears `hopScheduled` so the next feed
    /// schedules a fresh drain. Extracted as a seam so the coalesce
    /// contract is exercisable from tests without standing up a real
    /// `TerminalView`. The race between a test calling this and the
    /// scheduled MainActor drain is benign: whoever wins the lock takes
    /// the bytes; the loser gets an empty snapshot and is a no-op.
    func consumePendingBytes() -> [UInt8] {
        state.withLockedValue { state in
            state.hopScheduled = false
            let out = state.pendingBytes
            state.pendingBytes.removeAll(keepingCapacity: true)
            return out
        }
    }

    /// Read-only snapshot of the pending byte buffer. Test-observable
    /// without consuming the buffer; production code does not read this.
    var pendingByteCount: Int {
        state.withLockedValue { $0.pendingBytes.count }
    }

    /// Whether a MainActor drain hop is currently scheduled. Becomes
    /// true on the first `feed` in a burst and false either when the
    /// hop runs the drain or when a test calls `consumePendingBytes`.
    var isDrainHopScheduled: Bool {
        state.withLockedValue { $0.hopScheduled }
    }

    /// Invoked by the adapter's `TerminalViewDelegate.send` conformance.
    /// Forwards the operator's keystrokes unchanged through the
    /// configured `sendHandler` closure. Tested directly without
    /// instantiating a `TerminalView`: the contract is that bytes
    /// arrive at the handler in the same order and content they
    /// arrived from SwiftTerm.
    func forwardKeystrokes(_ data: ArraySlice<UInt8>) {
        let handler = state.withLockedValue { $0.sendHandler }
        handler?(data)
    }

    /// Invoked by the adapter's `updateNSView` / `updateUIView`
    /// lifecycle and by `TerminalViewDelegate.sizeChanged` (the latter
    /// fires when SwiftTerm reflows in response to a DECCOLM-style
    /// escape sequence from the server). Both paths converge here.
    /// Fires the resize handler only when the dimensions changed, and
    /// only when both are positive: early SwiftUI render passes can
    /// report 0-sized geometry before layout completes, and a
    /// `cols=0` resize would propagate as a degenerate
    /// `SSHSession.resize(cols:0, rows:0)` call.
    func notifyResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let outcome = state.withLockedValue { current -> (changed: Bool, handler: (@Sendable (Int, Int) -> Void)?) in
            guard cols != current.lastCols || rows != current.lastRows else {
                return (false, nil)
            }
            current.lastCols = cols
            current.lastRows = rows
            return (true, current.resizeHandler)
        }
        if outcome.changed {
            outcome.handler?(cols, rows)
        }
    }
}

// MARK: - PulseTerminalAdapter

/// SwiftUI wrapper around SwiftTerm's `TerminalView`. Pulse-owned because
/// SwiftTerm ships AppKit / UIKit views but no generic SwiftUI bridge:
/// the iOS sample's `SwiftUITerminalView` is `#if canImport(UIKit) && DEBUG`
/// (internal-for-testing, iOS-only), so reusing it would push us into a
/// debug-only / single-platform corner. Keeping the adapter Pulse-owned
/// and minimal lets the SSH layer stay strictly concerned with byte
/// transport while supporting both macOS and iOS production builds.
///
/// **Hot path.** Bytes flow through `Terminal.feed(buffer: ArraySlice<UInt8>)`
/// (the slice overload at `Sources/SwiftTerm/Terminal.swift:4890`), which
/// is zero-copy from Pulse's `SSHSession.setOutputHandler` closure shape.
/// The other two `feed` overloads (`[UInt8]` and `String`) allocate per
/// call and must not be used for the SSH consume path: the recording-tap
/// byte-pump can push kilobyte-per-record paste-bombs through here, and
/// avoiding the allocation is non-negotiable.
///
/// **Delegate model.** SwiftTerm ships two delegate protocols:
/// `TerminalDelegate` (engine-level, lower-layer; see `Terminal.swift:18`)
/// and `TerminalViewDelegate` (UI-level, what host apps implement; see
/// `Apple/TerminalViewDelegate.swift:12`). The adapter's `Coordinator`
/// conforms to `TerminalViewDelegate`. The 10 required methods are
/// either wired through the surface (`send`, `sizeChanged`) or stubbed
/// empty (title, directory, scrolled, clipboard, rangeChanged) or
/// implemented to forward to the system (`requestOpenLink`). `bell`
/// and `iTermContent` have default protocol-extension implementations
/// in SwiftTerm's platform files.
///
/// **Resize.** Both `MacTerminalView.setFrameSize(_:)` and
/// `iOSTerminalView.layoutSubviews()` internally call SwiftTerm's
/// `processSizeChange`, which reflows the terminal grid to the new
/// pixel size. The adapter reads `terminal.cols` / `terminal.rows`
/// inside `updateNSView` / `updateUIView` (which SwiftUI fires after
/// layout) and forwards changes through `PulseTerminalSurface.notifyResize`
/// which dedupes and guards against zero dimensions. The
/// `TerminalViewDelegate.sizeChanged` callback fires for server-driven
/// reflows (DECCOLM 80/132 column switches) and converges on the
/// same surface method, so both paths share the dedupe logic.
struct PulseTerminalAdapter {

    /// Stable identity holding the byte-pump wiring closures. The
    /// operator view owns this; the adapter holds it during its
    /// SwiftUI lifetime.
    let surface: PulseTerminalSurface

    /// The platform `TerminalView` type SwiftTerm ships under
    /// `Sources/SwiftTerm/Mac/MacTerminalView.swift` (NSView) and
    /// `Sources/SwiftTerm/iOS/iOSTerminalView.swift` (UIView). Both
    /// export the same `TerminalView` symbol; the typealias keeps
    /// call sites platform-agnostic.
    typealias PlatformTerminalView = SwiftTerm.TerminalView
}

#if os(macOS)

extension PulseTerminalAdapter: NSViewRepresentable {

    typealias NSViewType = PlatformTerminalView

    func makeNSView(context: Context) -> PlatformTerminalView {
        let view = PlatformTerminalView(frame: .zero, font: nil)
        view.terminalDelegate = context.coordinator
        surface.view = view
        return view
    }

    func updateNSView(_ nsView: PlatformTerminalView, context: Context) {
        let terminal = nsView.getTerminal()
        surface.notifyResize(cols: terminal.cols, rows: terminal.rows)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: surface)
    }
}

#else

extension PulseTerminalAdapter: UIViewRepresentable {

    typealias UIViewType = PlatformTerminalView

    func makeUIView(context: Context) -> PlatformTerminalView {
        let view = PlatformTerminalView(frame: .zero, font: nil)
        view.terminalDelegate = context.coordinator
        surface.view = view
        return view
    }

    func updateUIView(_ uiView: PlatformTerminalView, context: Context) {
        let terminal = uiView.getTerminal()
        surface.notifyResize(cols: terminal.cols, rows: terminal.rows)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: surface)
    }
}

#endif

// MARK: - Coordinator

extension PulseTerminalAdapter {

    /// Conforms to SwiftTerm's `TerminalViewDelegate`. The protocol
    /// has 10 required methods covering UI-level events. Only two are
    /// load-bearing for Pulse: `send` (operator keystrokes → SSH) and
    /// `sizeChanged` (server-driven reflow → SSH resize). The rest
    /// are stubbed empty or forward to the system; `bell` and
    /// `iTermContent` use SwiftTerm's default implementations.
    final class Coordinator: NSObject, TerminalViewDelegate {

        let surface: PulseTerminalSurface

        init(surface: PulseTerminalSurface) {
            self.surface = surface
            super.init()
        }

        /// Operator keystrokes from the terminal. Forwarded unchanged
        /// to the surface, which invokes the configured `sendHandler`.
        /// The data parameter is `ArraySlice<UInt8>` end to end, so
        /// the forward is zero-copy.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            surface.forwardKeystrokes(data)
        }

        /// Server-driven reflow (typically DECCOLM 80/132 column
        /// switching). Forwarded through the same dedupe path that
        /// SwiftUI-layout-driven resizes use.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            surface.notifyResize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Not surfaced to the operator. A future Settings → SSH
            // option could route window-title updates into the
            // SwiftUI title binding.
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // OSC 7. Not surfaced.
        }

        func scrolled(source: TerminalView, position: Double) {
            // Scrollback position is the operator's concern, not
            // ours: SwiftTerm handles its own scroll UI.
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            // OSC 52. Bridging clipboard-write requests from the
            // server is a security-sensitive surface and is
            // deliberately deferred.
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            // Visual-change notification. Only fires when SwiftTerm's
            // `notifyUpdateChanges` is set true, which Pulse leaves
            // false.
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // Operator clicked a link in the terminal output. Hand
            // off to the system URL handler. Mirrors the default
            // implementation SwiftTerm provides on macOS at
            // `MacTerminalView.swift:2402`; on iOS the default is
            // absent so we provide one explicitly.
            guard let url = URL(string: link) else { return }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
    }
}
