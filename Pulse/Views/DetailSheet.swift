//
//  DetailSheet.swift
//  Pulse
//
//  Created by Matt Lawrence Romanes (Omega Networks) on 20/02/24.
//

import Foundation
import SwiftUI
import SwiftData
import MapKit

#if os (iOS)
/**
 This SwiftUI view presents detailed information about a selected site, including its name, group, and a list of devices with their respective problems. It's designed to be presented as a sheet, with functionality to refresh the content and dismiss the view dynamically.
 
 - Requires:
 
 - Important: This view relies on the presence of a selected site within the `ViewModel`. If no site is selected, default placeholder text is displayed.
 
 - Note: Real-time updates and additional features such as a graph view for the site are planned but not yet implemented.
 
 - TODO: Implement real-time updates to ensure the view reflects the latest data without needing manual refreshes.
 - TODO: Integrate a `SiteGraphView` to visually represent data related to the selected site.
 */
struct DetailSheet: View {
    @State private var showSiteGraph: Bool = false
    @Binding var selectedSite: Site?
    
    var body: some View {
        VStack {
            //Site name, site group name
            HStack {
                VStack(alignment: .leading) {
                    Text(selectedSite?.name ?? "Unknown")
                        .font(.title)
                        .fontWeight(.bold)
                        .fixedSize(horizontal: false, vertical: true) // Allow the name to wrap.
                    
                    Text(selectedSite?.group?.name ?? "No Group")
                        .font(.caption)
                }
                Spacer() // Pushes content to the left and button to the right.
                Button(action: {
                    // Action to close the sheet or perform relevant action
                    selectedSite = nil // Example action to deselect site and close sheet.
                }) {
                    Image(systemName: "xmark.circle.fill") // Styling the button with a system image.
                        .imageScale(.medium)
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
            
            List {
//                Section (header: Text("Topology")) {
                    //TODO: "Solve view origin is invalid" error
                    //                    if let site = selectedSite {
                    //                        SiteGraphView(site: site, selectedDevice: .constant(nil), enableGestures: .constant(false), isInPopover: true, labelsEnabled: .constant(false), saveCoordinates: .constant(false), isHorizontalLayout: .constant(true))
                    //                            .frame(width: 300, height: 300)
                    
                    //TODO: Replace Text view with Button and Label views
                    //                        Text("Open topology view")
                    //                            .font(.caption)
                    //                            .onTapGesture {
                    //                                self.showSiteGraph = true
                    //                            }
                    
                    /// Termporary substitute view while resolving issues with using original view
                    Button {
                        self.showSiteGraph = true
                    } label : {
                        Label("Open Topology View", systemImage: "network")
                            .labelStyle(.titleAndIcon)
                    }
                    .fullScreenCover(isPresented: $showSiteGraph) { //MARK: Full screen cover showing the site topology
                        if let site = selectedSite {
                            NavigationStack {
                                ZStack {
                                    //TODO: Re-introduce touch gestures for iOS, iPadOS
                                    SiteGraphView(site: site, selectedDevice: .constant(nil), enableGestures: .constant(true), isInPopover: false, labelsEnabled: .constant(false), saveCoordinates: .constant(false), isHorizontalLayout: .constant(true))
                                        .toolbar {
                                            //TODO: Add in the centre of the toolbar
                                            ToolbarItemGroup(placement: .principal) {
                                                VStack (alignment: .center) {
                                                    Text(selectedSite?.name ?? "Unknown")
                                                        .font(.headline)
                                                        .fontWeight(.bold)
                                                        .fixedSize(horizontal: false, vertical: true) // Allow the name to wrap.
                                                    
                                                    Text(selectedSite?.group?.name ?? "No Group")
                                                        .font(.caption)
                                                }
                                            }
                                            
                                            ToolbarItem(placement: .navigationBarTrailing) {
                                                Button {
                                                    self.showSiteGraph = false // This will dismiss the fullScreenCover
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill") // Styling the button with a system image.
                                                        .imageScale(.medium)
                                                        .foregroundColor(.primary)
                                                }
                                            }
                                        }
                                        .toolbarBackground(.hidden, for: .navigationBar)
                                }
                            }
                        }
                    }
//                }
                
                //TODO: Determine if this is still neccesary
                Section (header: Text("Problems")) {
                    if let site = selectedSite {
                        ProblemTable(site: site)
                            .frame(height: 400)
                    }
                }
                
                //Add address, GPS coordinates
                Section (header: Text("Details")) {
                    let site = selectedSite ?? nil
                    
                    VStack (alignment: .leading) {
                        //TODO: Add NetBox data
                        Text("Address")
                            .font(.headline)
                        Text(site?.physicalAddress ?? "Unknown")
                            .font(.caption)
                        
                        Divider()
                        
                        Text("Devices")
                            .font(.headline)
                        Text("\(site?.devices?.count ?? 0)")
                            .font(.caption)
                    }
                }
                
            }
        }
    }
}
#endif
