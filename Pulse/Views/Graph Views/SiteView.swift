//
//  SiteView.swift
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
import Charts
import Foundation

#if os (macOS)
struct SiteView: View {
    //MARK: All properties for SiteView
    @Environment(\.openWindow) var openWindow
    @Environment(\.modelContext) private var modelContext
    
    // Query for the site and its devices
    @SceneStorage("selected-site-id") var storedSiteId: String = ""
    private var siteId: Int64
    @Query var sites: [Site]
    
    // Properties for interaction
    @State private var showLeft = false
    @State private var showRight = false ///Set to true when testing
    @State private var showBottom = false
    @State private var selectedDevice: Device?
    @State private var searchText = ""
    @State private var enableGestures = false
    @State private var labelsEnabled = false
    
    //Property for saving Devices' coordinates
    @State private var saveCoordinates: Bool = false
    @State private var showAlert: Bool = false
    
    //Properties for SiteGraphView's zoom levels
    @State private var scale = 1.0
    private let minScale = 0.1
    private let maxScale = 4.0
    
    @State private var contentWidth: CGFloat = 220 // Default width for left hand pane
    
    //Properties for showing the sheet for configuring Devices
    @State private var showingConfigureDeviceSheet = false
    @State private var newDeviceRole: Int64 = 0
    @State private var newDeviceLocation: CGPoint?
    
    //Properties to alter the laout
    @State var isHorizontalLayout: Bool = true
    
    //Properties for the ItemChart
    @State private var startDate: Date = Calendar.current.date(byAdding: .hour, value: -1, to: Date.now) ?? Date()
    
