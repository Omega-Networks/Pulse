//
//  MapView.swift
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
import CoreLocation
//import simd

struct MapView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query private var sites: [Site]

    // PowerSense data for basic stats
    @Query private var powerSenseEvents: [PowerSenseEvent]
    @Query private var powerSenseDevices: [PowerSenseDevice]

    // Computed property for events related to devices
    private var eventsRelatedToDevices: [PowerSenseEvent] {
        powerSenseEvents.filter { $0.device != nil }
    }

    // Computed properties for device power states
    private var offlinePowerSenseDevices: [PowerSenseDevice] {
        powerSenseDevices.filter { device in
            device.isOffline == true  // Explicitly offline (has active event)
        }
    }

    private var onlinePowerSenseDevices: [PowerSenseDevice] {
        powerSenseDevices.filter { device in
            device.isOffline == false  // Explicitly online (has resolved event)
        }
    }

    private var unknownStatusDevices: [PowerSenseDevice] {
        powerSenseDevices.filter { device in
            device.isOffline == nil  // No events, status unknown
        }
    }
    @Binding var cameraPosition: MapCameraPosition
    @Binding var mapStyle: MapStyle

    @Binding var selectedSite: Site?
    var selectedSiteGroups: Set<Int64>
    @Binding var showPowerSenseOverlay: Bool
    
    //State variable for storing coordinate data
    @State private var tapLocation: CLLocationCoordinate2D? = nil
    @Environment(SharedLocations.self) private var sharedLocations   // Inject the shared instance
    
    //Property is iOS-specific only
    #if os (iOS)
    @Query private var syncProvider: [SyncProvider]
    @Binding var openSiteGroups: Bool
    @Binding var isMapSheetPresented: Bool
    #endif
    
    #if os(macOS)
    init(
        cameraPosition: Binding<MapCameraPosition>,
        mapStyle: Binding<MapStyle>,
        selectedSite: Binding<Site?>,
        selectedSiteGroups: Set<Int64>,
        showPowerSenseOverlay: Binding<Bool>
    ) {
        self.selectedSiteGroups = selectedSiteGroups
        self._cameraPosition = cameraPosition
        self._selectedSite = selectedSite
        self._mapStyle = mapStyle
        self._showPowerSenseOverlay = showPowerSenseOverlay
        
        // Predicate for filtering sites by search text and selected site groups
        let predicate = #Predicate<Site> { site in
            (selectedSiteGroups.isEmpty || (site.group.flatMap { selectedSiteGroups.contains($0.id) } ?? false))
        }
        
        // Query sites and enable filtering using the predicate
        _sites = Query(filter: predicate)
    }
    #elseif os(iOS)
    init(
        cameraPosition: Binding<MapCameraPosition>,
        mapStyle: Binding<MapStyle>,
        selectedSite: Binding<Site?>,
        selectedSiteGroups: Set<Int64>,
        openSiteGroups: Binding<Bool>,
        isMapSheetPresented: Binding<Bool>,
        showPowerSenseOverlay: Binding<Bool>
    ) {
        self.selectedSiteGroups = selectedSiteGroups
        self._cameraPosition = cameraPosition
        self._selectedSite = selectedSite
        self._mapStyle = mapStyle
        self._openSiteGroups = openSiteGroups
        self._isMapSheetPresented = isMapSheetPresented
        self._showPowerSenseOverlay = showPowerSenseOverlay
        
        // Predicate for filtering sites by search text and selected site groups
        let predicate = #Predicate<Site> { site in
            (selectedSiteGroups.isEmpty || (site.group.flatMap { selectedSiteGroups.contains($0.id) } ?? false))
        }
        
        // Query sites and enable filtering using the predicate
        _sites = Query(filter: predicate)
    }
    #endif
    
    var body: some View {
        ZStack (alignment: .topTrailing) {
            MapReader { reader  in
                Map(position: $cameraPosition) {
                    // Site annotations
                    ForEach(sites) { site in
                        Annotation(site.name, coordinate: site.coordinate) {
                            AnnotationView(
                                site: site,
                                selectedSite: $selectedSite
                            )
                        }
                    }

                    // PowerSense device annotations (simple circles)
                    if showPowerSenseOverlay {
                        ForEach(offlinePowerSenseDevices, id: \.deviceId) { device in
                            if device.latitude != 0.0 && device.longitude != 0.0 {
                                Annotation(device.name ?? device.deviceId,
                                         coordinate: CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)) {
                                    PowerSenseDeviceCircle(device: device)
                                }
                            }
                        }
                    }
                }
                .onTapGesture(perform: { screenCoord in
                    Task {
                        if let tapLocation = reader.convert(screenCoord, from: .local) {
                            sharedLocations.tapLocation = tapLocation
                            
                            let address = await getAddress(coordinate: tapLocation)
                            if let address = address {
                                sharedLocations.tapAddress = address
                            }
                        }
                    }
                })
                .mapControlVisibility(.visible)
                .mapStyle(
                    mapStyle == .standard ?
                        .standard(elevation: .realistic, emphasis: .automatic, pointsOfInterest: .excludingAll) :
                        .imagery(elevation: .realistic)
                )
                .mapControls {
                    MapCompass()
                    MapScaleView()
                    MapPitchToggle()
                    #if os(macOS)
                    MapPitchSlider()
                    MapZoomStepper()
                    #endif
                }
            }
            
            //MARK: Overlay of buttons on top of map view
#if os(iOS)
            buttonOverlays
#endif

            // PowerSense statistics overlay (simple)
            if showPowerSenseOverlay {
                VStack {
                    HStack {
                        PowerSenseMapStatsBadge(
                            deviceCount: powerSenseDevices.count,
                            eventCount: powerSenseEvents.count,
                            eventsWithDevicesCount: eventsRelatedToDevices.count,
                            offlineDeviceCount: offlinePowerSenseDevices.count,
                            onlineDeviceCount: onlinePowerSenseDevices.count
                        )
                        Spacer()
                    }
                    Spacer()
                }
                .padding()
            }
        }
    }

    
    // MARK: - Liquid Glass Helpers
    private func toggleMapStyle() {
        withAnimation(.smooth(duration: 0.4)) {
            mapStyle = mapStyle == .standard ? .imagery : .standard
        }
    }
    
    
