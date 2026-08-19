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
                Image("OmegaLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: min(28, rackWidth * 0.12), height: min(10, unitHeight * 0.4))
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

extension View {
    func applyCommonModifiers() -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .stroke(Color.gray.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: rackUnitCornerRadius))
    }
}
