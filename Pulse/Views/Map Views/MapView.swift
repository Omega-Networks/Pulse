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
@preconcurrency import MapKit
import SwiftData
import CoreLocation
import OSLog

struct MapView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(\.modelContext) private var modelContext
    @Environment(ClusteringService.self) private var clusteringService
    @Environment(PowerSenseMonitorService.self) private var monitorService
    @Query private var sites: [Site]

    // Phase 3: GPU-accelerated spatial clustering for outage visualization
    @State private var spatialClusters: [DeviceCluster] = []
    @State private var clusteringStats: ClusteringStats?
    @State private var isClusteringInProgress = false
    @State private var showOutagePolygons = true
    @State private var lastClusteringTime: Date?

    // Phase 6: Cluster detail view
    @State private var selectedCluster: DeviceCluster?
    @State private var showClusterDetail = false

    // Debug logging
    private let logger = Logger(subsystem: "pulse", category: "mapView")

    // Simple stats struct for display
    private struct ClusteringStats {
        let totalDevices: Int
        let offlineDevices: Int
        let onlineDevices: Int
        let totalEvents: Int
        let activeEvents: Int
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
                        await showCachedClusters()
                    }
                } else {
                    logger.info("⏭️ Skipping PowerSense initialization - overlay disabled")
                }
            }
            .onDisappear {
                // Clean up overlays to reduce MapKit rendering warnings
                logger.debug("🧹 MapView disappearing - cleaning up overlays")
                withAnimation(.easeInOut(duration: 0.2)) {
                    spatialClusters = []
                }
            }
            .onChange(of: showPowerSenseOverlay) { _, isEnabled in
                logger.info("🔄 PowerSense overlay toggled: \(isEnabled)")
                if isEnabled {
                    Task {
                        await showCachedClusters()
                    }
                } else {
                    // Clear clusters when overlay is disabled with animation
                    withAnimation(.easeInOut(duration: 0.4)) {
                        spatialClusters = []
                    }
                    logger.info("🧹 Cleared spatial clusters - overlay disabled")
                }
            }
            .onChange(of: monitorService.cachedResult) { _, newResult in
                // Auto-update polygons when background polling detects changes
                guard showPowerSenseOverlay, let result = newResult else { return }

                logger.info("🔄 Background update detected - refreshing \(result.clusters.count) polygons")

                let stats = ClusteringStats(
                    totalDevices: result.totalDevices,
                    offlineDevices: result.offlineDevices,
                    onlineDevices: result.totalDevices - result.offlineDevices,
                    totalEvents: result.totalEvents,
                    activeEvents: result.activeEvents
                )

                withAnimation(.easeInOut(duration: 0.4)) {
                    self.spatialClusters = result.clusters
                    self.clusteringStats = stats
                    self.lastClusteringTime = Date()
                }
            }
            .onChange(of: lastClusteringTime) { _, _ in
                // Trigger re-clustering when data changes
                // Note: Data change detection now handled by actor
            }
            .sheet(isPresented: $showClusterDetail) {
                if let cluster = selectedCluster {
                    ClusterDetailView(cluster: cluster)
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

    // MARK: - Phase 4: Gradient Outage Polygon Overlays

    @MapContentBuilder
    private var outagePolygonOverlays: some MapContent {
        // Render gradient layers for each cluster (heat map effect)
        let validClusters = spatialClusters.filter { !$0.gradientLayers.isEmpty }

        ForEach(validClusters) { cluster in
            // Render each gradient layer from outermost (lightest) to innermost (darkest)
            ForEach(Array(cluster.gradientLayers.enumerated()), id: \.offset) { layerIndex, layerVertices in
                if layerVertices.count >= 3 {
                    let polygon = MKPolygon(coordinates: layerVertices, count: layerVertices.count)
                    MapPolygon(polygon)
                        .foregroundStyle(gradientLayerStyle(
                            for: cluster,
                            layerIndex: layerIndex,
                            totalLayers: cluster.gradientLayers.count
                        ))
                        .tag("\(cluster.clusterId)-\(layerIndex)")
                }
            }
        }

        // TODO: Add annotation markers for tap handling (disabled for now)
        // ForEach(validClusters) { cluster in
        //     if !cluster.hullVertices.isEmpty {
        //         // Calculate centroid for tap target
        //         let lats = cluster.hullVertices.map { $0.latitude }
        //         let lons = cluster.hullVertices.map { $0.longitude }
        //         if let avgLat = lats.reduce(0.0, +) / Double(lats.count) as Double?,
        //            let avgLon = lons.reduce(0.0, +) / Double(lons.count) as Double? {
        //             let centroid = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
        //
        //             Annotation("", coordinate: centroid) {
        //                 Circle()
        //                     .fill(.clear)
        //                     .frame(width: 40, height: 40)
        //                     .contentShape(Circle())
        //                     .onTapGesture {
        //                         selectedCluster = cluster
        //                         showClusterDetail = true
        //                     }
        //             }
        //         }
        //     }
        // }
    }

    // MARK: - Phase 4: Gradient Layer Styling Functions

    /// Compute gradient layer style with intensity increasing toward center
    private func gradientLayerStyle(for cluster: DeviceCluster, layerIndex: Int, totalLayers: Int) -> Color {
        // Base color from confidence rating
        let baseColor = confidenceColor(for: cluster.confidenceRating)

        // Increased opacity gradient: outermost 28% → innermost 45%
        // Layer 0 (outermost) = 28%, Layer N (innermost) = 45%
        let normalizedLayer = Double(layerIndex) / Double(max(totalLayers - 1, 1))
        let alpha = 0.28 + (normalizedLayer * 0.17)  // 28% → 45% gradient (was 8% → 25%)

        return baseColor.opacity(alpha)
    }

    private func polygonStyle(for cluster: DeviceCluster) -> Color {
        // Legacy single polygon style (deprecated - now using gradientLayerStyle)
        let deviceCount = cluster.devices.count
        let normalizedCount = min(1.0, Double(deviceCount) / 500.0)
        let alpha = 0.3 + (normalizedCount * 0.3)

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
                if let stats = clusteringStats {
                    PowerSenseMapStatsBadge(
                        deviceCount: stats.totalDevices,
                        eventCount: stats.totalEvents,
                        eventsWithDevicesCount: stats.activeEvents,
                        offlineDeviceCount: stats.offlineDevices,
                        onlineDeviceCount: stats.onlineDevices
                    )
                }
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
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let geocoder = MKReverseGeocodingRequest(location: location)
        
        do {
            let placemarks = try await geocoder?.mapItems
            
            if let firstPlacemark = placemarks?.first
            {
                return "\(firstPlacemark.address, default: "")"
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

    /// Display cached clusters from monitor service (fast path: <0.4s)
    private func showCachedClusters() async {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Try to get cached result from monitor service
        let cachedResult = await MainActor.run {
            monitorService.getCachedResultIfValid()
        }

        if let result = cachedResult {
            logger.info("✅ Loading \(result.clusters.count) cached clusters...")

            // Extract stats from result
            let stats = ClusteringStats(
                totalDevices: result.totalDevices,
                offlineDevices: result.offlineDevices,
                onlineDevices: result.totalDevices - result.offlineDevices,
                totalEvents: result.totalEvents,
                activeEvents: result.activeEvents
            )

            // Update UI on main thread with animation
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.4)) {
                    self.spatialClusters = result.clusters
                    self.clusteringStats = stats
                    self.lastClusteringTime = Date()
                }
            }

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            logger.info("✅ Displayed \(result.clusters.count) cached clusters in \(String(format: "%.3f", duration))s")
        } else {
            // Fallback: cache invalid or empty, trigger fresh clustering
            logger.info("Cache invalid or empty - requesting fresh clustering")
            await requestFreshClustering()
        }
    }

    /// Request fresh clustering when cache is invalid (fallback path)
    private func requestFreshClustering() async {
        guard !isClusteringInProgress else {
            logger.info("⏸️ Clustering already in progress, skipping")
            return
        }

        await MainActor.run {
            isClusteringInProgress = true
        }

        do {
            logger.info("🔄 Requesting fresh clustering from monitor service...")
            try await monitorService.refreshClusters()

            // Show the newly cached clusters
            await showCachedClusters()

            await MainActor.run {
                isClusteringInProgress = false
            }
        } catch {
            logger.error("❌ Fresh clustering failed: \(error.localizedDescription)")

            await MainActor.run {
                isClusteringInProgress = false
                // Keep existing clusters on error rather than clearing
            }
        }
    }

    /// Derive statistics from cluster collection
    private func deriveStatsFromClusters(_ clusters: [DeviceCluster]) -> ClusteringStats {
        let totalDevices = clusters.reduce(0) { $0 + $1.deviceCount }
        let offlineDevices = clusters.flatMap { $0.devices }.filter { $0.isOffline == true }.count

        return ClusteringStats(
            totalDevices: totalDevices,
            offlineDevices: offlineDevices,
            onlineDevices: totalDevices - offlineDevices,
            totalEvents: 0, // TODO: Get from service if needed
            activeEvents: 0
        )
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

extension CLLocationCoordinate2D {
    //North Island coordinates now a static variable
    static var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: -38.831985, longitude: 175.870069)
    }
}

