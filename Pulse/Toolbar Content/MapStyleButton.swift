//
//  MapStyleButton.swift
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

struct MapStyleButton: View {
    @Binding var openMapStyles: Bool
    @Binding var mapStyle: MapStyle
    
    var body: some View {
        Button(action: {
            openMapStyles.toggle()
        }) {
            Image(systemName: "map")
                .fontWeight(.bold)
            #if os(iOS)
                .font(.system(size: 22))
            #endif
        }
        #if os(macOS)
        .popover(isPresented: $openMapStyles, arrowEdge: .bottom) {
            MapStyleView(selectedStyle: $mapStyle)
                .frame(width: 200, height: 150)
                .padding(2)
        }
        #endif
    }
}

enum MapStyle: String, Codable, Hashable {
    case standard
    case imagery
}

// MARK: Helper view for displaying MapStyle (similar to Apple Maps)
struct MapStyleView: View {
    @Binding var selectedStyle: MapStyle
    let mapStyles: [MapStyle] = [.standard, .imagery]
    
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 10) {
            ForEach(mapStyles, id: \.self) { style in
                VStack {
                    MapStylePreview(style: style)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedStyle == style ? Color.blue : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture {
                            DispatchQueue.main.async {
                                selectedStyle = style
                            }
                        }
                    
                    Text(style == .imagery ? "Satellite" : style.rawValue.capitalized)
                        .font(.caption)
                }
            }
        }
    }
}

struct MapStylePreview: View {
    let style: MapStyle
    private let cameraPosition: MapCameraPosition = .camera(MapCamera(
        centerCoordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090), distance: 1000, heading: 0, pitch: 0
    ))
    
    var body: some View {
        Map(initialPosition: cameraPosition, interactionModes: [])
            .mapStyle(
                style == .standard ? 
                    .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll)
                :    .imagery(elevation: .flat)
            )
            .allowsHitTesting(true)
            .aspectRatio(1, contentMode: .fit)
    }
}

