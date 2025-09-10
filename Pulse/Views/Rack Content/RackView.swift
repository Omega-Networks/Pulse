//
//  RackView.swift
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
#if os (macOS)
import AppKit
#endif

//Global corner radius
let rackCornerRadius: CGFloat = 8
let rackUnitCornerRadius: CGFloat = 5

struct RackView: View {
    var site: Site
    let unitHeight: CGFloat = 25// Fixed height for each rack unit
    
    @State private var staticDevices: [StaticDevice] = []
    @State private var deviceBays: [DeviceBay] = []
    
    @State private var isLoadingStaticDevices = false
    @State private var isLoadingDeviceBays = false
    @State private var dataLoaded = false
    
    var body: some View {
        #if os(iOS)
        iOSRackLayout
        #else
        macOSRackLayout
        #endif
    }
    
//    MARK: - Functions for MacOS, iOS specific views
    
    // iOS-specific layout
    private var iOSRackLayout: some View {
        GeometryReader { geometry in
            ScrollView {
                if dataLoaded {
                    LazyVStack(spacing: 20) {
                        ForEach(site.racks ?? []) { rack in
                            if rack.status != "deprecated" {
                                SingleRackView(
                                    site: site,
                                    rack: rack,
                                    staticDevices: $staticDevices,
                                    unitHeight: unitHeight,
                                    maxWidth: min(geometry.size.width * 0.9, 400) // Limit max width for larger devices
                                )
                                .frame(maxWidth: .infinity) // Center the rack
                            }
                        }
                    }
                    .padding()
                } else {
                    loadingView
                }
            }
            .task {
                await loadCachedStaticDevices()
                // Load device bays for all shelf devices
                await loadDeviceBaysForShelves()
                dataLoaded = true
            }
        }
    }
    
    // macOS-specific layout
    private var macOSRackLayout: some View {
        GeometryReader { geometry in
            ScrollView {
                if dataLoaded {
                    LazyVGrid(columns: [
                        GridItem(.flexible())  // Changed to single column
                    ], spacing: 20) {
                        ForEach(site.racks ?? []) { rack in
                            if rack.status != "deprecated" {
                                SingleRackView(
                                    site: site,
                                    rack: rack,
                                    staticDevices: $staticDevices,
                                    unitHeight: unitHeight,
                                    maxWidth: min(geometry.size.width - 40, 400) // Account for padding
                                )
                            }
                        }
                    }
                    .padding()
                } else {
                    loadingView
                }
            }
        }
        .task {
            await loadCachedStaticDevices()
            // Load device bays for all shelf devices
            await loadDeviceBaysForShelves()
            dataLoaded = true
        }
    }
    
    // Shared loading view
    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
    }
    
    // MARK: - Functions for fetching static devices and device bays
    
    private func loadCachedStaticDevices() async {
        staticDevices = await StaticDeviceCache.shared.getStaticDevices(forSiteId: site.id)
    }
    
    private func loadDeviceBaysForShelves() async {
        let shelfDevices = staticDevices.filter { $0.deviceRole == "Shelf" }
        for shelf in shelfDevices {
            let bays = await DeviceBayCache.shared.getDeviceBays(forDeviceId: shelf.id)
            deviceBays.append(contentsOf: bays)
        }
    }
}

//TODO: Enable rack view to leverage aspect ratio to enable viewing from different screen sizes
struct SingleRackView: View {
    var site: Site
    let rack: Rack
    @Binding var staticDevices: [StaticDevice]
    let unitHeight: CGFloat
    let maxWidth: CGFloat
    
    @State private var rackUnits: [RackUnit] = []
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var hoveredUnit: Int? = nil
    @State private var showDeviceBuilderSheet: Bool = false
    @State private var isHovering: Bool = false
    
    private let aspectRatioWithEars: CGFloat = 10.71
    private let aspectRatioWithoutEars: CGFloat = 10.33
    private let extraWidthFactor: CGFloat = 1.3 // Increase width by 10%
    
    private var rackWidth: CGFloat {
        unitHeight * aspectRatioWithoutEars * extraWidthFactor
    }
    
