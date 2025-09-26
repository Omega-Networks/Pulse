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

struct SpatialClusteringTestView: View {
    @State private var isRunning = false
    @State private var testOutput: String = ""
    @State private var testCompleted = false
    @State private var clusters: [DeviceCluster] = []
    @State private var showMap = false
    @State private var selectedClusterSeverity: DeviceCluster.ClusterSeverity? = nil
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4)
    )

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
                }
                .padding()
            }

            Spacer()

            VStack(spacing: 12) {
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
                    .background(isRunning ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(isRunning)
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
                    Annotation("\(cluster.devices.count) devices", coordinate: clusterCoordinate(cluster)) {
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

    private var filteredClusters: [DeviceCluster] {
        guard let severity = selectedClusterSeverity else { return clusters }
        return clusters.filter { $0.severity == severity }
    }

    private func clusterCoordinate(_ cluster: DeviceCluster) -> CLLocationCoordinate2D {
        // Use pre-computed coordinate to avoid any GPU transformations during map rendering
        return cluster.centroidCoordinate
    }

    private func clusterCount(for severity: DeviceCluster.ClusterSeverity) -> Int {
        clusters.filter { $0.severity == severity }.count
    }

    private func runTest() {
        isRunning = true
        testOutput = ""
        testCompleted = false
        clusters = []

        Task {
            // Run the actual clustering analysis
            await performClusteringAnalysis()

            await MainActor.run {
                self.testOutput = """
                ✅ Spatial Clustering Analysis Complete!

                Results:
                - Found \(self.clusters.count) outage clusters
                - Critical: \(self.clusterCount(for: .critical))
                - Major: \(self.clusterCount(for: .major))
                - Moderate: \(self.clusterCount(for: .moderate))
                - Minor: \(self.clusterCount(for: .minor))

                The clustering system has successfully analyzed PowerSense device outages and identified spatial patterns. Click "View Cluster Map" to visualize the results.

                🎯 Ready for real-time outage detection and visualization!
                """
                self.isRunning = false
                self.testCompleted = true
            }
        }
    }

    private func performClusteringAnalysis() async {
        do {
            // Generate test dataset
            let devices = generateMockPowerSenseDevices()

            // Create clustering manager
            let manager = try OutageClusteringManager(projectionSystem: .nztm2000)

            // Define test viewport (Wellington region)
            let wellingtonCenter = CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762)
            let span = MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.3)
            let region = MKCoordinateRegion(center: wellingtonCenter, span: span)
            let viewport = MKMapRect(region)

            // Perform clustering
            let foundClusters = try await manager.clusterDevicesInViewport(
                devices: devices,
                viewport: viewport,
                paddingKm: 10.0,
                clusteringParameters: .suburban
            )

            await MainActor.run {
                self.clusters = foundClusters
            }

        } catch {
            print("Clustering analysis failed: \(error)")
        }
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
    let cluster: DeviceCluster

    private var color: Color {
        switch cluster.severity {
        case .critical: return .red
        case .major: return .orange
        case .moderate: return .yellow
        case .minor: return .blue
        }
    }

    private var size: CGFloat {
        switch cluster.severity {
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

            Text("\(cluster.devices.count)")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

#Preview {
    SpatialClusteringTestView()
}
