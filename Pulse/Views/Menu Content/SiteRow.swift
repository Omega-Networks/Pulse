//
//  SiteRow.swift
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

struct SiteRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query private var site: [Site]
    @Binding var cameraPosition: MapCameraPosition
    @Binding var selectedSite: Site?
    
    var siteId: Int64
    
    
    init(cameraPosition: Binding<MapCameraPosition>, selectedSite: Binding<Site?>, siteId: Int64) {
        _cameraPosition = cameraPosition
        _selectedSite = selectedSite
        self.siteId = siteId
        
        _site = Query(filter: #Predicate<Site> { $0.id == siteId })
    }
    
    var body: some View {
        HStack {
            ZStack(alignment: .center) {
                Circle()
                    .frame(width: 25, height: 25)
                    .foregroundColor(site.first?.severityColor)
                Image(systemName: "building.fill")
                    .foregroundColor(site.first?.severityColor == Color.black ? Color.white : Color.black )
            }
            .padding(.leading, 8.0)
            VStack(alignment: .leading) {
                Text(site.first?.name ?? "Error")
#if os(macOS)
                    .foregroundColor(selectedSite == site.first ? .white : (colorScheme == .light ? .primary : .primary))
#endif
                    .lineLimit(1)
                Text(site.first?.group?.name ?? "N/A")
                    .font(.system(size: 11))
#if os(macOS)
                    .foregroundColor(selectedSite == site.first ? .white : (colorScheme == .light ? .primary : .primary))
#endif
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
#if os(macOS)
        .background(
            selectedSite == site.first ? Color.accentColor : Color.clear)
#endif
        .cornerRadius(5)
        .contentShape(Rectangle()) // Ensures the entire view is tappable
        .onTapGesture {
            selectedSite = site.first
            
            ///Wrapped in an async block to ensure a responsive user experience
            DispatchQueue.main.async {
                let siteCoordinates: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: site.first?.latitude ?? 0, longitude: site.first?.longitude ?? 0)
                withAnimation  {
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: siteCoordinates, distance: 5000, heading: 0, pitch: 0
                    ))
                }
            }
        }
    }
}

extension SiteRow {
    // Method for returning a Color based on an Int64 value
    func color(for value: Int64?) -> Color {
        guard let value = value else {
            return .purple
        }
        
        switch value {
        case 0:
            return .gray
        case 1:
            return .blue
        case 2:
            return .yellow
        case 3:
            return .orange
        case 4:
            return .red
        case 5:
            return .black
        case -1:
            return .green
        default:
            return .primary
        }
    }
}
