//
//  ContentView.swift
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

import SwiftData
import SwiftUI
import MapKit
import UserNotifications

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    
    // Add transaction control
    private let updateQueue = DispatchQueue(label: "com.pulse.mapupdates")
    @State private var isProcessingUpdates = false
    
    @Environment(\.openWindow) var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \SiteGroup.name, order: .forward) private var siteGroups: [SiteGroup]
    @State var selectedSite: Site?
    @State var selectedSiteGroups: Set<Int64> = []
    
    //Properties for searching through sites
    @State private var searchText = ""
    
    //Property for closing the detail sheet (sheet showing Site information)
    @State var isClearButtonClicked: Bool = false
    
    //Properties for opening popovers
    @State private var isLoading = false
    @State var openSiteGroups = false
    @State var openInvoices = false
    @State var openDeleteButtons = false
    
    //Properties for adjusting the map's camera position
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    //Proprety for changing the map style
    @AppStorage("mapStyle")
    var mapStyle: MapStyle = .standard
    @State var openMapStyles = false

    //Property for PowerSense overlay toggle
    @State var showPowerSenseOverlay = false
    
    //Properties for the iOS version
    @State private var eventMonitoringTimer: Timer?
    @State var zabbixUpdateTimer: Timer?
    @State private var isMonitoringEnabled = false
    
    //Properties for notification handling
    @State private var showingNotificationAlert = false
    let notificationHandler = NotificationHandler()
    
    @Query var syncProvider: [SyncProvider]
    
    @State var isEventMonitoringEnabled: Bool = false
    
    @StateObject var tipManager = TipManager.shared
    
    //iOS specific properties for sheet management
#if os (iOS)
    @State private var mainSheetOpen: Bool = true
    @State private var isMapSheetPresented = false
#endif
    
    var body: some View {
        Group {
            ///MacOS views
#if os(macOS)
            NavigationSplitView {
                VStack {
                    SearchBar(text: $searchText)
                        .padding(.horizontal, 20)
                    
                    //New subview for showing list of sites
                    SitesList(searchText: searchText, selectedSiteGroups: selectedSiteGroups, cameraPosition: $cameraPosition, selectedSite: $selectedSite)
                }
            } detail: {
                MapView(
                    cameraPosition: $cameraPosition,
                    mapStyle: $mapStyle,
                    selectedSite: $selectedSite,
                    selectedSiteGroups: selectedSiteGroups,
                    showPowerSenseOverlay: $showPowerSenseOverlay
                )
            }
#elseif os (iOS)
            /// iOS views
            VStack {
                MapView(
                    cameraPosition: $cameraPosition,
                    mapStyle: $mapStyle,
                    selectedSite: $selectedSite,
                    selectedSiteGroups: selectedSiteGroups,
                    openSiteGroups: $openSiteGroups,
                    isMapSheetPresented: $isMapSheetPresented,
                    showPowerSenseOverlay: $showPowerSenseOverlay
                )
            }
            .sheet(isPresented: $mainSheetOpen) { //Main sheet containing list of sites and search bar
                MainSheet(searchText: $searchText, selectedSiteGroups: selectedSiteGroups, cameraPosition: $cameraPosition, selectedSite: $selectedSite)
                    .sheet(item: $selectedSite) { site in
                        DetailSheet(selectedSite: $selectedSite)
                    }
                    .sheet(isPresented: $isMapSheetPresented) {
                        MapStyleSheet(mapStyle: $mapStyle)
                            .presentationDetents([.medium])
                    }
                    .interactiveDismissDisabled()
                    .presentationDetents([.height(50), .height(200), .medium, .large])
                    .presentationBackgroundInteraction(
                        .enabled(upThrough: .medium)
                    )
            }
#endif
        }
        .alert(isPresented: $showingNotificationAlert) {
            Alert(
                title: Text("Notifications Disabled"),
                message: Text("Please enable notifications for Pulse in your system settings to receive important updates."),
                dismissButton: .default(Text("OK"))
            )
        }
#if os(macOS)
        .toolbar(content: toolbarContent)
#endif
        .task {
            ///Delay push notification by 30 seconds to allow CloudKit to sync with Pulse
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                startMonitoringZabbixUpdates()
            }
            
            if isEventMonitoringEnabled {
                Task.detached(priority: .background) {
                    await updateEventMonitoring()
                }
            }
            
            // Check SyncProvider count and create if needed
            if syncProvider.isEmpty {
                let newSyncProvider = SyncProvider(
                    lastNetBoxUpdate: .now,
                    lastZabbixUpdate: .now
                )
                modelContext.insert(newSyncProvider)
                try? modelContext.save()
            }
            
            //Adjust camera position to centre of whatever is defined
            cameraPosition = .camera(MapCamera(
                centerCoordinate: .centerCoordinate,
                distance: 2_000_000,  // Increased from 10000 to 1,000,000 meters
                heading: 0,
                pitch: 0
            ))
            
            //If notification permissions are disabled, send an alert to user to enable it
            Task {
                let authorized = await notificationHandler.checkNotificationAuthorization()
                if !authorized {
                    await MainActor.run {
                        showingNotificationAlert = true
                    }
                }
            }
        }
        .onChange(of: scenePhase) { ///Clears notification badge
            if scenePhase == .active {
                Task {
                    await NotificationHandler.instance.resetBadgeCount()
                }
            }
        }
    }
    
    func deleteEvents() {
        Task { @MainActor in
            do {
                // 1. Fetch all events using existing modelContext
                let fetchDescriptor = FetchDescriptor<Event>()
                let events = try modelContext.fetch(fetchDescriptor)
                
                // 2. Track affected devices
                var affectedDevices = Set<Device>()
                
                // 3. Collect affected devices and delete events
                for event in events {
                    if let device = event.device {
                        affectedDevices.insert(device)
                    }
                    modelContext.delete(event)
                }
                
                // 4. Save changes
                try modelContext.save()
                
                // 5. Close the popover
                openDeleteButtons = false
                
            } catch {
                print("Failed to delete events: \(error)")
            }
        }
    }
    
    func updateEventMonitoring() async {
        // Cancel existing timer
        self.eventMonitoringTimer?.invalidate()
        self.eventMonitoringTimer = nil

        guard isEventMonitoringEnabled else { return }

        // Store container reference
        let container = modelContext.container
        
        Task.detached(priority: .userInitiated) {
            let service = SiteDataService(modelContainer: container)
            await service.getProblems()
        }
        
        // Timer without transaction wrapping
        await MainActor.run {
            self.eventMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
                Task.detached(priority: .utility) {
                    let service = SiteDataService(modelContainer: container)
                    await service.getProblems()
                }
            }
        }
    }
}
