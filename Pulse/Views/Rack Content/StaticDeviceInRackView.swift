//
//  StaticDeviceInRackView.swift
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
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import SwiftUI
import Foundation

struct FillerInRackView: View {
    var device: Device
    let unitHeight: CGFloat
    let rackWidth: CGFloat

    var body: some View {
        let role = device.deviceRole?.name ?? ""
        if role.localizedCaseInsensitiveContains("patch") {
            PatchPanelView(device: device, unitHeight: unitHeight, rackWidth: rackWidth)
        } else if role.localizedCaseInsensitiveContains("blank") {
            BlankPlateView(unitHeight: unitHeight, rackWidth: rackWidth)
        } else if role.localizedCaseInsensitiveContains("cable") {
            CableManagementView(unitHeight: unitHeight, rackWidth: rackWidth)
        } else if role.localizedCaseInsensitiveContains("shelf") {
            ShelfView(device: device, unitHeight: unitHeight, rackWidth: rackWidth)
        } else {
            BlankPlateView(unitHeight: unitHeight, rackWidth: rackWidth)
        }
    }
}

struct BlankPlateView: View {
    let unitHeight: CGFloat
    let rackWidth: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: rackUnitCornerRadius)
            .fill(.black)
            .frame(width: rackWidth, height: unitHeight)
            .overlay(
                RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                    .stroke(Color.gray, lineWidth: 1)
            )
    }
}

struct CableManagementView: View {
    let unitHeight: CGFloat
    let rackWidth: CGFloat

    private var fingerCount: Int {
        max(8, Int(rackWidth / 18))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .fill(Color(white: 0.08))

            HStack(spacing: 3) {
                ForEach(0..<fingerCount, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(white: 0.22))
                        .frame(width: 6, height: max(6, unitHeight * 0.55))
                }
            }
            .padding(.horizontal, 10)

            HStack {
                RackOmegaMark(height: min(14, unitHeight * 0.55))
                    .padding(.leading, 8)
                Spacer()
            }
        }
        .frame(width: rackWidth, height: unitHeight)
        .overlay(
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .stroke(Color.gray.opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: rackUnitCornerRadius))
    }
}

/// Vector swirl for 1U hardware. The landscape `OmegaLogo` PNG turns into
/// a few dirty pixels at rack scale; `MenuBarSwirl` is the SVG.
struct RackOmegaMark: View {
    var height: CGFloat

    var body: some View {
        Image("MenuBarSwirl")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: height, height: height)
            .foregroundStyle(.white.opacity(0.9))
            .accessibilityHidden(true)
    }
}

extension View {
    func applyCommonModifiers() -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .stroke(Color.gray.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: rackUnitCornerRadius))
    }
}
