//
//  SSHTerminalWindow.swift
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
import SwiftData

/// Window-routing value type for the per-device SSH terminal scene.
///
/// `Device.ID` and `Site.ID` both resolve to `Int64` (the default
/// `Identifiable.ID` for the two `@Model` classes whose `id: Int64`), so
/// a bare `WindowGroup(for: Int64.self)` cannot tell a device-targeted
/// window open from a site-targeted one. Wrapping each id in a distinct
/// nominal type makes the two `WindowGroup` value types unambiguous: an
/// `openWindow` aimed at the wrong scene is a compile error, not a
/// routing-order accident.
///
/// `Codable` is load-bearing. SwiftUI persists the window's value for
/// state restoration, so the conformance must stay explicit; if it is
/// ever dropped, restored windows silently fail to decode.
///
/// The targets store the model's `Int64` NetBox id directly rather than
/// the `Identifiable` associated type: `Site` is not explicitly
/// `Identifiable`, so `Site.ID` is not usable as a stored-property type,
/// and the `Int64` is exactly the value the `openWindow` call sites
/// already hold.
struct DeviceWindowTarget: Hashable, Codable {
    let deviceID: Int64
}

/// Window-routing value type for the per-site Site View scene. See
/// `DeviceWindowTarget` for why the id is wrapped in a nominal type.
struct SiteWindowTarget: Hashable, Codable {
    let siteID: Int64
}

/// Scene wrapper for the operator-facing SSH terminal. On macOS this
/// exposes a per-`DeviceWindowTarget` `WindowGroup`; SwiftUI's per-value
/// `WindowGroup` semantics activate an existing window when the operator
/// triggers `openWindow(id: "ssh-terminal", value: DeviceWindowTarget(deviceID: device.id))`
/// for a device that already has a terminal open, which is the desired
/// single-terminal-per-device behaviour.
///
/// **Why a nominal value type.** `Device.ID` and `Site.ID`
/// both resolve to `Int64` (the default `Identifiable.ID` for the two
/// `@Model` classes whose `id: Int64`), so two
/// `WindowGroup(for: Int64.self)` registrations would collide and a bare
/// `openWindow(value: someInt64)` would match by registration order
/// rather than by intent. The runtime routing is disambiguated by an
/// explicit `id:` string per scene; keying each scene on a distinct
/// nominal type (`DeviceWindowTarget` here, `SiteWindowTarget` for Site
/// View) makes the value type itself select the scene, so a
/// `DeviceWindowTarget` cannot land in the Site View scene by accident.
/// The `id:` strings are retained as state-restoration anchors
/// and as a guard against a future `Int64`-keyed scene; every call site
/// passes the matching `id:` and wraps its id in the matching target.
/// See ADR 0001 §9 (window model) for the routing rationale.
///
/// On iOS the same view is buildable but no scene registers it here;
/// iOS routing from a device row to the terminal is the concern of
/// the future iOS surface and is not in scope for this slice.
///
/// The wrapper is a `Scene`-producing type rather than a struct
/// embedded directly in `PulseApp` so the routing intent is legible
/// and so the `WindowGroup`'s `ModelContainer` injection lives next
/// to its `for:` keypath, not buried inside the main app file.
struct SSHTerminalScene: Scene {

    let modelContainer: ModelContainer
    var entitlements: EntitlementStore
    var seats: LicenseSeatStore
    var roles: RolePresentationStore

    /// Scene-body content closure, factored out so the `#if os(macOS)`
    /// branches below stay focused on the modifier chain and the body
    /// itself is declared once.
    @ViewBuilder
    private func sceneContent(for target: DeviceWindowTarget?) -> some View {
        if let target {
            SSHTerminalView(connection: .device(target.deviceID))
                .modelContainer(modelContainer)
                .pulseBilling(entitlements: entitlements, seats: seats, roles: roles)
        } else {
            // SwiftUI can instantiate the scene with a nil value
            // during restoration. Show an empty placeholder rather
            // than crashing on a missing identity.
            Text("No device selected.")
                .padding()
        }
    }

    #if os(macOS)
    var body: some Scene {
        // Terminal-shaped window chrome. Two macOS-only modifiers
        // chained on the WindowGroup:
        //
        // - `.windowResizability(.contentSize)` makes the
        //   `SSHTerminalView`'s existing `.frame(minWidth: 720,
        //   minHeight: 420)` the window's enforced minimum. The
        //   720x420 floor is deliberately oversized vs the 80x24 cell
        //   grid (which is closer to 580x360 at the default font
        //   size); the surplus gives the recording-state toolbar item
        //   room to render without the title eliding.
        //
        // - `.windowToolbarStyle(.unified(showsTitle: true))` renders
        //   the title alongside toolbar items in a single bar. The
        //   `.unifiedCompact` variant was used initially but produced
        //   a click-to-update regression where server output did not
        //   repaint until the operator clicked in the window (the
        //   debug surface, which carries no `.windowToolbarStyle`,
        //   did not exhibit the symptom — strong evidence the compact
        //   style was interfering with SwiftTerm's `setNeedsDisplay`
        //   propagation). The full-size unified style preserves the
        //   inline-title chrome at slightly taller height without
        //   the rendering issue. The render-path diagnostic loggers
        //   in `PulseTerminalAdapter` (category `ssh.render`) remain
        //   in place to catch any future recurrence under this or a
        //   different chrome style.
        //
        // The iOS scene wiring (future slice) inherits the same
        // `.toolbar` declaration on the view body and renders it via
        // the platform-default toolbar surface.
        WindowGroup("SSH Terminal", id: "ssh-terminal", for: DeviceWindowTarget.self) { $target in
            sceneContent(for: target)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
    #else
    var body: some Scene {
        WindowGroup("SSH Terminal", id: "ssh-terminal", for: DeviceWindowTarget.self) { $target in
            sceneContent(for: target)
        }
    }
    #endif
}
