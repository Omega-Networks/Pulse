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

/// Operator-facing Device Web window, routed per `DeviceWindowTarget`.
/// Mirrors `SSHTerminalScene`: keying the `WindowGroup` on the nominal
/// `DeviceWindowTarget` rather than the raw `Device.ID` (which is `Int64`
/// and collides with `Site.ID`) makes a misrouted `openWindow` a compile
/// error rather than a registration-order accident. Per ADR 0001 §9, all
/// three id-addressed scenes (SSH Terminal, Site View, Device Web) key on
/// nominal target structs; the `id: "device-web"` string is retained as the
/// state-restoration anchor and as a second line of defence against a future
/// `Int64`-keyed scene. See `DeviceWindowTarget` and `SSHTerminalScene` for
/// the full routing rationale.
struct DeviceWebScene: Scene {

    let modelContainer: ModelContainer

    @ViewBuilder
    private func sceneContent(for target: DeviceWindowTarget?) -> some View {
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
        WindowGroup("Device Web", id: "device-web", for: DeviceWindowTarget.self) { $target in
            sceneContent(for: target)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
    #else
    var body: some Scene {
        WindowGroup("Device Web", id: "device-web", for: DeviceWindowTarget.self) { $target in
            sceneContent(for: target)
        }
    }
    #endif
}
