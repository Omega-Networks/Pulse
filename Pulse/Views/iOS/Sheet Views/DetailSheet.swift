//
//  DetailSheet.swift
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

import Foundation
import SwiftUI
import SwiftData
import MapKit

#if os (iOS)
/**
 This SwiftUI view presents detailed information about a selected site, including its name, group, and a list of devices with their respective events. It's designed to be presented as a sheet, with functionality to refresh the content and dismiss the view dynamically.
 
 - Requires:
 
 - Important: This view relies on the presence of a selected site within the `ViewModel`. If no site is selected, default placeholder text is displayed.
 
 - Note: Real-time updates and additional features such as a graph view for the site are planned but not yet implemented.
 
 - TODO: Implement real-time updates to ensure the view reflects the latest data without needing manual refreshes.
 - TODO: Integrate a `SiteGraphView` to visually represent data related to the selected site.
 */
struct DetailSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showSiteGraph: Bool = false
    let site: Site
    @State private var selectedTab = 0
    @State private var rackEdit = RackEditSession()
    
    var body: some View {
        VStack {
            //Site name, site group name
            HStack {
                VStack(alignment: .leading) {
                    Text(site.name)
                        .font(.title)
                        .fontWeight(.bold)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text(site.group?.name ?? "No Group")
                        .font(.caption)
                }
                Spacer()
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill") // Styling the button with a system image.
                        .imageScale(.medium)
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
            
            List {
                Button {
                    self.showSiteGraph = true
                } label : {
                    Label("Open Topology View", systemImage: "network")
                        .labelStyle(.titleAndIcon)
                }
                .fullScreenCover(isPresented: $showSiteGraph) { //MARK: Full screen cover showing the site topology
                    NavigationStack {
                            TabView(selection: $selectedTab) {
                                // Topology View Tab
                                SiteGraphView(
                                    site: site,
                                    selectedDevice: .constant(nil),
                                    enableGestures: .constant(true),
                                    isInPopover: false,
                                    labelsEnabled: .constant(false),
                                    saveCoordinates: .constant(false),
                                    isHorizontalLayout: .constant(true)
                                )
                                .tag(0)
                                .tabItem {
                                    Label("Topology", systemImage: "network")
                                }
                                
                                // Rack View Tab
                                RackView(site: site)
                                    .tag(1)
                                    .tabItem {
                                        Label("Racks", systemImage: "square.stack.3d.up")
                                    }
                            }
                            .toolbar {
                                ToolbarItemGroup(placement: .principal) {
                                    VStack(alignment: .center) {
                                        Text(site.name)
                                            .font(.headline)
                                            .fontWeight(.bold)
                                            .fixedSize(horizontal: false, vertical: true)
                                        
                                        Text(site.group?.name ?? "No Group")
                                            .font(.caption)
                                    }
                                }
                                
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button {
                                        DispatchQueue.main.async {
                                            self.showSiteGraph = false
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .imageScale(.medium)
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                            .toolbarBackground(.hidden, for: .navigationBar)
                    }
                }
                
                Section (header: Text("Details")) {
                    VStack (alignment: .leading) {
                        Text("Address")
                            .font(.headline)
                        Text(site.physicalAddress ?? "No address")
                            .font(.caption)
                        
                        Divider()
                        
                        Text("Devices")
                            .font(.headline)
                        Text("\(site.devices?.count ?? 0)")
                            .font(.caption)
                    }
                }
                
            }
        }
        .environment(rackEdit)
        .task {
            do {
                let service = SiteDataService(modelContainer: modelContext.container)
                try await service.loadAllSiteData(for: site.id)
            } catch {
                print("Error loading site data: \(error)")
            }
        }
    }
}
#endif
