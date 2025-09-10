//
//  SitesList.swift
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
import MapKit
import SwiftData

struct SitesList: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sites: [Site]
    var searchText: String
    var selectedSiteGroups: Set<Int64>
    @Binding var cameraPosition: MapCameraPosition
    @Binding var selectedSite: Site?
    
    init(
        searchText: String,
        selectedSiteGroups: Set<Int64>,
        cameraPosition: Binding<MapCameraPosition>,
        selectedSite: Binding<Site?>
    ) {
        self.searchText = searchText
        self.selectedSiteGroups = selectedSiteGroups
        self._cameraPosition = cameraPosition
        self._selectedSite = selectedSite
        
        let predicate = #Predicate<Site> { site in
            (searchText.isEmpty || site.name.localizedStandardContains(searchText)) &&
            (selectedSiteGroups.isEmpty || (site.group.flatMap { selectedSiteGroups.contains($0.id) } ?? false))
        }
        
        // Just sort by name initially
        _sites = Query(
            filter: predicate,
            sort: [SortDescriptor(\Site.name)]
        )
    }
    
    var body: some View {
        ScrollView(.vertical) {
            LazyVStack {
                // Sort sites in the view instead
                ForEach(sites.sorted { site1, site2 in
                    if site1.highestSeverity != site2.highestSeverity {
                        return site1.highestSeverity > site2.highestSeverity
                    }
                    return site1.name < site2.name
                }) { site in
                    SiteRow(
                        cameraPosition: $cameraPosition,
                        selectedSite: $selectedSite,
                        siteId: site.id
                    )
                }
            }
        }
        .id(UUID())
        .frame(minWidth: 400, idealWidth: 450, maxWidth: 500, maxHeight: .infinity)
    }
}
