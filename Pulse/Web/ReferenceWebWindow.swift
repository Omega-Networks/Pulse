//
//  ReferenceWebWindow.swift
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

import SwiftUI

/// Window-routing value for one reference page.
///
/// A distinct type from `DeviceWebWindowTarget`. Two `WindowGroup(for:)`
/// scenes that share a Swift type collide (ADR 0001 section 9). `Codable`
/// is what SwiftUI persists for state restoration.
struct ReferenceWebWindowTarget: Hashable, Codable {
    let url: URL
}

#if os(macOS)
/// Reference pages opened from a problem description. macOS only.
/// iOS presents `ReferenceWebView` as a sheet from the problems list.
struct ReferenceWebScene: Scene {
    var body: some Scene {
        WindowGroup("Reference", id: "reference-web", for: ReferenceWebWindowTarget.self) { $target in
            if let target {
                ReferenceWebView(url: target.url)
            } else {
                Text("No page selected.")
                    .padding()
            }
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
#endif
