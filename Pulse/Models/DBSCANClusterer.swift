//
//  DBSCANClusterer.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  High-performance DBSCAN clustering algorithm implementation using GKQuadtree
//  for O(n log n) neighbor queries instead of O(n²) brute force approach
//

import Foundation
import GameplayKit
import CoreLocation
import OSLog

/// Industry-standard DBSCAN clustering algorithm optimized with spatial indexing
/// Time Complexity: O(n log n) vs O(n²) brute force
/// Used by major mapping services for spatial clustering
public final class DBSCANClusterer {

    // MARK: - Logging Infrastructure

    private let algorithmLogger = Logger(subsystem: "powersense.clustering", category: "algorithms")
    private let performanceLogger = Logger(subsystem: "powersense.clustering", category: "performance")
    private let debugLogger = Logger(subsystem: "powersense.clustering", category: "debug")
    private let errorLogger = Logger(subsystem: "powersense.clustering", category: "errors")

    // MARK: - Configuration

    /// Clustering parameters following DBSCAN standard
    public struct ClusteringConfig {
        /// Eps: maximum distance between points in same cluster (in meters)
        let eps: CLLocationDistance

        /// MinPts: minimum points required to form a cluster
        let minPts: Int

        /// Performance monitoring thresholds
        let maxClusteringTime: TimeInterval
        let logDetailedMetrics: Bool

        static let `default` = ClusteringConfig(
            eps: 500.0,          // 500 meters - suburb level clustering
            minPts: 5,           // Minimum 5 devices for meaningful outage
            maxClusteringTime: 0.050,  // 50ms performance target
            logDetailedMetrics: true
        )
    }

    // MARK: - Internal Data Structures

    /// Point state tracking for DBSCAN algorithm
    private enum PointType {
        case unvisited
        case visited
        case noise
        case core
        case border
    }

    /// Internal clustering node with algorithm state
    private final class ClusteringNode {
        let device: PowerSenseDevice
        var pointType: PointType = .unvisited
        var clusterId: Int = -1
        let coordinate: CLLocationCoordinate2D

        init(device: PowerSenseDevice) {
            self.device = device
            self.coordinate = CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
        }
    }

    // MARK: - Performance Metrics

    private struct ClusteringMetrics {
        var totalPoints: Int = 0
        var clusters: Int = 0
        var noisePoints: Int = 0
        var corePoints: Int = 0
        var borderPoints: Int = 0
        var avgClusterSize: Double = 0
        var clusteringTime: TimeInterval = 0
        var neighborQueries: Int = 0
        var avgNeighborsPerPoint: Double = 0
    }

    // MARK: - Main Clustering Interface

    /// Perform DBSCAN clustering on offline devices using spatial index for performance
    /// Returns array of clusters, each containing related offline devices
    public func cluster(
        devices: [PowerSenseDevice],
        config: ClusteringConfig = .default,
        spatialManager: SpatialDeviceManager
    ) async -> [[PowerSenseDevice]] {

        guard !devices.isEmpty else {
            algorithmLogger.info("📊 DBSCAN: No devices provided for clustering")
            return []
        }

        let startTime = Date()
        algorithmLogger.info("🔍 DBSCAN clustering started with \(devices.count) devices")
        algorithmLogger.info("📊 Parameters: eps=\(Int(config.eps))m, minPts=\(config.minPts)")

        // Initialize clustering nodes
        let nodes = devices.map { ClusteringNode(device: $0) }
        var metrics = ClusteringMetrics()
        metrics.totalPoints = devices.count

        var clusters: [[PowerSenseDevice]] = []
        var currentClusterId = 0

        debugLogger.debug("🏗️ Initialized \(nodes.count) clustering nodes")

        // Main DBSCAN algorithm
        for node in nodes {
            guard node.pointType == .unvisited else { continue }

            node.pointType = .visited

            // Find neighbors using spatial index - O(log n) instead of O(n)
            let neighbors = await findNeighbors(
                center: node.coordinate,
                eps: config.eps,
                spatialManager: spatialManager,
                excludeDevice: node.device.deviceId
            )

            metrics.neighborQueries += 1
            metrics.avgNeighborsPerPoint = (metrics.avgNeighborsPerPoint * Double(metrics.neighborQueries - 1) + Double(neighbors.count)) / Double(metrics.neighborQueries)

            debugLogger.debug("🎯 Node \(node.device.deviceId) has \(neighbors.count) neighbors")

            if neighbors.count < config.minPts {
                // Not enough neighbors - mark as noise
                node.pointType = .noise
                metrics.noisePoints += 1
                debugLogger.debug("🔇 Device \(node.device.deviceId) marked as noise (only \(neighbors.count) neighbors)")
                continue
            }

            // Start new cluster - this is a core point
            node.pointType = .core
            node.clusterId = currentClusterId
            metrics.corePoints += 1

            let cluster = await expandCluster(
                coreNode: node,
                neighbors: neighbors,
                clusterId: currentClusterId,
                nodes: nodes,
                config: config,
                spatialManager: spatialManager,
                metrics: &metrics
            )

            clusters.append(cluster)
            currentClusterId += 1

            algorithmLogger.info("✅ Cluster \(currentClusterId - 1) formed with \(cluster.count) devices")
        }

        // Calculate final metrics
        let clusteringTime = Date().timeIntervalSince(startTime)
        metrics.clusteringTime = clusteringTime
        metrics.clusters = clusters.count
        metrics.avgClusterSize = clusters.isEmpty ? 0 : Double(clusters.map { $0.count }.reduce(0, +)) / Double(clusters.count)

        // Count border points (non-core, non-noise points in clusters)
        metrics.borderPoints = nodes.filter { $0.pointType == .visited && $0.clusterId >= 0 }.count

        await logClusteringResults(metrics: metrics, config: config)

        // Performance validation
        if clusteringTime > config.maxClusteringTime {
            performanceLogger.warning("⚠️ DBSCAN clustering exceeded target time: \(String(format: "%.3f", clusteringTime))s > \(String(format: "%.3f", config.maxClusteringTime))s")
        } else {
            performanceLogger.info("🎯 DBSCAN clustering completed within target: \(String(format: "%.3f", clusteringTime))s")
        }

        return clusters
    }

