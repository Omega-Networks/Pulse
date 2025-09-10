//
//  MainSheet.swift
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


//TODO: Enable real-time updates for this view

#if os(iOS)
/**
 A SwiftUI view that presents a searchable list of sites. It includes a `SearchBar` for filtering the list based on user input and displays each site using a `SiteRow`. The view is intended to be used as a main sheet in an application, allowing users to search for and select sites from a list.
 
 - Parameters:
 - searchText: A binding to a String value that represents the current input in the search bar. This value is used to filter the list of sites.
 - cameraPosition: A binding to a `MapCameraPosition` value that may be used to adjust the map view based on the selected site (not directly manipulated within this view but passed to `SiteRow`).
 - sites: An environment query that fetches the list of sites to be displayed. This data is filtered based on the search text and selected site groups.
 
 The view performs asynchronous filtering of sites based on the search text and selected site groups from the ViewModel. It updates the list of filtered sites to reflect the current search criteria and selected site groups.
 
 - Note: The `filterSites` function is a private asynchronous function that filters and sorts the sites based on the search criteria and selected site groups. It updates the ViewModel's `filteredSites` property with the results.
 
 - Important: The view relies on the `ViewModel` to provide data and manage state related to site selection and filtering. Make sure the ViewModel is properly initialized and injected into the environment.
 
 - TODO: Implement additional functionality as needed, such as handling selection of sites from the list and updating the map camera position accordingly.
 */
struct MainSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sites: [Site]
    @Binding var searchText: String
    var selectedSiteGroups: Set<Int64>
    @Binding var cameraPosition: MapCameraPosition
    @Binding var selectedSite: Site?
    //Boolean variable for opening settings sheet
    @State private var showSettingsSheet: Bool = false
    
    init(
        searchText: Binding<String>,
        selectedSiteGroups: Set<Int64>,
        cameraPosition: Binding<MapCameraPosition>,
        selectedSite: Binding<Site?>
    ) {
        self._searchText = searchText
        self.selectedSiteGroups = selectedSiteGroups
        self._cameraPosition = cameraPosition
        self._selectedSite = selectedSite
        
        // Predicate for filtering sites by search text and selected site groups
        let predicate = #Predicate<Site> { site in
            (selectedSiteGroups.isEmpty || (site.group.flatMap { selectedSiteGroups.contains($0.id) } ?? false))
        }
        
        // Query sites and enable filtering using the predicate and sorting using the sort descriptor
        //TODO: Refine sorting logic by highest Severity
        _sites = Query(
            filter: predicate,
            sort: [
                SortDescriptor(\Site.highestSeverityStored, order: .reverse),
                SortDescriptor(\Site.name)
            ]
        )
    }
    
    var body: some View {
        VStack {
            HStack(spacing: 10) { // Add spacing here to control gap between elements
                // Search bar for filtering the list of sites
                SearchBar(text: $searchText)
                    .padding(.top, 20) // Remove horizontal padding

                //Settings icon for inputting NetBox, Zabbix API and URL
                Image(systemName: "gear")
                    .font(.title)
                    .foregroundColor(.primary)
                    .padding(.top, 20)
                    .padding(.trailing, 20) // Add trailing padding to maintain some space from the edge
                    .onTapGesture {
                        showSettingsSheet = true
                    }
            }
            .padding(.leading, 20) // Add leading padding to the HStack to maintain left alignment
            
            // List of filtered sites
            List(sites) { site in
                SiteRow(
                    cameraPosition: $cameraPosition,
                    selectedSite: $selectedSite,
                    siteId: site.id
                )
            }
            .frame(minWidth: 400, idealWidth: 450, maxWidth: 500, maxHeight: .infinity)
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView()
            }
        }
    }
}

#endif
