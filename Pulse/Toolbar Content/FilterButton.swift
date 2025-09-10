//
//  FilterButton.swift
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

struct FilterButton: View {
    @Binding var openSiteGroups: Bool
    
    @Query private var siteGroups: [SiteGroup]
    @Binding var selectedSiteGroups: Set<Int64>
    @Binding var selectedSite: Site?
    
    var body: some View {
        Button(action: {
            openSiteGroups.toggle()
        }) {
            Image(systemName: "list.triangle")
                .fontWeight(.bold)
            #if os (iOS)
                .font(.system(size: 22))
            #endif
        }
        #if os(macOS)
        .popover(isPresented: $openSiteGroups, arrowEdge: .bottom) {
            VStack {
                List(siteGroups, id: \.id) { siteGroup in
                    SiteGroupRow(siteGroup: siteGroup, selectedSiteGroups: $selectedSiteGroups)
                        .contentShape(Rectangle())
                }
            }
            .frame(width: 400, height: 300)
        }
        #elseif os (iOS)
        .sheet(isPresented: $openSiteGroups) {
            VStack {
                //MARK: New view
                List(siteGroups, id: \.id) { siteGroup in
                    SiteGroupRow(siteGroup: siteGroup, selectedSiteGroups: $selectedSiteGroups)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedSiteGroups.contains(siteGroup.id) {
                                selectedSiteGroups.remove(siteGroup.id)
                            } else {
                                selectedSiteGroups.insert(siteGroup.id)
                            }
                            // Deselecting any selected site
                            selectedSite = nil
                        }
                }
            }
            .presentationDetents([.medium])
            .frame(width: 400, height: 300)
        }
        #endif
    }
}


