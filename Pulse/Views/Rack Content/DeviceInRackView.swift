//
//  DeviceInRackView.swift
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

struct DeviceInRackView: View {
    var device: Device
    let unitHeight: CGFloat
    let rackWidth: CGFloat
    
    var body: some View {
        ZStack {
            // Outer clear rectangle with gray stroke
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                        .stroke(Color.gray.opacity(0.5), lineWidth: 0.5)
                )
            
            // Colored severity rectangle
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .fill(device.severityColor)
                .frame(width: rackWidth - 25, height: unitHeight)
            
            // Device name
            Text(device.name ?? "Unnamed Device")
                .font(.system(size: 14))
                .foregroundColor(.black)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: rackWidth, height: unitHeight)
        .applyCommonModifiers()
    }
}
