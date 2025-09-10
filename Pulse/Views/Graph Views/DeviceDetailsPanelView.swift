//
//  DeviceDetailsPanel.swift
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
import AVKit

struct DeviceDetailsPanelView: View {
    @State var site: Site
    @Binding var selectedDevice: Device? // Changed to @Bindable to allow modifications
    
    // State for controlling the configuration sheet
    @State private var showingCameraConfigSheet = false
    
    var body: some View {
        TabView {
            // deviceInfoSection Tab
            ScrollView(.vertical, showsIndicators: true) {
                if let device = selectedDevice {
                    deviceInfoSection(device)
                    
                } else {
                    Text("Select a device to view details")
                        .padding(.vertical, 10)
                }
            }
            .tabItem {
                Label("Device Details", systemImage: "info.circle")
            }
            .tag("Device Details")
            
            // RackView Tab
            VStack {
                Text("Racks")
                    .font(.title)
                    .fontWeight(.bold)
                
                RackView(site: site)
            }
            .padding(20)
            .tabItem {
                Label("Rack View", systemImage: "square.stack.3d.up")
            }
            .tag("Rack View")
        }
        #if os(macOS)
        .tabViewStyle(.grouped)
        #endif
        .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Helper Views
    
    private func deviceInfoSection(_ device: Device) -> some View {
        VStack(alignment: .leading) {
            
            HStack(alignment: .center) {
                Text("\(device.name ?? "Error")")
                    .font(.title)
                    .fontWeight(.bold)
                
                Spacer()
                
                if device.supportsCameraStream {
                    Button {
                        showingCameraConfigSheet = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.borderless)
                    .font(.headline)
                    .help("Configure Camera Stream URL")
                }
            }
            .padding(.top, 20) // Apply padding to the entire HStack
            
            DeviceUptimeChart(deviceId: device.zabbixId)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .padding(.top, -15)
            
            DeviceFaceplate(deviceId: device.id)
                .padding(.vertical, 40)
            
            switch device.deviceRole?.id {
            case 3: // Security Router
                HStack(alignment: .top) {
                    VStack {
                        ItemChart(deviceId: device.zabbixId, item: "CPU usage")
                        CPUCoresChart(deviceId: device.zabbixId)
                    }
                    
                    ItemChart(deviceId: device.zabbixId, item: "Memory usage")
                }
                .padding(.vertical, 10)
                                
            default:
                Spacer()
            }
            
            #if os(macOS)
            TabView {
                InterfacesTable(device: device)
                    .id(device.id)
                    .tabItem {
                        Label("Interfaces", systemImage: "network")
                    }
                                                
                DeviceChartSelector(deviceId: device.id)
                    .padding()
                    .tabItem {
                        Label("Graphs", systemImage: "chart.line.uptrend.xyaxis")
                    }
            }
            .padding(.top, 10)
            .frame(minHeight: 400, alignment: .top)
            #endif
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
    
    private func cpuMemorySection(_ device: Device) -> some View {
        HStack(alignment: .top) {
            VStack {
                ItemChart(deviceId: device.zabbixId, item: "CPU usage")
                CPUCoresChart(deviceId: device.zabbixId)
            }
            .frame(maxWidth: .infinity)
            
            VStack {
                ItemChart(deviceId: device.zabbixId, item: "Memory usage")
            }
            .frame(maxWidth: .infinity)
        }
    }
}


//#Preview("Device Details Panel View") {
//    @Previewable @Query(filter: #Predicate<Site> { $0.id == 1 }) var sites: [Site]
//    @Previewable @Query(filter: #Predicate<Device> { $0.id == 1 }) var devices: [Device]
//    
//    DeviceDetailsPanelView(
//        site: sites.first ?? Site(id: 1),
//        selectedDevice: .constant(devices.first)
//    )
//    .frame(width: 600, height: 400)
//}
