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

/// Scene wrapper for the operator-facing SSH terminal. On macOS this
/// exposes a per-`Device.ID` `WindowGroup`; SwiftUI's per-value
/// `WindowGroup` semantics activate an existing window when the
/// operator triggers `openWindow(id: "ssh-terminal", value: device.id)`
/// for a device that already has a terminal open, which is the desired
/// single-terminal-per-device behaviour.
///
/// **Why the `id: "ssh-terminal"` argument.** `Device.ID` and `Site.ID`
/// both resolve to `Int64` (the default `Identifiable.ID` for the two
/// `@Model` classes whose `id: Int64`). SwiftUI's `WindowGroup(for:)`
/// keys on the Swift type, not the textual declaration, so two
/// `WindowGroup(for: Int64.self)` registrations collide and
/// `openWindow(value: device.id)` matches by registration order rather
/// than by intent. The explicit `id:` argument disambiguates the
/// routing per the SwiftUI contract: `openWindow(id:value:)` targets
/// exactly the named scene regardless of value-type collisions. The
/// Site View scene carries a matching `id: "site-view"` for the same
/// reason; both call sites pass the matching `id:`. A future slice may
/// wrap the two ids in distinct nominal struct types
/// (`DeviceWindowTarget`, `SiteWindowTarget`) so the disambiguation
/// becomes a compile error rather than a string-id discipline gate.
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

    var body: some Scene {
        // The scene shape is identical on macOS and iOS; the platform
        // difference is whether anything currently routes into it. On
        // iOS the device-row gesture that calls
        // `openWindow(id:value:)` arrives in a future slice; the scene
        // registration itself is platform-agnostic.
        WindowGroup("SSH Terminal", id: "ssh-terminal", for: Device.ID.self) { $deviceID in
            if let id = deviceID {
                SSHTerminalView(connection: .device(id))
                    .modelContainer(modelContainer)
            } else {
                // SwiftUI can instantiate the scene with a nil value
                // during restoration. Show an empty placeholder rather
                // than crashing on a missing identity.
                Text("No device selected.")
                    .padding()
            }
        }
    }
}
