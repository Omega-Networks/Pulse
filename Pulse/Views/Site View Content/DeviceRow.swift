//
//  DeviceRowView.swift
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

struct DeviceRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    var deviceId: Int64
    @Query var device: [Device]
    @Binding var selectedDevice: Device?
    
    init(deviceId: Int64, selectedDevice: Binding<Device?>) {
        self.deviceId = deviceId
        self._selectedDevice = selectedDevice
        
        _device = Query(filter: #Predicate<Device> { $0.id == deviceId } )
    }
    
    var body: some View {
        HStack {
            ZStack(alignment: .center) {
                Circle()
                    .frame(width: 25, height: 25)
                    .foregroundColor(device.first?.severityColor)
                Image(device.first?.symbolName ?? "", variableValue: 0)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(device.first?.severityColor ?? .clear, Color.black)
                    .font(.system(size: 16, weight: .regular))
            }
            .padding(.leading, 12)
            
            VStack(alignment: .leading) {
                Text(device.first?.name ?? "")
                    .foregroundColor(selectedDevice == device.first ? .white : (colorScheme == .light ? .primary : .primary))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                
                Text(device.first?.deviceRole?.name ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(selectedDevice == device.first ? .white : (colorScheme == .light ? .secondary : .secondary))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 3)
        .background(selectedDevice == device.first ? Color.accentColor : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .measureWidth() // Measure the actual content width
        .onTapGesture {
            selectedDevice = device.first
        }
        .contextMenu {
            Button(action: {
                if let device = device.first {
                    print("Editor for \(device.name ?? "") is a work in progress.")
                }
            }) {
                Label("Edit", systemImage: "pencil")
            }
            
            Button(role: .destructive, action: {
                if let device = device.first {
                    let deviceId = device.id
                    Task.detached(priority: .background) {
                        //TODO: Conform to Swift 6 standards // WHY??
                        await deleteDevice(deviceId)
                    }
                }
            }) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private func getDevice() -> Device? {
        let descriptor = FetchDescriptor<Device>(predicate: #Predicate { $0.id == deviceId })
        return try? modelContext.fetch(descriptor).first
    }
    
    //TODO: Resolve issue with deleting device causing app-wide crash
    private func deleteDevice(_ deviceId: Int64) async {
        do {
            // Fetch the device again to ensure we have a context-associated object
            let descriptor = FetchDescriptor<Device>(predicate: #Predicate<Device> { $0.id == deviceId })
            if let freshDevice = try modelContext.fetch(descriptor).first {
                modelContext.delete(freshDevice)
                try modelContext.save()
                print("Device deleted successfully")
                
                // If the deleted device was the selected device, deselect it
                if selectedDevice?.id == freshDevice.id {
                    selectedDevice = nil
                }
            } else {
                print("Device not found in context, it may have been already deleted")
            }
        } catch {
            print("Failed to delete device: \(error)")
        }
    }
}


