//
//  SpatialClusteringActor.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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

import Foundation
import SwiftData
import MapKit
import CoreLocation
import OSLog

// MARK: - Simple Results

struct ClusterResult: Sendable {
    let clusters: [SimpleCluster]
    let totalDevices: Int
    let offlineDevices: Int
    let processingTime: Double
}

struct SimpleCluster: Sendable, Identifiable {
    let id: Int
    let deviceCount: Int
    let latitude: Double
    let longitude: Double
    let severity: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var color: String {
        switch severity {
        case "critical": return "red"
        case "major": return "orange"
        case "moderate": return "yellow"
        default: return "blue"
        }
    }
}

// MARK: - Spatial Clustering Actor

/// Modern GPU-accelerated actor for spatial clustering of any SpatialDevice data
actor SpatialClusteringActor {

    private let modelContainer: ModelContainer
    private let config: SpatialClusteringConfig
    private let indexer: GPUSpatialIndexManager<PowerSenseDeviceDTO>
    private let logger = Logger.spatialClustering

    init(
        modelContainer: ModelContainer,
        config: SpatialClusteringConfig = .default,
        transformer: CoordinateTransformer
    ) {
        self.modelContainer = modelContainer
        self.config = config
        self.indexer = GPUSpatialIndexManager(transformer: transformer)

        logger.info("🌍 GPU-only SpatialClusteringActor initialized")
    }

    /// Convenience initializer that creates its own transformer
    init(
        modelContainer: ModelContainer,
        config: SpatialClusteringConfig = .default
    ) throws {
        let transformer = try CoordinateTransformer(projectionSystem: config.projectionSystem)
        self.init(modelContainer: modelContainer, config: config, transformer: transformer)
    }

    // MARK: - Public Interface

    /// Modern GPU-accelerated clustering for all devices
    func clusterAllDevices() async throws -> ClusterResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("🚀 Starting GPU-accelerated clustering")

        // Validate configuration
        try config.clusteringParameters.validate()

        // Query all devices and convert to DTOs
        let devices = try await getSpatialDeviceDTOs()
        let offlineCount = devices.filter { $0.isOffline == true }.count

        logger.info("📊 Found \(devices.count) devices, \(offlineCount) offline")

        guard offlineCount >= config.clusteringParameters.minPoints else {
            throw ClusteringError.insufficientData(deviceCount: offlineCount, minimum: config.clusteringParameters.minPoints)
        }

        // Build GPU spatial index
        try await indexer.buildIndex(devices: devices)

        // Perform clustering using GPU-accelerated approach
        let clusters = try await performModernClustering(devices: devices)

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("✅ Clustering completed in \(String(format: "%.3f", processingTime))s")

        return ClusterResult(
            clusters: clusters,
            totalDevices: devices.count,
            offlineDevices: offlineCount,
            processingTime: processingTime
        )
    }

    /// Get all spatial devices as DTOs - converts SwiftData models to Sendable DTOs
    func getSpatialDeviceDTOs() async throws -> [PowerSenseDeviceDTO] {
        let modelContext = ModelContext(modelContainer)

        var descriptor = FetchDescriptor<PowerSenseDevice>(
            sortBy: [SortDescriptor(\.deviceId)]
        )
        descriptor.fetchLimit = config.clusteringParameters.maxDevices

        let devices = try modelContext.fetch(descriptor)
        logger.debug("📱 Fetched \(devices.count) PowerSenseDevice devices")

        return devices.map { $0.toDTO() }
    }

    /// Query devices within a specific region (viewport-based clustering)
    func clusterDevicesInRegion(_ region: GeographicBounds) async throws -> ClusterResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("🗺️ Starting regional clustering")

        try config.clusteringParameters.validate()

        let devices = try await getSpatialDeviceDTOs()
        let regionDevices = devices.filter { device in
            let coordinate = CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
            return region.contains(coordinate)
        }

        let offlineCount = regionDevices.filter { $0.isOffline == true }.count
        logger.info("📍 Found \(regionDevices.count) devices in region, \(offlineCount) offline")

        guard !regionDevices.isEmpty else {
            return ClusterResult(clusters: [], totalDevices: 0, offlineDevices: 0, processingTime: 0)
        }

        // Build index and cluster
        try await indexer.buildIndex(devices: regionDevices)
        let clusters = try await performModernClustering(devices: regionDevices)

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("✅ Regional clustering completed in \(String(format: "%.3f", processingTime))s")

        return ClusterResult(
            clusters: clusters,
            totalDevices: regionDevices.count,
            offlineDevices: offlineCount,
            processingTime: processingTime
        )
    }

    // MARK: - Private Methods

    /// Modern GPU-accelerated clustering implementation
    private func performModernClustering(devices: [PowerSenseDeviceDTO]) async throws -> [SimpleCluster] {
        logger.debug("🔬 Performing GPU-accelerated clustering on \(devices.count) devices")

        // Filter to offline devices only for clustering
        let offlineDevices = devices.filter { $0.isOffline == true }

        guard !offlineDevices.isEmpty else {
            logger.info("ℹ️ No offline devices found - returning empty cluster set")
            return []
        }

        // Use DBSCAN approach: find density-connected components
        var clusters: [SimpleCluster] = []
        var visitedDevices: Set<String> = []
        var clusterId = 0

        for device in offlineDevices {
            guard !visitedDevices.contains(device.deviceId) else { continue }

            // Find all neighbors within epsilon
            let neighbors = try await indexer.findNeighbors(
                for: device.deviceId,
                within: config.clusteringParameters.epsilon
            )

            // Check if this forms a cluster (minimum points requirement)
            if neighbors.count >= config.clusteringParameters.minPoints {
                // Expand cluster using density-connectivity
                let clusterDevices = try await expandCluster(
                    from: device,
                    neighbors: neighbors,
                    visited: &visitedDevices
                )

                // Apply privacy aggregation threshold
                if clusterDevices.count >= config.clusteringParameters.aggregationThreshold {
                    let cluster = createSimpleCluster(
                        id: clusterId,
                        devices: clusterDevices
                    )
                    clusters.append(cluster)
                    clusterId += 1

                    logger.debug("✅ Created cluster \(clusterId-1) with \(clusterDevices.count) devices")
                } else {
                    logger.debug("🔒 Cluster with \(clusterDevices.count) devices below aggregation threshold - filtered for privacy")
                }
            }
        }

        logger.info("📊 Generated \(clusters.count) clusters from \(offlineDevices.count) offline devices")
        return clusters
    }


    /// Expand cluster using density-connectivity (DBSCAN algorithm)
    private func expandCluster(
        from seed: PowerSenseDeviceDTO,
        neighbors: [PowerSenseDeviceDTO],
        visited: inout Set<String>
    ) async throws -> [PowerSenseDeviceDTO] {
        var cluster: [PowerSenseDeviceDTO] = [seed]
        var queue = Array(neighbors)
        visited.insert(seed.deviceId)

        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard !visited.contains(current.deviceId) else { continue }

            visited.insert(current.deviceId)
            cluster.append(current)

            // Find neighbors of this point
            let currentNeighbors = try await indexer.findNeighbors(
                for: current.deviceId,
                within: config.clusteringParameters.epsilon
            )

            // If this is also a core point, add its neighbors to expansion queue
            if currentNeighbors.count >= config.clusteringParameters.minPoints {
                for neighbor in currentNeighbors {
                    if !visited.contains(neighbor.deviceId) {
                        queue.append(neighbor)
                    }
                }
            }
        }

        return cluster
    }

    /// Create a SimpleCluster from a list of devices
    private func createSimpleCluster(id: Int, devices: [any SpatialDevice]) -> SimpleCluster {
        // Calculate centroid
        let avgLat = devices.map { $0.latitude }.reduce(0, +) / Double(devices.count)
        let avgLon = devices.map { $0.longitude }.reduce(0, +) / Double(devices.count)

        // Determine severity based on device count
        let severity: String
        switch devices.count {
        case 200...: severity = "critical"
        case 50..<200: severity = "major"
        case 10..<50: severity = "moderate"
        default: severity = "minor"
        }

        return SimpleCluster(
            id: id,
            deviceCount: devices.count,
            latitude: avgLat,
            longitude: avgLon,
            severity: severity
        )
    }

    // MARK: - Performance and Diagnostics

    /// Get current performance metrics from GPU indexer
    func getIndexerPerformanceMetrics() async -> SpatialIndexMetrics {
        return await indexer.performanceMetrics
    }

    /// Check if GPU indexer is ready for clustering operations
    func isIndexerReady() async -> Bool {
        return await indexer.isIndexReady
    }

    /// Get device count currently indexed
    func getIndexedDeviceCount() async -> Int {
        return await indexer.deviceCount
    }
}