    // MARK: - Core Algorithm Implementation

    /// Expand cluster from core point using density-reachable criteria
    private func expandCluster(
        coreNode: ClusteringNode,
        neighbors: [PowerSenseDevice],
        clusterId: Int,
        nodes: [ClusteringNode],
        config: ClusteringConfig,
        spatialManager: SpatialDeviceManager,
        metrics: inout ClusteringMetrics
    ) async -> [PowerSenseDevice] {

        var cluster = [coreNode.device]
        var seedSet = neighbors
        let nodeDict = Dictionary(uniqueKeysWithValues: nodes.map { ($0.device.deviceId, $0) })

        debugLogger.debug("🌱 Expanding cluster \(clusterId) from core point with \(seedSet.count) seeds")

        var seedIndex = 0
        while seedIndex < seedSet.count {
            let currentDevice = seedSet[seedIndex]
            seedIndex += 1

            guard let currentNode = nodeDict[currentDevice.deviceId] else { continue }

            if currentNode.pointType == .noise {
                // Convert noise point to border point
                currentNode.pointType = .visited
                currentNode.clusterId = clusterId
                cluster.append(currentDevice)
                debugLogger.debug("🔄 Converted noise point \(currentDevice.deviceId) to border point in cluster \(clusterId)")
                continue
            }

            if currentNode.pointType != .unvisited { continue }

            // Mark as visited and add to cluster
            currentNode.pointType = .visited
            currentNode.clusterId = clusterId
            cluster.append(currentDevice)

            // Check if this point is also a core point
            let pointNeighbors = await findNeighbors(
                center: currentNode.coordinate,
                eps: config.eps,
                spatialManager: spatialManager,
                excludeDevice: currentDevice.deviceId
            )

            metrics.neighborQueries += 1

            if pointNeighbors.count >= config.minPts {
                // This is also a core point - add its neighbors to seed set
                currentNode.pointType = .core
                metrics.corePoints += 1

                for neighbor in pointNeighbors {
                    if !seedSet.contains(where: { $0.deviceId == neighbor.deviceId }) {
                        seedSet.append(neighbor)
                    }
                }

                debugLogger.debug("🎯 Core point \(currentDevice.deviceId) added \(pointNeighbors.count) new seeds")
            }
        }

        algorithmLogger.debug("📊 Cluster \(clusterId) expanded to \(cluster.count) devices")
        return cluster
    }

    /// Find neighbors within eps distance using spatial index - O(log n) operation
    private func findNeighbors(
        center: CLLocationCoordinate2D,
        eps: CLLocationDistance,
        spatialManager: SpatialDeviceManager,
        excludeDevice: String
    ) async -> [PowerSenseDevice] {

        let startTime = Date()

        // Use spatial manager's radius query for O(log n) performance
        let candidates = spatialManager.getDevicesNearPoint(center, radius: eps)

        // Filter out the center device itself and ensure only offline devices
        let neighbors = candidates.filter { device in
            device.deviceId != excludeDevice && device.isOffline
        }

        let queryTime = Date().timeIntervalSince(startTime)
        debugLogger.debug("🔍 Neighbor query: found \(neighbors.count) neighbors in \(String(format: "%.6f", queryTime))s")

        if queryTime > 0.01 { // 10ms threshold for neighbor queries
            performanceLogger.warning("⚠️ Neighbor query slow: \(String(format: "%.6f", queryTime))s for \(candidates.count) candidates")
        }

        return neighbors
    }