    private var totalRackWidth: CGFloat {
        unitHeight * aspectRatioWithEars // This includes the ears
    }
    
    private var totalRackHeight: CGFloat {
        unitHeight * CGFloat(rackUnits.count)
    }
    
    struct RackUnit: Identifiable {
        let id = UUID()
        let index: Int
        var device: Device?
        var staticDevice: StaticDevice?
        var isStartingUnit: Bool = false
    }
    
    init(site: Site, rack: Rack, staticDevices: Binding<[StaticDevice]>, unitHeight: CGFloat, maxWidth: CGFloat) {
        self.site = site
        self.rack = rack
        self._staticDevices = staticDevices
        self.unitHeight = unitHeight
        self.maxWidth = maxWidth
        
        // Initialize rackUnits here
        let rackHeight = Int(rack.uHeight ?? 45)
        self._rackUnits = State(initialValue: (0..<rackHeight).map { RackUnit(index: $0, device: nil, staticDevice: nil) })
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Text(rack.name ?? "Unnamed Rack")
                .font(.headline)
                .padding(.bottom, 5)
            
            HStack(spacing: 0) {
                // Rack unit numbers
                VStack(spacing: 0) {
                    ForEach(rackUnits.indices, id: \.self) { index in
                        Text("\(rackUnits.count - index)")
                            .font(.system(size: 12))
                            .frame(height: unitHeight)
                            .foregroundColor(.gray)
                    }
                }
                .frame(width: 20)
                
                // Rack with devices
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(rackUnits.reversed()) { unit in
                            ZStack {
                                if let device = unit.device, unit.isStartingUnit {
                                    DeviceInRackView(device: device, unitHeight: unitHeight * CGFloat(device.deviceType?.uHeight ?? 1), rackWidth: rackWidth)
                                        .zIndex(1)
                                } else if let staticDevice = unit.staticDevice, unit.isStartingUnit {
                                    StaticDeviceInRackView(staticDevice: staticDevice, unitHeight: unitHeight, rackWidth: rackWidth)
                                        .zIndex(1)
                                } else if unit.device == nil && unit.staticDevice == nil {
                                    RackUnitView(unit: unit.index + 1, unitHeight: unitHeight, rackWidth: rackWidth)
                                        .onTapGesture {
                                            showDeviceBuilderSheet = true
                                        }
                                        .zIndex(0)
                                }
                            }
                        }
                    }
                }
                .frame(width: rackWidth, height: totalRackHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: rackCornerRadius)
                        .stroke(Color.gray, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: rackCornerRadius))
            }
        }
        .frame(width: maxWidth)
        .onAppear {
            updateRackUnits()
        }
        .onChange(of: staticDevices) {
            updateRackUnits()
        }
    }
    
    private func updateRackUnits() {
        let rackHeight = Int(rack.uHeight ?? 45)
        var tempRackUnits = (0..<rackHeight).map { RackUnit(index: $0, device: nil, staticDevice: nil) }
        
        // Add regular devices
        for device in rack.devices ?? [] {
            if let position = device.rackPosition, position > 0 && position <= Float(rackHeight) {
                let index = min(max(0, Int(position.rounded()) - 1), rackHeight - 1)
                let uHeight = Int(device.deviceType?.uHeight?.rounded() ?? 1)
                for i in 0..<uHeight {
                    if index + i < rackHeight {
                        tempRackUnits[index + i].device = device
                        if i == 0 {
                            tempRackUnits[index + i].isStartingUnit = true
                        }
                    }
                }
            }
        }
        
        // Add static devices
        for staticDevice in staticDevices {
            if staticDevice.rackName == rack.name,
               let position = staticDevice.rackPosition,
               position > 0 && position <= Float(rackHeight) {
                let index = min(max(0, Int(position.rounded()) - 1), rackHeight - 1)
                tempRackUnits[index].staticDevice = staticDevice
                tempRackUnits[index].isStartingUnit = true
            }
        }
        
        rackUnits = tempRackUnits
    }
}

//#Preview {
//    RackView()
//}
