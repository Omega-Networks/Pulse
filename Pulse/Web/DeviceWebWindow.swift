//
//  DeviceWebWindow.swift
//  Pulse
//
//  Copyright © 2025-present Omega Networks Limited.
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

import SwiftData
import SwiftUI

/// Window-routing value type for the per-device Device Web scene.
///
/// Distinct from the SSH terminal's `DeviceWindowTarget` on purpose, even
/// though both wrap a `Device.ID`. SwiftUI's `WindowGroup(for:)` keys on the
/// Swift type, not the `id:` string (ADR 0001 §9), so
/// two scenes registered `for:` the *same* type collide: `openWindow` can
/// match the wrong group by registration order, and SwiftUI can mount a
/// second content-view instance for a single open. A second `SSHTerminalView`
/// instance has its own fresh auto-fire `@State`, defeating the per-instance
/// `didAttemptAutoFire` guard and reintroducing the first-connect "child
/// channel inactive" race. One distinct nominal type per id-addressed scene
/// keeps every `WindowGroup(for:)` registration unambiguous.
///
/// `Codable` is load-bearing: SwiftUI persists the value for state
/// restoration, so dropping the conformance would silently fail to restore
/// Device Web windows.
struct DeviceWebWindowTarget: Hashable, Codable {
    let deviceID: Int64
}

/// Operator-facing Device Web window, routed per `DeviceWebWindowTarget`.
/// Mirrors `SSHTerminalScene` but keys on its own nominal type rather than
/// sharing the SSH terminal's `DeviceWindowTarget`: two `WindowGroup(for:)`
/// registrations of the same Swift type collide and can mount the view
/// twice (see `DeviceWebWindowTarget` and ADR 0001 §9). Keying on the raw
/// `Device.ID` would collide with the SSH terminal and Site View scenes the
/// same way. The `id: "device-web"` string is retained as the
/// state-restoration anchor and as a guard against a future `Int64`-keyed
/// scene. See `DeviceWindowTarget` / `SSHTerminalScene` for the routing
/// lineage.
struct DeviceWebScene: Scene {

    let modelContainer: ModelContainer

    @ViewBuilder
    private func sceneContent(for target: DeviceWebWindowTarget?) -> some View {
        if let target {
            DeviceWebView(deviceID: target.deviceID)
                .modelContainer(modelContainer)
        } else {
            // SwiftUI can instantiate the scene with a nil value during
            // restoration. Show a placeholder rather than crashing.
            Text("No device selected.")
                .padding()
        }
    }

    #if os(macOS)
    var body: some Scene {
        WindowGroup("Device Web", id: "device-web", for: DeviceWebWindowTarget.self) { $target in
            sceneContent(for: target)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
    #else
    var body: some Scene {
        WindowGroup("Device Web", id: "device-web", for: DeviceWebWindowTarget.self) { $target in
            sceneContent(for: target)
        }
    }
    #endif
}
