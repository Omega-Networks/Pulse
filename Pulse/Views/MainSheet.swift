//
//  MainSheet.swift
//  Pulse
//
//  Created by Matt Lawrence Romanes (Omega Networks) on 20/02/24.
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
    @Binding var searchText: String
    @Binding var cameraPosition: MapCameraPosition
    @Binding var selectedSite: Site?
    
    @Binding var selectedSiteGroups: Set<Int64>
    @State private var filteredSites: [Site] = []
    @Query private var sites: [Site]
    
    var body: some View {
        VStack {
            // Search bar for filtering the list of sites
            SearchBar(text: $searchText, onClear: {
                Task {
                    await filterSites()
                }
            })
            .padding([.horizontal, .top], 20)
            
            // List of filtered sites
            List(filteredSites) { site in
                SiteRow(
                    cameraPosition: $cameraPosition,
                    selectedSite: $selectedSite, 
                    siteId: site.id
                )
            }
            .frame(minWidth: 400, idealWidth: 450, maxWidth: 500, maxHeight: .infinity)
        }
        .onAppear {
            Task.detached(priority: .background) {
                await filterSites()
            }
        }
        .onChange(of: sites) {
            Task.detached(priority: .background) {
                await filterSites()
            }
        }
        .onChange(of: searchText) {
            Task.detached(priority: .background) {
                await filterSites()
            }
        }
    }
    
    /**
     Filters the list of sites based on the current search text and selected site groups. The filtered list is sorted based on severity and name.
     
     This function performs the filtering and sorting asynchronously and updates the ViewModel's `filteredSites` property with the results.
     
     - Uses `lowercasedSearchText` to ensure case-insensitive search.
     - Filters based on site name and group membership, with support for empty search text (show all sites) and selection of multiple site groups.
     - Sorts the results by severity and then by name to prioritize more severe sites.
     */
    private func filterSites() async {
        let lowercasedSearchText = searchText.lowercased()
        let filtered = sites.filter { site in
            let siteGroupId = site.group?.id ?? 0
            let siteName = site.name.lowercased()
            
            let nameMatches = lowercasedSearchText.isEmpty || siteName.contains(lowercasedSearchText)
            let groupMatches = selectedSiteGroups.isEmpty || selectedSiteGroups.contains(siteGroupId)
            
            return nameMatches && groupMatches
        }
            .sorted { (site1, site2) -> Bool in
                if site1.highestSeverityInt != site2.highestSeverityInt {
                    return site1.highestSeverityInt > site2.highestSeverityInt
                }
                return site1.name < site2.name
            }
        
        // Perform UI update on the main thread
        await MainActor.run {
            filteredSites = filtered
        }
    }
    
}
#endif
