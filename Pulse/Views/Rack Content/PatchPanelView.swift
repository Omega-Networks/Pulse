//
//  PatchPanelView.swift
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

struct PatchPanelView: View {
    let staticDevice: StaticDevice
    let unitHeight: CGFloat
    let rackWidth: CGFloat
    
    
    private let portsPerRow: Int64 = 24
    private let portsPerGroup: Int64 = 6
    private let groupSpacing: CGFloat = 6
    private let portSpacing: CGFloat = 1
    private let sidePadding: CGFloat = 5 // Add padding on each side
    
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<Int(rowCount), id: \.self) { rowIndex in
                HStack(spacing: 0) {
                    Spacer().frame(width: sidePadding) // Left padding
                    ForEach(0..<Int(groupsPerRow), id: \.self) { groupIndex in
                        HStack(spacing: portSpacing) {
                            ForEach(0..<Int(portsInGroup(row: Int64(rowIndex), group: Int64(groupIndex))), id: \.self) { portIndex in
                                let portNumber = Int64(rowIndex) * portsPerRow + Int64(groupIndex) * portsPerGroup + Int64(portIndex) + 1
                                PortView(portNumber: portNumber)
                            }
                        }
                        if groupIndex < Int(groupsPerRow) - 1 {
                            Spacer().frame(width: groupSpacing)
                        }
                    }
                    Spacer().frame(width: sidePadding) // Right padding
                }
            }
        }
        .frame(width: rackWidth, height: unitHeight)
        .background(Color.gray.opacity(0.2))
        .overlay(
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .stroke(Color.gray, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: rackUnitCornerRadius))
    }
    
    private var rowCount: Int64 {
        (staticDevice.frontPortCount ?? 0 + portsPerRow - 1) / portsPerRow
    }
    
    private var groupsPerRow: Int64 {
        portsPerRow / portsPerGroup
    }
    
    private func portsInGroup(row: Int64, group: Int64) -> Int64 {
        let startPort = row * portsPerRow + group * portsPerGroup
        let remainingPorts = (staticDevice.frontPortCount ?? 0) - startPort
        return min(portsPerGroup, remainingPorts)
    }
}

//MARK: Subview showing physical port and number

struct PortView: View {
    let portNumber: Int64
    
    private let portSize: CGFloat = 8
    private let portColour: Color = Color(red: 99/255, green: 99/255, blue: 99/255)
    
    var body: some View {
        VStack(spacing: 1) {
            Text("\(portNumber)")
                .font(.system(size: 5))
                .frame(width: portSize + 2) // Slightly wider than the port for better alignment
            
            ZStack {
                Rectangle()
                    .fill(portColour)
                Rectangle()
                    .stroke(Color.black, lineWidth: 0.5) // Reduced line width
            }
            .frame(width: portSize, height: portSize)
        }
    }
}
