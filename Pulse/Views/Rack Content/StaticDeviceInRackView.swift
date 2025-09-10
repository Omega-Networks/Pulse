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

struct StaticDeviceInRackView: View {
    var staticDevice: StaticDevice
    let unitHeight: CGFloat
    let rackWidth: CGFloat
    
    var body: some View {
        switch staticDevice.deviceRole {
        case "Patch Panel":
            PatchPanelView(staticDevice: staticDevice, unitHeight: unitHeight, rackWidth: rackWidth)
        case "Blank Plate":
            BlankPlateView(unitHeight: unitHeight, rackWidth: rackWidth)
        case "Cable Management":
            CableManagementView(unitHeight: unitHeight, rackWidth: rackWidth)
        case "Shelf":
            ShelfView(staticDevice: staticDevice, unitHeight: unitHeight, rackWidth: rackWidth)
        default:
            EmptyView()
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
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .fill(Color.clear)
            .applyCommonModifiers()
            
            HStack(alignment: .center) {
                Image("OmegaLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 10)
                    .padding(.leading, 10)
                Spacer()
            }
            .frame(width: rackWidth - 25, height: unitHeight)
            .background(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                    .stroke(Color.gray, lineWidth: 1)
            )
        }
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
