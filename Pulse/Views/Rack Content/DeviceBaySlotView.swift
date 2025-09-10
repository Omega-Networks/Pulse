//
//  DeviceBaySlotView.swift
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

// Individual bay slot view
struct DeviceBaySlotView: View {
    let bay: DeviceBay
    let unitHeight: CGFloat
    let rackWidth: CGFloat
    
    @Environment(\.modelContext) private var modelContext
    @State private var installedDevice: Device?
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if let device = installedDevice {
                DeviceInShelfView(device: device, rackWidth: rackWidth, unitHeight: unitHeight)
            } else {
                // Empty bay view
                ZStack {
                    RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                        .fill(Color.clear)
                        .frame(width: rackWidth - 4, height: unitHeight)
                    
                    VStack(spacing: 2) {
                        Text(bay.label?.capitalized ?? bay.name?.capitalized ?? "")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    .padding(2)
                }
                .frame(width: rackWidth)
                .overlay(
                    RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                        .stroke(Color.gray, lineWidth: 1)
                )
            }
        }
        .task {
            await loadInstalledDevice()
        }
    }
    
    private func loadInstalledDevice() async {
        guard let deviceId = bay.deviceId else {
            isLoading = false
            return
        }
        
        let descriptor = FetchDescriptor<Device>(
            predicate: #Predicate<Device> { device in
                device.id == deviceId
            }
        )
        
        do {
            let devices = try modelContext.fetch(descriptor)
            await MainActor.run {
                installedDevice = devices.first
                isLoading = false
            }
        } catch {
            print("Error fetching device: \(error)")
            await MainActor.run {
                isLoading = false
            }
        }
    }
}

struct DeviceInShelfView: View {
    var device: Device
    let rackWidth: CGFloat
    let unitHeight: CGFloat
    
    var body: some View {
        ZStack {
            // Background with severity color
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .fill(device.severityColor)
                .frame(width: rackWidth - 4, height: unitHeight)
            
            VStack(spacing: 2) {
                // Device name
                Text(device.name ?? "Unnamed Device")
                    .font(.system(size: 11))
                    .foregroundColor(.black)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(2)
        }
        .frame(width: rackWidth)
    }
}
