//
//  SpatialClusteringTestView.swift
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
import CoreLocation
import SwiftData

// MARK: - Sendable Device Wrapper

/// Sendable wrapper for PowerSense device data to avoid concurrency issues
private struct SendableDeviceData: SpatialDevice, Sendable {
    let deviceId: String
    let latitude: Double
    let longitude: Double
    let isOffline: Bool?
}

/// Sendable wrapper for clustering results
fileprivate struct SendableClusterResult: Sendable {
    let clusters: [SendableDeviceCluster]
    let region: MKCoordinateRegion?
}

/// Sendable wrapper for device cluster data
fileprivate struct SendableDeviceCluster: Sendable, Identifiable {
    let id: Int
    let clusterId: Int
    let deviceCount: Int
    let centroidCoordinate: CLLocationCoordinate2D
    let severity: String // Store as string to avoid enum Sendable issues
    let confidenceRating: Double
    let totalDevicesInArea: Int

    var clusterSeverity: DeviceCluster.ClusterSeverity {
        switch severity {
        case "critical": return .critical
        case "major": return .major
        case "moderate": return .moderate
        default: return .minor
        }
    }
}

struct SpatialClusteringTestView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var powerSenseDevices: [PowerSenseDevice]

    @State private var isRunning = false
    @State private var testOutput: String = ""
    @State private var lastClusteringTime: Double = 0.0
    @State private var testCompleted = false
    @State private var clusters: [SendableDeviceCluster] = []
    @State private var showMap = false
    @State private var selectedClusterSeverity: DeviceCluster.ClusterSeverity? = nil
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4)
    )

    // Data filtering states
    @State private var showOnlyWithPowerData = true
    @State private var showOnlyOffline = false

    var body: some View {
        NavigationView {
            if showMap && !clusters.isEmpty {
                clusterVisualizationView
            } else {
                testingView
            }
        }
    }

    private var testingView: some View {
        VStack(spacing: 20) {
            Text("PowerSense Outage Clustering")
                .font(.title)
                .padding()

            if !testOutput.isEmpty {
                ScrollView {
                    Text(testOutput)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .padding()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "map.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)

                    Text("Spatial Clustering System")
                        .font(.title2)
                        .fontWeight(.medium)

                    Text("Run clustering analysis to detect PowerSense outage patterns and visualize them on an interactive map.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // Data source info
                    VStack(spacing: 4) {
                        Text("Data Source: \(filteredDevices.count) PowerSense Devices")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text("\(offlineDeviceCount) offline devices")
                            .font(.caption)
                            .foregroundColor(.orange)

                        if lastClusteringTime > 0 {
                            Text("Last run: \(String(format: "%.2f", lastClusteringTime))s (\(String(format: "%.0f", Double(filteredDevices.count) / lastClusteringTime)) devices/sec)")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding()
            }

            Spacer()

            VStack(spacing: 12) {
                // Filter controls
                VStack(spacing: 8) {
                    Toggle("Only devices with power data", isOn: $showOnlyWithPowerData)
                        .font(.caption)
                    Toggle("Only offline devices", isOn: $showOnlyOffline)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                if testCompleted && !clusters.isEmpty {
                    Button(action: { showMap = true }) {
                        HStack {
                            Image(systemName: "map")
                            Text("View Cluster Map")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }

                Button(action: runTest) {
                    HStack {
                        if isRunning {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(isRunning ? "Running Analysis..." : testCompleted ? "Run Analysis Again" : "Run Clustering Analysis")
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isRunning || filteredDevices.isEmpty ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(isRunning || filteredDevices.isEmpty)

                // Refresh button
                Button(action: refreshData) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh Data")
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }
            }
            .padding()
        }
        .navigationTitle("Outage Clustering")
    }

    private var clusterVisualizationView: some View {
        VStack(spacing: 0) {
            // Header with controls
            VStack(spacing: 8) {
                HStack {
                    Button("← Back to Tests") {
                        showMap = false
                    }
                    .foregroundColor(.blue)

                    Spacer()

                    Text("\(clusters.count) Outage Clusters")
                        .font(.headline)

                    Spacer()

                    Menu("Filter") {
                        Button("All Clusters") { selectedClusterSeverity = nil }
                        Divider()
                        Button("Critical") { selectedClusterSeverity = .critical }
                        Button("Major") { selectedClusterSeverity = .major }
                        Button("Moderate") { selectedClusterSeverity = .moderate }
                        Button("Minor") { selectedClusterSeverity = .minor }
                    }
                }

                clusterSummaryView
            }
            .padding()
            .background(Color(.gray))

            // Map View
            Map(position: .constant(.region(mapRegion))) {
                ForEach(filteredClusters) { cluster in
                    Annotation("\(cluster.deviceCount) devices", coordinate: clusterCoordinate(cluster)) {
                        ClusterAnnotationView(cluster: cluster)
                    }
                }
            }
        }
    }

    private var clusterSummaryView: some View {
        HStack(spacing: 16) {
            ClusterSummaryCard(
                title: "Critical",
                count: clusterCount(for: .critical),
                color: .red
            )
            ClusterSummaryCard(
                title: "Major",
                count: clusterCount(for: .major),
                color: .orange
            )
            ClusterSummaryCard(
                title: "Moderate",
                count: clusterCount(for: .moderate),
                color: .yellow
            )
            ClusterSummaryCard(
                title: "Minor",
                count: clusterCount(for: .minor),
                color: .blue
            )
        }
    }

    private var filteredClusters: [SendableDeviceCluster] {
        guard let severity = selectedClusterSeverity else { return clusters }
        return clusters.filter { $0.clusterSeverity == severity }
    }

    private func clusterCoordinate(_ cluster: SendableDeviceCluster) -> CLLocationCoordinate2D {
        // Use pre-computed coordinate to avoid any GPU transformations during map rendering
        return cluster.centroidCoordinate
    }

    private func clusterCount(for severity: DeviceCluster.ClusterSeverity) -> Int {
        clusters.filter { $0.clusterSeverity == severity }.count
    }

    private func runTest() {
        isRunning = true
        testOutput = ""
        testCompleted = false
        clusters = []

        Task {
            let startTime = CFAbsoluteTimeGetCurrent()

            // Run the actual clustering analysis
            await performClusteringAnalysis()

            let totalTime = CFAbsoluteTimeGetCurrent() - startTime
            self.lastClusteringTime = totalTime

            await MainActor.run {
                self.testOutput = """
                ✅ Spatial Clustering Analysis Complete!

                Data Source: \(self.filteredDevices.count) PowerSense devices
                Offline Devices: \(self.offlineDeviceCount) devices

                Results:
                - Found \(self.clusters.count) outage clusters
                - Critical: \(self.clusterCount(for: .critical))
                - Major: \(self.clusterCount(for: .major))
                - Moderate: \(self.clusterCount(for: .moderate))
                - Minor: \(self.clusterCount(for: .minor))

                The clustering system has successfully analyzed real PowerSense device outages and identified spatial patterns. Click "View Cluster Map" to visualize the results.

                ⏱️ Performance:
                - Total analysis time: \(String(format: "%.2f", self.lastClusteringTime))s
                - Processing rate: \(String(format: "%.0f", Double(self.filteredDevices.count) / self.lastClusteringTime)) devices/sec

                🎯 Ready for real-time outage detection and visualization!
                """
                self.isRunning = false
                self.testCompleted = true
            }
        }
    }

    private func performClusteringAnalysis() async {
        // Extract device data on main actor first (quick operation)
        let deviceData = filteredDevices.map { device in
            SendableDeviceData(
                deviceId: device.deviceId,
                latitude: device.latitude,
                longitude: device.longitude,
                isOffline: device.isOffline
            )
        }

        // Perform heavy computation off main actor to keep UI responsive
        let result = await Task.detached(priority: .userInitiated) {
            let startTime = CFAbsoluteTimeGetCurrent()

            do {
                // Create clustering manager (involves GPU initialization)
                let managerStartTime = CFAbsoluteTimeGetCurrent()
                let manager = try OutageClusteringManager(projectionSystem: .nztm2000)
                let managerTime = CFAbsoluteTimeGetCurrent() - managerStartTime
                print("⏱️ ClusteringManager creation: \(String(format: "%.2f", managerTime))s")

                // Define viewport based on device distribution or default to Wellington
                let viewport: MKMapRect
                let mapUpdateRegion: MKCoordinateRegion?

                if !deviceData.isEmpty {
                    // Calculate bounds from actual device locations
                    let minLat = deviceData.map { $0.latitude }.min() ?? -41.5
                    let maxLat = deviceData.map { $0.latitude }.max() ?? -41.0
                    let minLon = deviceData.map { $0.longitude }.min() ?? 174.5
                    let maxLon = deviceData.map { $0.longitude }.max() ?? 175.2

                    let center = CLLocationCoordinate2D(
                        latitude: (minLat + maxLat) / 2,
                        longitude: (minLon + maxLon) / 2
                    )
                    let span = MKCoordinateSpan(
                        latitudeDelta: (maxLat - minLat) * 1.2,
                        longitudeDelta: (maxLon - minLon) * 1.2
                    )
                    let region = MKCoordinateRegion(center: center, span: span)
                    viewport = MKMapRect(region)
                    mapUpdateRegion = region
                } else {
                    // Default Wellington region if no devices
                    let wellingtonCenter = CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762)
                    let span = MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.3)
                    let region = MKCoordinateRegion(center: wellingtonCenter, span: span)
                    viewport = MKMapRect(region)
                    mapUpdateRegion = nil
                }

                // Perform clustering with appropriate parameters based on device density
                // For very large datasets, use more restrictive parameters to improve performance
                let parameters: DBSCANClusterer.Parameters
                if deviceData.count > 10000 {
                    // Large dataset: use restrictive parameters to prevent performance issues
                    parameters = DBSCANClusterer.Parameters(epsilon: 500.0, minPoints: 8)
                } else if deviceData.count > 1000 {
                    parameters = .urban
                } else {
                    parameters = .suburban
                }

                print("📊 Clustering \(deviceData.count) devices with parameters: epsilon=\(parameters.epsilon)m, minPoints=\(parameters.minPoints)")

                // Cast to [any SpatialDevice] for clustering
                let spatialDevices: [any SpatialDevice] = deviceData.map { $0 as any SpatialDevice }

                // Heavy computation: clustering analysis (runs off main actor)
                print("🔥 Starting clustering analysis...")
                let clusteringStartTime = CFAbsoluteTimeGetCurrent()
                let foundClusters = try await manager.clusterDevicesInViewport(
                    devices: spatialDevices,
                    viewport: viewport,
                    paddingKm: 10.0,
                    clusteringParameters: parameters
                )
                let clusteringTime = CFAbsoluteTimeGetCurrent() - clusteringStartTime
                print("✅ Clustering analysis complete: found \(foundClusters.count) clusters in \(String(format: "%.2f", clusteringTime))s")

                // Convert to sendable format
                let conversionStartTime = CFAbsoluteTimeGetCurrent()
                let sendableClusters = foundClusters.map { cluster in
                    SendableDeviceCluster(
                        id: cluster.id,
                        clusterId: cluster.clusterId,
                        deviceCount: cluster.devices.count,
                        centroidCoordinate: cluster.centroidCoordinate,
                        severity: severityToString(cluster.severity),
                        confidenceRating: cluster.confidenceRating,
                        totalDevicesInArea: cluster.totalDevicesInArea
                    )
                }
                let conversionTime = CFAbsoluteTimeGetCurrent() - conversionStartTime

                let totalTime = CFAbsoluteTimeGetCurrent() - startTime
                print("⏱️ Performance Summary:")
                print("   • Manager creation: \(String(format: "%.2f", managerTime))s")
                print("   • Clustering analysis: \(String(format: "%.2f", clusteringTime))s")
                print("   • Data conversion: \(String(format: "%.3f", conversionTime))s")
                print("   • Total time: \(String(format: "%.2f", totalTime))s")
                print("   • Performance: \(String(format: "%.0f", Double(deviceData.count) / totalTime)) devices/sec")

                return SendableClusterResult(clusters: sendableClusters, region: mapUpdateRegion)

            } catch {
                let totalTime = CFAbsoluteTimeGetCurrent() - startTime
                print("❌ Clustering analysis failed after \(String(format: "%.2f", totalTime))s: \(error)")
                return SendableClusterResult(clusters: [], region: nil)
            }
        }.value

        // Update UI with sendable cluster data
        clusters = result.clusters
        if let region = result.region {
            mapRegion = region
        }

        // Store timing for UI display (extract from the result if available)
        // For now, we'll calculate it from the clustering operation
    }
}

// MARK: - Memory Management Extension
extension SpatialClusteringTestView {
    /// Clean up GPU resources when view disappears
    func cleanup() {
        clusters.removeAll()
        // Note: CoordinateTransformerManager handles GPU resource lifecycle
        print("🧹 SpatialClusteringTestView cleanup completed")
    }

    // MARK: - Data Filtering

    /// Filter devices based on current filter settings
    private var filteredDevices: [PowerSenseDevice] {
        var devices = powerSenseDevices.filter { device in
            // Must have valid location data
            device.latitude != 0.0 && device.longitude != 0.0
        }

        if showOnlyWithPowerData {
            devices = devices.filter { $0.hasPowerStatusData }
        }

        if showOnlyOffline {
            devices = devices.filter { $0.isOffline == true }
        }

        return devices
    }
//
    /// Count of offline devices in filtered set
    private var offlineDeviceCount: Int {
        filteredDevices.filter { $0.isOffline == true }.count
    }

    /// Refresh PowerSense data
    private func refreshData() {
        // Trigger SwiftData refresh by updating the view
        // The @Query will automatically refresh when the underlying data changes
        testCompleted = false
        clusters.removeAll()
        testOutput = "Data refreshed. \(filteredDevices.count) PowerSense devices available."
    }

    /// Convert cluster severity to string
    private func severityToString(_ severity: DeviceCluster.ClusterSeverity) -> String {
        switch severity {
        case .critical: return "critical"
        case .major: return "major"
        case .moderate: return "moderate"
        case .minor: return "minor"
        }
    }

}

struct ClusterSummaryCard: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color(.gray))
        .cornerRadius(6)
        .shadow(radius: 1)
    }
}

struct ClusterAnnotationView: View {
    fileprivate let cluster: SendableDeviceCluster

    private var color: Color {
        switch cluster.clusterSeverity {
        case .critical: return .red
        case .major: return .orange
        case .moderate: return .yellow
        case .minor: return .blue
        }
    }

    private var size: CGFloat {
        switch cluster.clusterSeverity {
        case .critical: return 32
        case .major: return 28
        case .moderate: return 24
        case .minor: return 20
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: size * 2, height: size * 2)

            Circle()
                .fill(color)
                .frame(width: size, height: size)

            Text("\(cluster.deviceCount)")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

#Preview {
    SpatialClusteringTestView()
}
