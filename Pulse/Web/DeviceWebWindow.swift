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

/// Operator-facing Device Web window, routed per `Device.ID`. Mirrors
/// `SSHTerminalScene`: an explicit `id: "device-web"` disambiguates the
/// `WindowGroup(for: Device.ID.self)` registration from the SSH terminal and
/// Site View scenes, which also key on `Int64`-valued ids (see the
/// routing-disambiguation note in ADR 0001). It converges with the nominal
/// window-target struct when that work lands.
struct DeviceWebScene: Scene {

    let modelContainer: ModelContainer

    @ViewBuilder
    private func sceneContent(for deviceID: Device.ID?) -> some View {
        if let id = deviceID {
            DeviceWebView(deviceID: id)
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
        WindowGroup("Device Web", id: "device-web", for: Device.ID.self) { $deviceID in
            sceneContent(for: deviceID)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
    #else
    var body: some Scene {
        WindowGroup("Device Web", id: "device-web", for: Device.ID.self) { $deviceID in
            sceneContent(for: deviceID)
        }
    }
    #endif
}