    // MARK: Initialization body for SiteView
    init(siteId: Int64) {
        self.siteId = siteId
        // Store the new ID when view is initialized
        self.storedSiteId = String(siteId)
        _sites = Query(filter: #Predicate<Site> { $0.id == siteId })
    }
    
    var body: some View {
        VSplitView {
            HSplitView {
                if showLeft {
                    VStack(alignment: .leading) {
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading) {
                                ForEach(sites.first?.devices?.sorted { device1, device2 in
                                    if device1.highestSeverity != device2.highestSeverity {
                                        return device1.highestSeverity > device2.highestSeverity
                                    }
                                    return (device1.name ?? "") < (device2.name ?? "")
                                } ?? [], id: \.self.id) { device in
                                    DeviceRow(deviceId: device.id, selectedDevice: $selectedDevice)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 10)
                    .frame(minWidth: contentWidth, maxWidth: 600)
                    .onPreferenceChange(WidthPreferenceKey.self) { width in
                        // Add padding to the measured width
                        let desiredWidth = width + 50 // Additional padding
                        // Clamp the width between minimum and maximum values
                        Task { @MainActor in
                            contentWidth = min(max(desiredWidth, 220), 400)
                        }
                    }
                }
                
                // MARK: Main
                VStack {
                    if let site = sites.first {
                        ZStack {
                            ScrollView([.horizontal, .vertical]) {
                                SiteGraphView(
                                    siteId: site.id,
                                    selectedDevice: $selectedDevice,
                                    enableGestures: $enableGestures,
                                    isInPopover: false,
                                    labelsEnabled: $labelsEnabled,
                                    saveCoordinates: $saveCoordinates,
                                    isHorizontalLayout: $isHorizontalLayout,
                                    showingConfigureDeviceSheet: $showingConfigureDeviceSheet,
                                    newDeviceRole: $newDeviceRole,
                                    newDeviceLocation: $newDeviceLocation
                                )
                                .frame(width: 5000, height: 5000)
                            }
                        }

                    } else {
                        // Handle the case where site is nil
                        EmptyView()
                    }
                }
                .frame(minWidth: 400, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                
                //MARK: Right
                if showRight {
                    if let site = sites.first {
                        DeviceDetailsPanelView(site: site, selectedDevice: $selectedDevice)
                    }
                }
            }
            .frame(idealWidth: .infinity, maxWidth: .infinity, minHeight: 400, idealHeight: 800, maxHeight: .infinity)
            
            // MARK: Bottom
            if showBottom {
                VStack {
                    if let site = sites.first {
                        EventTable(site: site)
                    }
                }
                .frame(maxWidth: .infinity, idealHeight: 200, maxHeight: .infinity)
            }
        }
        .toolbar(content: toolbarContent)
        .navigationTitle(sites.first?.name ?? "Unknown")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedDevice) {
            showRight = selectedDevice != nil
        }
        .task {
            do {
                let service = SiteDataService(modelContainer: modelContext.container)
                try await service.loadAllSiteData(for: siteId)
            } catch {
                print("Error loading site data: \(error)")
            }
        }
    }
}

// MARK: The toolbar content of SiteView
extension SiteView {
    func updateStartDate(_ date: Date) {
        // Use the date parameter as needed
        startDate = date
    }
    
    @ToolbarContentBuilder
    private func toolbarContent() -> some ToolbarContent {
        
        ToolbarItemGroup (placement: .navigation) {
            /// "Toolbar"
            Button {
                withAnimation {
                    showLeft.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .fontWeight(.medium)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .padding(.all, 5.0)
            
            Spacer()
        }
        
        ToolbarItemGroup (placement: .primaryAction) {
            Button {
                withAnimation {
                    DispatchQueue.main.async {
                        isHorizontalLayout.toggle()
                    }
                }
            } label: {
                ZStack(alignment: .center) {
                    Image(systemName: "align.vertical.center.fill")
                        .fontWeight(.medium)
                        .foregroundStyle(isHorizontalLayout ? Color.primary : Color.clear)
                        .font(.title2)
                        .animation(Animation.smooth.speed(0.69), value: isHorizontalLayout)
                    
                    Image(systemName: "align.horizontal.center.fill")
                        .fontWeight(.medium)
                        .foregroundStyle(isHorizontalLayout ? Color.clear : Color.primary)
                        .font(.title2)
                        .animation(Animation.smooth.speed(0.69), value: isHorizontalLayout)
                }
            }
            .buttonStyle(.plain)
            .padding(.all, 5.0)
            
            Button {
                withAnimation {
                    showBottom.toggle()
                }
            } label: {
                Image(systemName: "menubar.dock.rectangle")
                    .fontWeight(.medium)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .padding(.all, 5.0)
            
            Button {
                labelsEnabled.toggle()
            } label: {
                /// Animated labelsEnabled icon on toggle
                ZStack(alignment: .center) {
                    Image(systemName: "eye.fill")
                        .font(.title2)
                        .foregroundStyle(labelsEnabled ? Color.white : Color.clear)
                        .animation(Animation.easeInOut.speed(0.69), value: labelsEnabled)
                    Image(systemName: "eye.slash.fill")
                        .symbolRenderingMode(.palette)
                        .font(.title2)
                        .foregroundStyle(
                            labelsEnabled ? Color.clear : Color.gray,
                            labelsEnabled ? Color.white : Color.gray
                        )
                        .animation(Animation.bouncy.speed(0.69), value: labelsEnabled)
                }
            }
            
            Button {
                enableGestures.toggle()
                if !enableGestures {
                    Task {
                        try modelContext.save()
                    }
                }
            } label: {
                /// Animated dragEnabled icon on toggle
                ZStack(alignment: .center) {
                    Image(systemName: "hand.draw.fill")
                        .font(.title2)
                        .foregroundStyle(enableGestures ? Color.white : Color.clear)
                        .animation(Animation.easeInOut.speed(0.69), value: enableGestures)
                    Image(systemName: "hand.draw")
                        .symbolRenderingMode(.palette)
                        .font(.title2)
                        .foregroundStyle(
                            enableGestures ? Color.clear : Color.gray,
                            enableGestures ? Color.white : Color.clear
                        )
                        .animation(Animation.bouncy.speed(0.69), value: enableGestures)
                }
            }
            .scaleEffect(0.75)
            .toggleStyle(.switch)
            ///Button for toggling the right hand pane (may not be required
            Button {
                withAnimation {
                    showRight.toggle()
                    if !showRight {
                        selectedDevice = nil
                    }
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .fontWeight(.medium)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .padding(.all, 5.0)
        }
    }
}

#endif

