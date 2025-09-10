//
//  SiteGroupRow.swift
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

/**
 A view that represents a single row for a site group in a list. It displays the name of the site group and a toggle button that is checked if the site group is selected and unchecked if it is not selected. When the toggle button is clicked, it updates the selected site groups. It requires a SiteGroup object and a Binding array of selected site groups as inputs.
 */
struct SiteGroupRow: View {
    @Bindable var siteGroup: SiteGroup
    var isRoot: Bool = true
    @Binding var selectedSiteGroups: Set<Int64>
    @State private var isExpanded: Bool = false
    
    // Helper function to get all child IDs recursively
    private func getAllChildIds(from group: SiteGroup) -> Set<Int64> {
        var ids = Set<Int64>([group.id])
        if let children = group.children {
            for child in children {
                ids.formUnion(getAllChildIds(from: child))
            }
        }
        return ids
    }
    
    var body: some View {
        if siteGroup.parent == nil || !isRoot {
            VStack(alignment: .leading) {
                HStack {
                    if let children = siteGroup.children, !children.isEmpty {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .animation(.easeInOut, value: isExpanded)
                    }
                    
                    Toggle(siteGroup.name, isOn: Binding(
                        get: { selectedSiteGroups.contains(siteGroup.id) },
                        set: { isSelected in
                            let idsToModify = getAllChildIds(from: siteGroup)
                            if isSelected {
                                selectedSiteGroups.formUnion(idsToModify)
                            } else {
                                selectedSiteGroups.subtract(idsToModify)
                            }
                        }
                    ))
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let children = siteGroup.children, !children.isEmpty {
                        isExpanded.toggle()
                    }
                }
                
                if isExpanded, let children = siteGroup.children, !children.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(children) { child in
                            SiteGroupRow(siteGroup: child,
                                       isRoot: false,
                                       selectedSiteGroups: $selectedSiteGroups)
                                .padding(.leading)
                        }
                    }
                    .padding(.leading)
                    .padding([.vertical, .bottom], 2)
                }
            }
        }
    }
}
