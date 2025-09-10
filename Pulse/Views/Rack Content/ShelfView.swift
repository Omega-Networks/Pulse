//
//  SwiftUIView.swift
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
import SwiftData

struct ShelfView: View {
    let staticDevice: StaticDevice
    let unitHeight: CGFloat
    let rackWidth: CGFloat
    @State private var deviceBays: [DeviceBay] = []
    
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                        .stroke(Color.gray.opacity(0.5), lineWidth: 0.5)
                )
            
            // Device bays container
            HStack(spacing: 2) {
                ForEach(deviceBays) { bay in
                    DeviceBaySlotView(bay: bay, unitHeight: unitHeight, rackWidth: (rackWidth - 4) / CGFloat(max(1, deviceBays.count)))
                }
                // If no bays loaded, show empty shelf
                if deviceBays.isEmpty {
                   EmptyView()
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(width: rackWidth, height: unitHeight)
        .background(Color.gray.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .stroke(Color.black, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: rackUnitCornerRadius))
        .task {
            deviceBays = await DeviceBayCache.shared.getDeviceBays(forDeviceId: staticDevice.id)
        }
    }
}

//#Preview {
//    SwiftUIView()
//}
