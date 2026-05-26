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

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// SwiftUI wrapper around SwiftTerm's `TerminalView`. Pulse-owned because
/// SwiftTerm ships AppKit / UIKit views but no generic SwiftUI bridge:
/// the iOS sample's `TerminalHostRepresentable` is SSH-specific (it embeds
/// connection logic), so reusing it would push SSH semantics into the UI
/// adapter. Keeping the adapter Pulse-owned and minimal lets the SSH layer
/// stay strictly concerned with byte transport.
///
/// **Hot path.** Bytes flow through `Terminal.feed(buffer: ArraySlice<UInt8>)`
/// (the slice overload at `Sources/SwiftTerm/Terminal.swift:4890`), which
/// is zero-copy from Pulse's `SSHSession.setOutputHandler` closure shape.
/// The other two `feed` overloads (`[UInt8]` and `String`) allocate per
/// call and must not be used for the SSH consume path: the recording-tap
/// byte-pump can push kilobyte-per-record paste-bombs through here, and
/// avoiding the allocation is non-negotiable.
///
/// **Delegate model.** SwiftTerm exposes a single `TerminalDelegate`
/// protocol (`Sources/SwiftTerm/Terminal.swift:18`). There is no
/// separate `TerminalViewDelegate`. The adapter's `Coordinator` conforms
/// to `TerminalDelegate` and forwards keystroke output through a
/// closure to the operator-facing view, which in turn forwards into
/// `SSHSession.write(_:)` (also `ArraySlice<UInt8>`-shaped, also
/// zero-copy on the keystroke direction).
///
/// **Resize.** `TerminalDelegate.sizeChanged(source:)` at
/// `Terminal.swift:69` is documented as "not wired up" via the
/// escape-sequence path. The adapter drives resize from the platform
/// view's bounds observer (`NSView.frame` / `UIView.bounds` change)
/// into a `resizeHandler` closure that the operator view wires to
/// `SSHSession.resize(cols:rows:)`. The bounds observer is wired in
/// a subsequent change; this scaffold establishes the SwiftUI surface
/// and the underlying `TerminalView` lifecycle only.
struct PulseTerminalAdapter {
    // The platform `TerminalView` type SwiftTerm ships under
    // `Sources/SwiftTerm/Mac/MacTerminalView.swift` (NSView) and
    // `Sources/SwiftTerm/iOS/iOSTerminalView.swift` (UIView). Both
    // export the same `TerminalView` symbol; the typealias here keeps
    // call sites platform-agnostic.
    #if os(macOS)
    typealias PlatformTerminalView = SwiftTerm.TerminalView
    #else
    typealias PlatformTerminalView = SwiftTerm.TerminalView
    #endif
}

#if os(macOS)

extension PulseTerminalAdapter: NSViewRepresentable {

    typealias NSViewType = PlatformTerminalView

    func makeNSView(context: Context) -> PlatformTerminalView {
        // Initial frame is `.zero`; SwiftUI assigns the real frame via
        // layout. Default font (`nil`) lets SwiftTerm pick its bundled
        // monospaced face, which renders consistently on retina and
        // non-retina displays.
        let view = PlatformTerminalView(frame: .zero, font: nil)
        return view
    }

    func updateNSView(_ nsView: PlatformTerminalView, context: Context) {
        // Scaffold: no per-update propagation yet. Subsequent change
        // wires the byte-pump consumer (the SSHSession's output
        // handler), the keystroke forwarder, and the resize handler
        // through `context.coordinator`.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
}

#else

extension PulseTerminalAdapter: UIViewRepresentable {

    typealias UIViewType = PlatformTerminalView

    func makeUIView(context: Context) -> PlatformTerminalView {
        let view = PlatformTerminalView(frame: .zero, font: nil)
        return view
    }

    func updateUIView(_ uiView: PlatformTerminalView, context: Context) {
        // Scaffold: no per-update propagation yet. See macOS path.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
}

#endif

// MARK: - Coordinator

extension PulseTerminalAdapter {

    /// Owns the `TerminalDelegate` conformance. Subsequent change adds
    /// the keystroke forwarder closure (`sendHandler`) and the resize
    /// forwarder closure (`resizeHandler`); the scaffold here is the
    /// empty class so the SwiftUI representable shape compiles and the
    /// SwiftTerm SPM resolution is verified by the build.
    final class Coordinator {
        init() {}
    }
}