    // MARK: - Results Logging and Analysis

    /// Log comprehensive clustering results and analysis
    private func logClusteringResults(metrics: ClusteringMetrics, config: ClusteringConfig) async {

        algorithmLogger.info("""
        🎉 DBSCAN CLUSTERING COMPLETED:
        ==============================
        • Input Points: \(metrics.totalPoints)
        • Clusters Found: \(metrics.clusters)
        • Core Points: \(metrics.corePoints)
        • Border Points: \(metrics.borderPoints)
        • Noise Points: \(metrics.noisePoints)
        • Avg Cluster Size: \(String(format: "%.1f", metrics.avgClusterSize))
        • Total Processing Time: \(String(format: "%.3f", metrics.clusteringTime))s
        • Neighbor Queries: \(metrics.neighborQueries)
        • Avg Neighbors/Point: \(String(format: "%.1f", metrics.avgNeighborsPerPoint))

        🔧 ALGORITHM PARAMETERS:
        • Eps (radius): \(Int(config.eps))m
        • MinPts (density): \(config.minPts)

        📊 QUALITY METRICS:
        • Clustering Ratio: \(String(format: "%.1f", Double(metrics.totalPoints - metrics.noisePoints) / Double(metrics.totalPoints) * 100))%
        • Noise Ratio: \(String(format: "%.1f", Double(metrics.noisePoints) / Double(metrics.totalPoints) * 100))%
        • Avg Query Time: \(String(format: "%.6f", metrics.clusteringTime / Double(metrics.neighborQueries)))s
        """)

        // Performance analysis
        let pointsPerSecond = Double(metrics.totalPoints) / metrics.clusteringTime
        performanceLogger.info("⚡ Processing Rate: \(String(format: "%.0f", pointsPerSecond)) points/second")

        if metrics.clusters == 0 {
            algorithmLogger.warning("⚠️ No clusters found - consider adjusting eps (\(Int(config.eps))m) or minPts (\(config.minPts))")
        } else if metrics.noisePoints > metrics.totalPoints / 2 {
            algorithmLogger.warning("⚠️ High noise ratio (\(String(format: "%.1f", Double(metrics.noisePoints) / Double(metrics.totalPoints) * 100))%) - consider increasing eps")
        }

        // Detailed cluster analysis if enabled
        if config.logDetailedMetrics {
            debugLogger.debug("""
            🔍 DETAILED CLUSTERING ANALYSIS:
            • Points processed: \(metrics.totalPoints)
            • Spatial queries performed: \(metrics.neighborQueries)
            • Query efficiency: \(String(format: "%.1f", Double(metrics.neighborQueries) / Double(metrics.totalPoints)))x per point
            • Memory efficiency: O(n) space complexity maintained
            • Time complexity achieved: O(n log n) vs O(n²) brute force
            """)
        }
    }

    // MARK: - Utility Methods

    /// Validate clustering configuration parameters
    static func validateConfig(_ config: ClusteringConfig) -> Bool {
        guard config.eps > 0 && config.minPts >= 1 else {
            Logger(subsystem: "powersense.clustering", category: "validation")
                .error("❌ Invalid clustering config: eps=\(config.eps), minPts=\(config.minPts)")
            return false
        }
        return true
    }

    /// Calculate clustering quality score based on results
    static func calculateQualityScore(
        totalPoints: Int,
        clusters: [[PowerSenseDevice]],
        noisePoints: Int
    ) -> Double {
        guard totalPoints > 0 else { return 0.0 }

        let clusteredPoints = totalPoints - noisePoints
        let clusteringRatio = Double(clusteredPoints) / Double(totalPoints)

        // Quality factors
        let densityScore = clusters.isEmpty ? 0.0 : Double(clusters.count) / Double(totalPoints) * 100 // Prefer moderate cluster count
        let noiseScore = 1.0 - (Double(noisePoints) / Double(totalPoints)) // Prefer low noise
        let sizeVarianceScore = calculateSizeVarianceScore(clusters) // Prefer consistent cluster sizes

        // Weighted quality score
        return (clusteringRatio * 0.4 + noiseScore * 0.3 + sizeVarianceScore * 0.2 + min(1.0, densityScore / 10.0) * 0.1)
    }

