//
//  AnnotationView.swift
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
import MapKit

struct AnnotationView: View {
    @Environment(\.openWindow) var openWindow
    let site: Site  // Direct reference instead of query
    @Binding var selectedSite: Site?
    
    // Properties for the new RadialGradient pulse effect
    var duration = 2.0
    
    init(site: Site, selectedSite: Binding<Site?>) {
        self.site = site
        self._selectedSite = selectedSite
    }
    
    var circleFrame:CGFloat {
#if os(iOS)
        return 10;
#elseif os(macOS)
        return 30;
#endif
    }
    
    var body: some View {
        ZStack {
            let siteSeverityColour = site.severityColor
            let unacknowledgedSeverityColour = site.unacknowledgedSeverityColor
            
            //MARK: Pulse effect for showing highest unacknowledged severity
            if site.highestUnacknowledgedSeverity > 0 {
                Image(systemName: "circle.fill")
                    .font(.system(size: 100))
                    .symbolEffect(.pulse, options: .repeating.speed(2))
                    .foregroundStyle(RadialGradient(colors: [unacknowledgedSeverityColour, Color.clear, ],
                                                  center: .center,
                                                  startRadius: 0,
                                                  endRadius: 25))
            }
            // Rest of the view remains the same, but use site directly instead of site.first
            Circle()
                .fill(RadialGradient(
                    colors: [siteSeverityColour, siteSeverityColour, Color.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 5)
                )
                .onTapGesture {
                    selectedSite = site
                }
                .frame(width: circleFrame, height: circleFrame)
#if os(macOS)
                .popover(isPresented: Binding(
                    get: { selectedSite?.id == site.id },
                    set: { _ in selectedSite = nil }
                ), arrowEdge: .leading) {
                    if let selectedSite = selectedSite {
                        popoverContent(for: selectedSite)
                    }
                }
#endif
        }
    }
    
    ///Content of popover based on the site selected on the map
    private func popoverContent(for site: Site) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            //Title, subtitle
            HStack {
                VStack (alignment: .leading) {
                    Text(site.name)
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text(site.group?.name ?? "No Group")
                        .font(.caption)
                        .padding(.bottom, 20) // Add padding if needed to separate from the next content
                }
            }
            
            //TODO: Add button to close sheet
            Button {
                DispatchQueue.main.async {
                    openWindow(value: site.id)
                }
            } label: {
                Label("Open Topology View", systemImage: "network")
                    .labelStyle(.titleAndIcon)
            }
            .padding(.bottom, 20) // Add padding below the button
            
            Section (
                header:
                    EmptyView()
            ) {
                VStack (alignment: .leading) {
                    Text("Status")
                        .font(.headline)
                    Text(site.status?.capitalized ?? "N/A")
                        .font(.caption)
                    
                    Divider()
                    
                    Text("Address")
                        .font(.headline)
                    Text(site.physicalAddress ?? "Unknown")
                        .font(.caption)
                    
                    Divider()
                    
                    Text("Coordinates")
                        .font(.headline)
                    Text("\(site.coordinate.latitude),\(site.coordinate.longitude)")
                        .font(.caption)
                    
                    Divider()
                    
                    Text("Devices")
                        .font(.headline)
                    Text("\(site.devices?.count ?? 0)")
                        .font(.caption)
                }
            }
            .padding(.top, 10)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // Ensure VStack fills the sheet and aligns content to top
    }
}

//#Preview {
//    AnnotationView()
//}
