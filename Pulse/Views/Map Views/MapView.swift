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
import OSLog

struct MapView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query private var sites: [Site]

    // PowerSense data for basic stats
    @Query private var powerSenseEvents: [PowerSenseEvent]
    @Query private var powerSenseDevices: [PowerSenseDevice]

    // Phase 3: GPU-accelerated spatial clustering for outage visualization
    @State private var spatialClusters: [DeviceCluster] = []
    @State private var isClusteringInProgress = false
    @State private var showOutagePolygons = true
    @State private var lastClusteringTime: Date?

    // TEST ONLY: Device circle rendering (easily removable)
    @State private var showTestDeviceCircles = false // Set to false to disable

    // Debug logging
    private let logger = Logger(subsystem: "pulse", category: "mapView")

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
        mainMapView
            .onAppear {
                logger.info("🏁 MapView onAppear - PowerSense overlay enabled: \(showPowerSenseOverlay)")
                // Only initialize if PowerSense overlay is actually enabled
                if showPowerSenseOverlay {
                    Task {
                        await performSpatialClustering()
                    }
                } else {
                    logger.info("⏭️ Skipping PowerSense initialization - overlay disabled")
                }
            }
            .onChange(of: showPowerSenseOverlay) { _, isEnabled in
                logger.info("🔄 PowerSense overlay toggled: \(isEnabled)")
                if isEnabled {
                    Task {
                        await performSpatialClustering()
                    }
                } else {
                    // Clear clusters when overlay is disabled
                    spatialClusters = []
                    logger.info("🧹 Cleared spatial clusters - overlay disabled")
                }
            }
            .onChange(of: offlinePowerSenseDevices.count) { _, newCount in
                // Re-cluster when offline device count changes
                logger.info("📱 Offline device count changed: \(newCount)")
                if showPowerSenseOverlay && newCount > 0 {
                    Task {
                        await performSpatialClustering()
                    }
                }
            }
    }

    // MARK: - Main Map View

    private var mainMapView: some View {
        ZStack(alignment: .topTrailing) {
            mapReaderContent
            overlayContent
        }
    }

    private var mapReaderContent: some View {
        MapReader { reader in
            mapContent
                .onTapGesture(perform: { screenCoord in
                    handleMapTap(reader: reader, screenCoord: screenCoord)
                })
                .mapControlVisibility(.visible)
                .mapStyle(currentMapStyle)
                .mapControls {
                    mapControlsContent
                }
        }
    }

    private var mapContent: some View {
        Map(position: $cameraPosition) {
            siteAnnotations

            // Phase 3: Render outage polygons from spatial clustering
            if showOutagePolygons && showPowerSenseOverlay {
                outagePolygonOverlays
            }
        }
    }

    @MapContentBuilder
    private var siteAnnotations: some MapContent {
        ForEach(sites) { site in
            Annotation(site.name, coordinate: site.coordinate) {
                AnnotationView(
                    site: site,
                    selectedSite: $selectedSite
                )
            }
        }
    }

    // MARK: - Phase 3 Outage Polygon Overlays

    @MapContentBuilder
    private var outagePolygonOverlays: some MapContent {
        // Render polygons in batches to prevent UI hangs
        let validClusters = spatialClusters.filter { $0.polygon != nil && $0.hullVertices.count >= 3 }

        ForEach(validClusters) { cluster in
            if let polygon = cluster.polygon {
                MapPolygon(polygon)
                    .foregroundStyle(polygonStyle(for: cluster))
            }
        }
    }

    // MARK: - Phase 3 Styling Functions

    private func polygonStyle(for cluster: DeviceCluster) -> Color {
        // Fill opacity based on device count (20-80%)
        let deviceCount = cluster.devices.count
        let normalizedCount = min(1.0, Double(deviceCount) / 500.0) // Normalize to 500 devices
        let alpha = 0.2 + (normalizedCount * 0.6) // 20% minimum, 80% maximum

        // Fill color based on confidence rating
        let baseColor = confidenceColor(for: cluster.confidenceRating)
        return baseColor.opacity(alpha)
    }

    /// Map confidence rating to color gradient: yellow (low) → orange (medium) → red (high)
    /// - <20%: Yellow
    /// - 20-70%: Yellow → Orange → Red gradient
    /// - >70%: Red
    private func confidenceColor(for confidence: Double) -> Color {
        if confidence < 0.2 {
            return .yellow
        } else if confidence > 0.7 {
            return .red
        } else {
            // Linear interpolation from yellow (20%) → orange (45%) → red (70%)
            let normalized = (confidence - 0.2) / 0.5 // 0.0 at 20%, 1.0 at 70%

            if normalized < 0.5 {
                // Yellow to orange (20-45%)
                let t = normalized * 2.0 // 0.0-1.0 in first half
                return Color(
                    red: 1.0,
                    green: 1.0 - (t * 0.35), // 1.0 → 0.65
                    blue: 0.0
                )
            } else {
                // Orange to red (45-70%)
                let t = (normalized - 0.5) * 2.0 // 0.0-1.0 in second half
                return Color(
                    red: 1.0,
                    green: 0.65 - (t * 0.65), // 0.65 → 0.0
                    blue: 0.0
                )
            }
        }
    }

    @ViewBuilder
    private var mapControlsContent: some View {
        MapCompass()
        MapScaleView()
        MapPitchToggle()
        #if os(macOS)
        MapPitchSlider()
        MapZoomStepper()
        #endif
    }

    private var currentMapStyle: _MapKit_SwiftUI.MapStyle {
        mapStyle == .standard ?
            .standard(elevation: .realistic, emphasis: .automatic, pointsOfInterest: .excludingAll) :
            .imagery(elevation: .realistic)
    }

    @ViewBuilder
    private var overlayContent: some View {
        #if os(iOS)
        buttonOverlays
        #endif

        if showPowerSenseOverlay {
            powerSenseStatsOverlay
        }
    }

    private var powerSenseStatsOverlay: some View {
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

    // MARK: - Helper Methods

    private func handleMapTap(reader: MapProxy, screenCoord: CGPoint) {
        Task {
            if let tapLocation = reader.convert(screenCoord, from: .local) {
                sharedLocations.tapLocation = tapLocation

                let address = await getAddress(coordinate: tapLocation)
                if let address = address {
                    sharedLocations.tapAddress = address
                }
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
        // TODO: Replace CLGeocoder with MKReverseGeocodingRequest (deprecated in macOS 26.0)
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

    // MARK: - Phase 3 Spatial Clustering Integration

    private func performSpatialClustering() async {
        guard !isClusteringInProgress else {
            logger.info("⏸️ Spatial clustering already in progress, skipping")
            return
        }

        let offlineDevices = offlinePowerSenseDevices
        let totalDevices = powerSenseDevices.count
        let onlineDevices = onlinePowerSenseDevices.count
        let unknownDevices = unknownStatusDevices.count

        logger.info("📊 PowerSense Device Status - Total: \(totalDevices), Online: \(onlineDevices), Offline: \(offlineDevices.count), Unknown: \(unknownDevices)")

        guard !offlineDevices.isEmpty else {
            logger.info("📍 No offline devices found for clustering (need devices with isOffline = true)")
            await MainActor.run {
                spatialClusters = []
            }
            return
        }

        logger.info("🚀 Starting spatial clustering for \(offlineDevices.count) offline devices")

        await MainActor.run {
            isClusteringInProgress = true
        }

        do {
            let clusteringActor = try SpatialClusteringActor(
                modelContainer: modelContext.container,
                config: SpatialClusteringConfig.default
            )

            // Perform GPU-accelerated clustering with Phase 3 hull computation
            let result = try await clusteringActor.clusterAllDevices()

            // Use DeviceCluster results with polygon data from Phase 3
            let clusters = result.clusters

            // Compute statistics off the main thread to avoid UI blocking
            let statsStartTime = CFAbsoluteTimeGetCurrent()
            let totalDevicesInClusters = clusters.reduce(0) { $0 + $1.deviceCount }
            let avgConfidence = clusters.isEmpty ? 0.0 : clusters.map(\.confidenceRating).reduce(0, +) / Double(clusters.count)
            let clustersWithPolygons = clusters.filter { $0.polygon != nil }.count
            let statsTime = CFAbsoluteTimeGetCurrent() - statsStartTime

            logger.info("✅ Spatial clustering completed: \(clusters.count) clusters generated")
            logger.info("📊 Cluster stats - Total devices: \(totalDevicesInClusters), Avg confidence: \(String(format: "%.2f", avgConfidence))")
            logger.info("🗺️ Polygon stats - \(clustersWithPolygons)/\(clusters.count) clusters have polygons for rendering")
            logger.info("⏱️ Statistics computation: \(String(format: "%.1f", statsTime * 1000))ms")

            // Debug: Print coordinate bounds for first few clusters (off main thread)
            if !clusters.isEmpty {
                logger.info("🗺️ Cluster coordinate ranges:")
                for (index, cluster) in clusters.prefix(3).enumerated() {
                    if !cluster.hullVertices.isEmpty {
                        let lats = cluster.hullVertices.map(\.latitude)
                        let lons = cluster.hullVertices.map(\.longitude)
                        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
                        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
                        logger.info("   Cluster \(index): lat[\(String(format: "%.3f", minLat)), \(String(format: "%.3f", maxLat))] lon[\(String(format: "%.3f", minLon)), \(String(format: "%.3f", maxLon))]")
                    }
                }
            }

            // Debug individual clusters (off main thread)
            for (index, cluster) in clusters.enumerated() {
                logger.debug("📍 Cluster \(index): \(cluster.deviceCount) devices, \(cluster.hullVertices.count) hull vertices, polygon: \(cluster.polygon != nil ? "✓" : "✗")")
            }

                    // Update UI on main thread with minimal processing
            let uiUpdateStartTime = CFAbsoluteTimeGetCurrent()
            await MainActor.run {
                self.spatialClusters = clusters
                self.isClusteringInProgress = false
                self.lastClusteringTime = Date()
            }
            let uiUpdateTime = CFAbsoluteTimeGetCurrent() - uiUpdateStartTime
            logger.info("⏱️ UI update time: \(String(format: "%.1f", uiUpdateTime * 1000))ms")

        } catch {
            logger.error("❌ Spatial clustering failed: \(error.localizedDescription)")

            await MainActor.run {
                isClusteringInProgress = false
                // Keep existing clusters on error rather than clearing
            }
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