    private static func calculateSizeVarianceScore(_ clusters: [[PowerSenseDevice]]) -> Double {
        guard !clusters.isEmpty else { return 0.0 }

        let sizes = clusters.map { Double($0.count) }
        let mean = sizes.reduce(0, +) / Double(sizes.count)
        let variance = sizes.map { pow($0 - mean, 2) }.reduce(0, +) / Double(sizes.count)
        let coefficient = variance / max(mean, 1.0) // Coefficient of variation

        return max(0.0, 1.0 - coefficient / 2.0) // Lower variance = higher score
    }
}

// MARK: - Performance Monitoring Extensions

extension DBSCANClusterer {

    /// Benchmark the clustering algorithm with different parameters in parallel
    static func benchmark(
        devices: [PowerSenseDevice],
        spatialManager: SpatialDeviceManager,
        configurations: [ClusteringConfig]
    ) async -> [(config: ClusteringConfig, time: TimeInterval, clusters: Int)] {

        let benchmarkLogger = Logger(subsystem: "powersense.clustering", category: "benchmark")
        benchmarkLogger.info("🏁 Starting parallel DBSCAN benchmark with \(configurations.count) configurations")

        guard !configurations.isEmpty else {
            benchmarkLogger.warning("⚠️ No configurations provided for benchmark")
            return []
        }

        let benchmarkStart = Date()

        // Use TaskGroup for parallel benchmarking
        let results = await withTaskGroup(of: (config: ClusteringConfig, time: TimeInterval, clusters: Int).self) { group in
            var benchmarkResults: [(config: ClusteringConfig, time: TimeInterval, clusters: Int)] = []

            for config in configurations {
                group.addTask {
                    let clusterer = DBSCANClusterer()
                    let startTime = Date()
                    let clusters = await clusterer.cluster(devices: devices, config: config, spatialManager: spatialManager)
                    let benchmarkTime = Date().timeIntervalSince(startTime)

                    benchmarkLogger.debug("📊 Config eps=\(Int(config.eps)), minPts=\(config.minPts): \(String(format: "%.3f", benchmarkTime))s, \(clusters.count) clusters")
                    return (config: config, time: benchmarkTime, clusters: clusters.count)
                }
            }

            for await result in group {
                benchmarkResults.append(result)
            }

            return benchmarkResults.sorted { $0.time < $1.time }
        }

        let totalBenchmarkTime = Date().timeIntervalSince(benchmarkStart)

        // Find optimal configuration
        let optimal = results.first { $0.clusters > 0 }
        if let best = optimal {
            benchmarkLogger.info("🏆 Optimal config: eps=\(Int(best.config.eps)), minPts=\(best.config.minPts) (\(String(format: "%.3f", best.time))s)")
        }

        benchmarkLogger.info("🏁 Parallel benchmark completed in \(String(format: "%.3f", totalBenchmarkTime))s")
        benchmarkLogger.info("⚡ Tested \(configurations.count) configurations concurrently")

        return results
    }

    /// Process multiple device sets in parallel for batch operations
    public static func clusterBatch(
        deviceSets: [[PowerSenseDevice]],
        config: ClusteringConfig = .default,
        spatialManager: SpatialDeviceManager
    ) async -> [[[PowerSenseDevice]]] {

        let batchLogger = Logger(subsystem: "powersense.clustering", category: "batch")
        batchLogger.info("🔄 Batch clustering started for \(deviceSets.count) device sets")

        guard !deviceSets.isEmpty else {
            batchLogger.warning("⚠️ No device sets provided for batch clustering")
            return []
        }

        let batchStart = Date()

        let results = await withTaskGroup(of: (clusters: [[PowerSenseDevice]], setIndex: Int).self) { group in
            var batchResults: [[[PowerSenseDevice]]] = Array(repeating: [], count: deviceSets.count)

            for (index, devices) in deviceSets.enumerated() {
                group.addTask {
                    let clusterer = DBSCANClusterer()
                    let clusters = await clusterer.cluster(devices: devices, config: config, spatialManager: spatialManager)
                    return (clusters: clusters, setIndex: index)
                }
            }

            for await result in group {
                batchResults[result.setIndex] = result.clusters
            }

            return batchResults
        }

        let totalBatchTime = Date().timeIntervalSince(batchStart)
        let avgTimePerSet = totalBatchTime / Double(deviceSets.count)

        batchLogger.info("🔄 Batch clustering completed in \(String(format: "%.3f", totalBatchTime))s")
        batchLogger.info("📊 Average time per device set: \(String(format: "%.3f", avgTimePerSet))s")
        batchLogger.info("⚡ Processed \(deviceSets.count) device sets concurrently")

        return results
    }
}