//  Subviews
    #if os(iOS)
    var buttonOverlays: some View {
        HStack {
            DataIndicator(color: getSymbolColor(for: syncProvider.first?.lastZabbixUpdate))
            Spacer()
            MapButton(action: {
                isMapSheetPresented.toggle()
            })
        }
        .padding(.leading, 16)
        .padding(.trailing, 45)  // Increased right padding to move the map icon further left
    }
    #endif
        
//    Helper functions
    
    func getCoordinateFromTap() -> CLLocationCoordinate2D {
        return CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194) // Dummy data
    }
    
    func getAddress(coordinate: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            
            if let firstPlacemark = placemarks.first,
               let street = firstPlacemark.thoroughfare,
               let suburb = firstPlacemark.locality,
               let city = firstPlacemark.administrativeArea,
               let postCode = firstPlacemark.postalCode,
               let houseNumber = firstPlacemark.subThoroughfare {
                
                return "\(houseNumber) \(street), \(suburb), \(city) \(postCode)"
            }
            return nil
            
        } catch {
            print("Error in reverse geocoding: \(error)")
            return nil
        }
    }
    
    private func getSymbolColor(for lastUpdate: Date?) -> Color {
        guard let lastUpdate = lastUpdate else {
            return .gray // Default color if no update is available
        }
        
        let now = Date()
        let timeDifference = now.timeIntervalSince(lastUpdate)
        
        switch timeDifference {
        case let diff where diff < 300: // Less than 5 minutes
            return .green
        case let diff where diff >= 300 && diff < 600: // Between 5 and 10 minutes
            return .orange
        default: // More than 10 minutes
            return .red
        }
    }
}

/**
 `SharedLocations` is a class that conforms to the `ObservableObject` protocol.
 This class is designed to hold and publish changes related to geographical coordinates and addresses.
 
 - Properties:
 - `tapLocation`: An optional `CLLocationCoordinate2D` that stores the latitude and longitude of a tapped location.
 - `tapAddress`: An optional `String` that stores the address corresponding to the tapped location.
 
 - Note:
 Any SwiftUI view that observes this object will refresh its UI when either `tapLocation` or `tapAddress` changes.
 
 - Example:
 ```swift
 @ObservedObject var sharedLocations = SharedLocations()
 ```
 */

// MARK: - PowerSense Simple Stats Component

struct PowerSenseMapStatsBadge: View {
    let deviceCount: Int
    let eventCount: Int
    let eventsWithDevicesCount: Int
    let offlineDeviceCount: Int
    let onlineDeviceCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("PowerSense")
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            // Device power status breakdown
            HStack(spacing: 12) {
                // Online devices
                HStack(spacing: 2) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("\(onlineDeviceCount)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                }

                // Offline devices
                if offlineDeviceCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.slash.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Text("\(offlineDeviceCount)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fontWeight(.medium)
                    }
                }
            }

            Text("\(deviceCount) total devices")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("\(eventCount) events")
                .font(.caption2)
                .foregroundStyle(.primary)

            if eventsWithDevicesCount > 0 {
                Text("\(eventsWithDevicesCount) linked to devices")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .fontWeight(.medium)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .shadow(radius: 2)
    }
}


@Observable
class SharedLocations {
    var tapLocation: CLLocationCoordinate2D?
    var tapAddress: String?
}

struct PowerSenseDeviceCircle: View {
    let device: PowerSenseDevice

    private var statusColor: Color {
        switch device.isOffline {
        case true: return .red      // Device is down
        case false: return .green   // Device is up
        case nil: return .orange    // Status unknown
        }
    }

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .drawingGroup() // Flatten rendering for performance
    }
}

extension CLLocationCoordinate2D {
    //North Island coordinates now a static variable
    static var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: -38.831985, longitude: 175.870069)
    }
}
