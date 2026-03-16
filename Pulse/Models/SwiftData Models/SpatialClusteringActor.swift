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

struct ClusterResult: Sendable, Equatable {
    let clusters: [DeviceCluster]
    let totalDevices: Int
    let offlineDevices: Int
    let processingTime: Double
    let totalEvents: Int
    let activeEvents: Int

    static func == (lhs: ClusterResult, rhs: ClusterResult) -> Bool {
        // Compare counts for change detection (skip deep cluster comparison for performance)
        return lhs.totalDevices == rhs.totalDevices &&
               lhs.offlineDevices == rhs.offlineDevices &&
               lhs.totalEvents == rhs.totalEvents &&
               lhs.activeEvents == rhs.activeEvents &&
               lhs.clusters.count == rhs.clusters.count
    }
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

/// Helper struct for coordinate deduplication in convex hull computation
private struct PointKey: Hashable, Sendable {
    let coord: CLLocationCoordinate2D

    func hash(into hasher: inout Hasher) {
        // Use fixed precision for floating point comparison
        let latFixed = Int(coord.latitude * 1000000) // 6 decimal places
        let lonFixed = Int(coord.longitude * 1000000)
        hasher.combine(latFixed)
        hasher.combine(lonFixed)
    }

    static func == (lhs: PointKey, rhs: PointKey) -> Bool {
        return abs(lhs.coord.latitude - rhs.coord.latitude) < 1e-6 &&
               abs(lhs.coord.longitude - rhs.coord.longitude) < 1e-6
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

        // Query events for stats
        let (totalEvents, activeEvents) = try await getEventStats()

        logger.info("📊 Found \(devices.count) devices, \(offlineCount) offline")
        logger.info("📊 Found \(totalEvents) events, \(activeEvents) active")

        // If no offline devices, return empty result (valid state - all devices online)
        guard offlineCount >= config.clusteringParameters.minPoints else {
            let processingTime = CFAbsoluteTimeGetCurrent() - startTime
            logger.info("✅ No offline devices - returning empty clusters (all devices online)")
            return ClusterResult(
                clusters: [],
                totalDevices: devices.count,
                offlineDevices: offlineCount,
                processingTime: processingTime,
                totalEvents: totalEvents,
                activeEvents: activeEvents
            )
        }

        // Build GPU spatial index
        try await indexer.buildIndex(devices: devices)

        // Perform clustering using GPU-accelerated approach
        let clusters = try await performClustering(devices: devices)

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("✅ Clustering completed in \(String(format: "%.3f", processingTime))s")

        return ClusterResult(
            clusters: clusters,
            totalDevices: devices.count,
            offlineDevices: offlineCount,
            processingTime: processingTime,
            totalEvents: totalEvents,
            activeEvents: activeEvents
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

    /// Get event statistics for display
    private func getEventStats() async throws -> (totalEvents: Int, activeEvents: Int) {
        let modelContext = ModelContext(modelContainer)

        let descriptor = FetchDescriptor<PowerSenseEvent>()
        let events = try modelContext.fetch(descriptor)

        let activeCount = events.filter { $0.isActive }.count

        logger.debug("📊 Fetched \(events.count) events, \(activeCount) active")

        return (events.count, activeCount)
    }

   
    // MARK: - Private Methods

    /// GPU-accelerated clustering implementation using DBSCAN
    private func performClustering(devices: [PowerSenseDeviceDTO]) async throws -> [DeviceCluster] {
        logger.debug("🔬 Performing GPU-accelerated DBSCAN clustering on \(devices.count) devices")

        // Filter to offline devices only for clustering
        let offlineDevices = devices.filter { $0.isOffline == true }

        guard !offlineDevices.isEmpty else {
            logger.info("ℹ️ No offline devices found - returning empty cluster set")
            return []
        }

        logger.info("🧠 Using GPU DBSCAN for \(offlineDevices.count) offline devices")

        // Get GPU buffers from the spatial index
        guard let gridParams = await indexer.getGridParameters(),
              let gpuGrid = await indexer.getGPUGrid(),
              let coordsBuffer = await indexer.getGPUCoordsBuffer(),
              let offlineFlagsBuffer = await indexer.getGPUOfflineFlagsBuffer() else {
            throw ClusteringError.clusteringFailed("Failed to access GPU buffers on Apple Silicon")
        }

        // Get the transformer from indexer for GPU DBSCAN
        let transformer = await indexer.getTransformer()

        // Configure DBSCAN parameters from config
        let dbscanParams = DBSCANParameters(
            epsilon: config.clusteringParameters.epsilon,
            minPoints: config.clusteringParameters.minPoints,
            aggregationThreshold: config.clusteringParameters.aggregationThreshold
        )

        // Perform GPU DBSCAN clustering
        let dbscanResult = try transformer.performGPUDBSCAN(
            coordsBuffer: coordsBuffer.buffer,
            offlineFlagsBuffer: offlineFlagsBuffer.buffer,
            grid: gpuGrid,
            gridParams: gridParams,
            dbscanParams: dbscanParams,
            deviceCount: devices.count
        )

        logger.info("🚀 GPU DBSCAN completed: \(dbscanResult.clusterCount) clusters, \(dbscanResult.iterations) iterations, \(String(format: "%.3f", dbscanResult.processingTime * 1000))ms")

        // Generate hull and confidence for visualization
        let clustersWithPolygons = try await generateClustersWithHullsAndConfidence(
            dbscanResult: dbscanResult,
            devices: devices,
            transformer: transformer,
            coordsBuffer: coordsBuffer,
            offlineFlagsBuffer: offlineFlagsBuffer,
            gridParams: gridParams,
            gpuGrid: gpuGrid,
            aggregationThreshold: config.clusteringParameters.aggregationThreshold
        )

        return clustersWithPolygons
    }


    /// Generate clusters with convex hull polygons and confidence scores (CPU-based)
    private func generateClustersWithHullsAndConfidence(
        dbscanResult: DBSCANResult,
        devices: [PowerSenseDeviceDTO],
        transformer: CoordinateTransformer,
        coordsBuffer: SendableBuffer,
        offlineFlagsBuffer: SendableBuffer,
        gridParams: GridIndexParameters,
        gpuGrid: GPUGrid,
        aggregationThreshold: Int
    ) async throws -> [DeviceCluster] {

        logger.info("🔺 Phase 3: Starting CPU-based hull & confidence generation")

        // Group devices by cluster label
        var clusterDevicesMap: [Int32: [PowerSenseDeviceDTO]] = [:]

        for (index, device) in devices.enumerated() {
            let label = dbscanResult.labels[index]
            if device.isOffline == true && label != -1 {
                if clusterDevicesMap[label] == nil {
                    clusterDevicesMap[label] = []
                }
                clusterDevicesMap[label]?.append(device)
            }
        }

        // Filter clusters meeting aggregation threshold
        var validClusters: [(Int32, [PowerSenseDeviceDTO])] = []

        for (label, clusterDevices) in clusterDevicesMap {
            if clusterDevices.count >= aggregationThreshold {
                validClusters.append((label, clusterDevices))
            }
        }

        guard !validClusters.isEmpty else {
            logger.info("⚠️ No clusters meet aggregation threshold - returning empty")
            return []
        }

        logger.info("📊 Phase 3: Processing \(validClusters.count) clusters with CPU-based hull computation")

        // Apply sampling for very large clusters ONLY if necessary for hull vertex limits
        // Increased from 1000 to 5000 to preserve data integrity (senior engineer recommendation)
        let samplingThreshold = config.clusteringParameters.maxHullVertices * 10  // e.g., 500 * 10 = 5000
        let maxPointsPerCluster = validClusters.map { $0.1.count }.max() ?? 100

        logger.info("🔧 Max points per cluster: \(maxPointsPerCluster)")
        logger.info("🔧 Sampling threshold: \(samplingThreshold)")
        logger.info("🔧 Cluster sizes: \(validClusters.map { $0.1.count }.prefix(5).map(String.init).joined(separator: ", "))\(validClusters.count > 5 ? "..." : "")")

        let finalClusters = validClusters.map { (label, devices) in
            if devices.count > samplingThreshold {
                logger.info("🔧 Sampling cluster \(label): \(devices.count) → \(samplingThreshold) (farthest-point)")
                return (label, applySamplingToCluster(devices: devices, targetCount: samplingThreshold))
            } else {
                return (label, devices)
            }
        }

        // Phase A: Batch transform ALL cluster coordinates upfront (single GPU call)
        logger.info("🔧 Phase A: Batch transforming coordinates for all clusters...")
        let batchStartTime = CFAbsoluteTimeGetCurrent()

        var deviceToProjected: [String: ProjectedCoordinate] = [:]
        var allClusterCoordinates: [CLLocationCoordinate2D] = []

        for (_, clusterDevices) in finalClusters {
            for device in clusterDevices {
                let coord = CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
                allClusterCoordinates.append(coord)
            }
        }

        let allProjected = try transformer.batchTransform(allClusterCoordinates)

        // Build lookup map
        var coordIndex = 0
        for (_, clusterDevices) in finalClusters {
            for device in clusterDevices {
                deviceToProjected[device.deviceId] = allProjected[coordIndex]
                coordIndex += 1
            }
        }

        let batchTime = CFAbsoluteTimeGetCurrent() - batchStartTime
        logger.info("✅ Phase A: Batch transform complete in \(String(format: "%.1f", batchTime * 1000))ms")

        // Phase B: Process clusters in parallel using TaskGroup
        logger.info("🔧 Phase B: Parallel hull computation across \(finalClusters.count) clusters...")
        let hullStartTime = CFAbsoluteTimeGetCurrent()

        // Capture configuration to avoid actor isolation issues
        let useConcaveHull = config.clusteringParameters.useConcaveHull

        let enhancedClusters = try await withThrowingTaskGroup(of: DeviceCluster?.self) { group in
            for (clusterIndex, (_, clusterDevices)) in finalClusters.enumerated() {
                // Process each cluster in parallel
                group.addTask { [devices, deviceToProjected, transformer] in
                    // Extract pre-transformed coordinates from cache
                    let projectedCoordinates = clusterDevices.compactMap { deviceToProjected[$0.deviceId] }
                    guard projectedCoordinates.count == clusterDevices.count else {
                        self.logger.error("⚠️ Coordinate mismatch for cluster \(clusterIndex)")
                        return nil
                    }

                    let deviceCoordinates = clusterDevices.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

                    // Calculate dynamic concavity based on cluster size (more devices = tighter hull)
                    // Formula: alphaRadius = 300 - (200 * log10(deviceCount))
                    // Examples: 10 devices=300m, 100=100m, 1000=100m, 10000=50m
                    let deviceCount = Double(clusterDevices.count)
                    let dynamicConcavity: Double
                    if deviceCount <= 10 {
                        dynamicConcavity = 300.0  // Very small clusters: loose hull
                    } else if deviceCount >= 10000 {
                        dynamicConcavity = 50.0   // Very large clusters: tight hull
                    } else {
                        // Logarithmic scale between 10 and 10000 devices
                        let logScale = log10(deviceCount / 10.0) / log10(10000.0 / 10.0)  // 0.0 to 1.0
                        dynamicConcavity = 300.0 - (250.0 * logScale)  // 300m → 50m
                    }

                    // Compute hull in projected metric space (concave or convex based on config)
                    let hullVertices: [CLLocationCoordinate2D]
                    if useConcaveHull {
                        hullVertices = try self.computeConcaveHull(
                            projectedCoordinates: projectedCoordinates,
                            concavity: dynamicConcavity,
                            transformer: transformer
                        )
                    } else {
                        // Fallback to convex hull in lat/lon space
                        hullVertices = self.computeConvexHull(points: deviceCoordinates)
                    }

                    // Calculate confidence using point-in-polygon test
                    let confidence = self.calculateClusterConfidence(
                        clusterDevices: clusterDevices,
                        hullVertices: hullVertices,
                        allDevices: devices
                    )

                    // Skip clusters with very low confidence
                    let minConfidence = 0.02 // 2% minimum confidence threshold
                    if confidence < minConfidence {
                        self.logger.info("🔍 Skipping cluster \(clusterIndex) with low confidence: \(String(format: "%.3f", confidence))")
                        return nil
                    }

                    // Calculate outage timing with anomaly filtering (no additional queries)
                    let (startTime, duration) = self.calculateOutageTiming(clusterDevices: clusterDevices)

                    // Generate gradient layers for heat map visualization (3 layers: outermost removed)
                    let gradientLayers = self.generateGradientLayers(
                        polygon: hullVertices,
                        bufferDistances: [-100, -50, 0]  // 3 layers: 100m outward, 50m outward, base
                    )

                    // Create DeviceCluster with CPU-computed hull and gradient layers
                    let deviceCluster = DeviceCluster(
                        clusterId: clusterIndex,
                        devices: clusterDevices,
                        projectedCoordinates: projectedCoordinates,
                        projectionSystem: .nztm2000,
                        confidenceRating: confidence,
                        totalDevicesInArea: clusterDevices.count,
                        hullVertices: hullVertices,
                        gradientLayers: gradientLayers,
                        outageStartTime: startTime,
                        outageDuration: duration
                    )

                    // Verify polygon creation
                    let hasPolygon = deviceCluster.polygon != nil
                    self.logger.debug("🔺 Cluster \(clusterIndex): \(hullVertices.count) hull vertices, confidence: \(String(format: "%.2f", confidence)), polygon: \(hasPolygon ? "✓" : "✗")")

                    return deviceCluster
                }
            }

            // Collect results
            var results: [DeviceCluster] = []
            for try await cluster in group {
                if let cluster = cluster {
                    results.append(cluster)
                }
            }
            return results
        }

        let hullTime = CFAbsoluteTimeGetCurrent() - hullStartTime
        logger.info("✅ Phase 3 CPU complete: \(String(format: "%.1f", hullTime * 1000))ms, \(enhancedClusters.count) valid clusters")

        // Log detailed metrics for analysis
        logCPUHullGenerationMetrics(clusters: enhancedClusters, processingTime: hullTime)

        return enhancedClusters
    }


    /// Check if polygon coordinates are in clockwise order
    /// Used to ensure MKPolygon compatibility (exterior rings should be clockwise)
    nonisolated private func isClockwise(coordinates: [CLLocationCoordinate2D]) -> Bool {
        guard coordinates.count >= 3 else { return true }

        var sum: Double = 0.0
        for i in 0..<coordinates.count {
            let current = coordinates[i]
            let next = coordinates[(i + 1) % coordinates.count]
            sum += (next.longitude - current.longitude) * (next.latitude + current.latitude)
        }

        return sum > 0.0
    }

    // MARK: - Debug Instrumentation

    /// Log CPU-based hull generation metrics for debugging and performance analysis
    private func logCPUHullGenerationMetrics(
        clusters: [DeviceCluster],
        processingTime: Double
    ) {
        logger.info("🔍 CPU Hull Generation Metrics:")

        let totalClusters = clusters.count
        let hullCounts = clusters.map { $0.hullVertices.count }
        let validClusters = hullCounts.filter { $0 >= 3 }.count
        let avgVertices = validClusters > 0 ? Double(hullCounts.reduce(0, +)) / Double(validClusters) : 0.0
        let maxVertices = hullCounts.max() ?? 0
        let minVertices = hullCounts.min() ?? 0

        logger.info("📊 Hull Vertex Analysis:")
        logger.info("  • Total clusters: \(totalClusters)")
        logger.info("  • Valid hulls (≥3 vertices): \(validClusters)")
        logger.info("  • Success rate: \(String(format: "%.1f", Double(validClusters) / Double(totalClusters) * 100))%")
        logger.info("  • Average vertices: \(String(format: "%.1f", avgVertices))")
        logger.info("  • Vertex range: \(minVertices) - \(maxVertices)")

        // Log confidence distribution
        let confidences = clusters.map { $0.confidenceRating }
        let avgConfidence = confidences.isEmpty ? 0.0 : confidences.reduce(0, +) / Double(confidences.count)
        let minConfidence = confidences.min() ?? 0.0
        let maxConfidence = confidences.max() ?? 0.0

        logger.info("📈 Confidence Analysis:")
        logger.info("  • Average confidence: \(String(format: "%.3f", avgConfidence))")
        logger.info("  • Confidence range: \(String(format: "%.3f", minConfidence)) - \(String(format: "%.3f", maxConfidence))")

        // Performance metrics
        logger.info("⏱️ CPU Performance:")
        logger.info("  • Total CPU time: \(String(format: "%.1f", processingTime * 1000))ms")
        logger.info("  • Average time per cluster: \(String(format: "%.2f", (processingTime * 1000) / Double(max(totalClusters, 1))))ms")

        // Log cluster details for debugging
        for (index, cluster) in clusters.enumerated() {
            let deviceCount = cluster.devices.count
            let hullCount = cluster.hullVertices.count
            let hasPolygon = cluster.polygon != nil

            logger.debug("🔺 Cluster \(index): \(deviceCount) devices → \(hullCount) vertices, confidence: \(String(format: "%.3f", cluster.confidenceRating)), polygon: \(hasPolygon ? "✓" : "✗")")
        }
    }

    /// Generate fallback convex hull using gift-wrapping algorithm (Jarvis march)
    /// Used when QuickHull fails due to collinearity or other degenerate cases
    private func generateFallbackHull(
        clusterIndex: Int,
        devices: [PowerSenseDeviceDTO]
    ) -> [CLLocationCoordinate2D] {
        logger.info("🎁 Generating fallback hull for cluster \(clusterIndex) with \(devices.count) devices")

        guard devices.count >= 3 else {
            // For very small clusters, return bounding box
            return createBoundingBox(devices)
        }

        let points = devices.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }

        // Gift-wrapping (Jarvis march) algorithm - O(nh) complexity
        var hull: [CLLocationCoordinate2D] = []

        // Find leftmost point (starting point)
        var leftmost = 0
        for i in 1..<points.count {
            if points[i].longitude < points[leftmost].longitude ||
               (points[i].longitude == points[leftmost].longitude && points[i].latitude < points[leftmost].latitude) {
                leftmost = i
            }
        }

        var p = leftmost
        repeat {
            hull.append(points[p])

            // Find the most counterclockwise point from points[p]
            var q = (p + 1) % points.count
            for i in 0..<points.count {
                if orientation(points[p], points[i], points[q]) == 2 {
                    q = i
                }
            }

            p = q
        } while p != leftmost && hull.count < points.count // Prevent infinite loops

        logger.info("🎁 Fallback hull complete: \(hull.count) vertices from \(points.count) points")
        return hull
    }

    /// Create a simple bounding box hull for degenerate cases
    private func createBoundingBox(_ devices: [PowerSenseDeviceDTO]) -> [CLLocationCoordinate2D] {
        guard !devices.isEmpty else { return [] }

        let lats = devices.map { $0.latitude }
        let lons = devices.map { $0.longitude }

        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLon = lons.min()!
        let maxLon = lons.max()!

        // Return clockwise bounding rectangle
        return [
            CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
            CLLocationCoordinate2D(latitude: minLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: minLon)
        ]
    }

    /// Calculate orientation of ordered triplet of points
    /// Returns: 0 -> collinear, 1 -> clockwise, 2 -> counterclockwise
    private func orientation(
        _ p: CLLocationCoordinate2D,
        _ q: CLLocationCoordinate2D,
        _ r: CLLocationCoordinate2D
    ) -> Int {
        let val = (q.longitude - p.longitude) * (r.latitude - p.latitude) -
                  (q.latitude - p.latitude) * (r.longitude - p.longitude)

        if abs(val) < 1e-10 { return 0 }  // Collinear (with tolerance for floating point)
        return val > 0 ? 1 : 2  // Clockwise or Counterclockwise
    }

    // MARK: - CPU-based Convex Hull Computation

    /// Compute convex hull using Andrew's monotone chain algorithm (O(n log n))
    /// Provides 100% reliability compared to GPU QuickHull implementation
    /// NOTE: nonisolated to allow parallel execution across multiple clusters
    nonisolated private func computeConvexHull(points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard points.count >= 3 else {
            // For degenerate cases, return bounding box
            return createBoundingBoxFromPoints(points)
        }

        // Remove duplicates and sort lexicographically (first by longitude, then by latitude)
        let uniquePoints = Array(Set(points.map { PointKey(coord: $0) }))
            .map { $0.coord }
            .sorted { a, b in
                if abs(a.longitude - b.longitude) < 1e-10 {
                    return a.latitude < b.latitude
                }
                return a.longitude < b.longitude
            }

        guard uniquePoints.count >= 3 else {
            return createBoundingBoxFromPoints(uniquePoints)
        }

        // Build lower hull
        var lower: [CLLocationCoordinate2D] = []
        for point in uniquePoints {
            while lower.count >= 2 && crossProduct(lower[lower.count-2], lower[lower.count-1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }

        // Build upper hull
        var upper: [CLLocationCoordinate2D] = []
        for point in uniquePoints.reversed() {
            while upper.count >= 2 && crossProduct(upper[upper.count-2], upper[upper.count-1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }

        // Remove last point of each half because it's repeated
        lower.removeLast()
        upper.removeLast()

        // Concatenate lower and upper hull
        var hull = lower + upper

        // Ensure we have at least 3 points for a valid polygon
        if hull.count < 3 {
            return createBoundingBoxFromPoints(uniquePoints)
        }

        // Ensure clockwise ordering for MapKit compatibility
        if !isClockwise(coordinates: hull) {
            hull.reverse()
        }

        // Note: Not simplifying convex hull vertices to maintain accuracy
        // MapKit efficiently handles hundreds of vertices
        return hull
    }

    /// Calculate cross product for convex hull computation
    /// Returns positive if points are counter-clockwise, negative if clockwise, zero if collinear
    nonisolated private func crossProduct(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        _ c: CLLocationCoordinate2D
    ) -> Double {
        return (b.longitude - a.longitude) * (c.latitude - a.latitude) -
               (b.latitude - a.latitude) * (c.longitude - a.longitude)
    }

    /// Create bounding box for degenerate point sets
    nonisolated private func createBoundingBoxFromPoints(_ points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard !points.isEmpty else { return [] }

        if points.count == 1 {
            // Single point: create small square around it
            let point = points[0]
            let epsilon = 0.0001 // ~10 meters
            return [
                CLLocationCoordinate2D(latitude: point.latitude - epsilon, longitude: point.longitude - epsilon),
                CLLocationCoordinate2D(latitude: point.latitude - epsilon, longitude: point.longitude + epsilon),
                CLLocationCoordinate2D(latitude: point.latitude + epsilon, longitude: point.longitude + epsilon),
                CLLocationCoordinate2D(latitude: point.latitude + epsilon, longitude: point.longitude - epsilon)
            ]
        }

        if points.count == 2 {
            // Two points: create rectangle around line
            let p1 = points[0], p2 = points[1]
            let epsilon = 0.0001
            return [
                CLLocationCoordinate2D(latitude: min(p1.latitude, p2.latitude) - epsilon,
                                     longitude: min(p1.longitude, p2.longitude) - epsilon),
                CLLocationCoordinate2D(latitude: min(p1.latitude, p2.latitude) - epsilon,
                                     longitude: max(p1.longitude, p2.longitude) + epsilon),
                CLLocationCoordinate2D(latitude: max(p1.latitude, p2.latitude) + epsilon,
                                     longitude: max(p1.longitude, p2.longitude) + epsilon),
                CLLocationCoordinate2D(latitude: max(p1.latitude, p2.latitude) + epsilon,
                                     longitude: min(p1.longitude, p2.longitude) - epsilon)
            ]
        }

        // Multiple points: standard bounding box
        let lats = points.map { $0.latitude }
        let lons = points.map { $0.longitude }
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!

        return [
            CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
            CLLocationCoordinate2D(latitude: minLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: minLon)
        ]
    }

    // MARK: - Phase 4: Concave Hull (Alpha Shapes)

    /// Compute concave hull using efficient grid-based spatial indexing algorithm
    /// Works in NZTM2000 projected space (meters) for accurate concavity
    /// NOTE: nonisolated to allow parallel execution across multiple clusters
    nonisolated private func computeConcaveHull(
        projectedCoordinates: [ProjectedCoordinate],
        concavity: Double,
        transformer: CoordinateTransformer
    ) throws -> [CLLocationCoordinate2D] {
        // Convert projected coordinates to Point for hull algorithm
        let points = projectedCoordinates.map { Point(x: $0.x, y: $0.y) }

        // Use efficient grid-based concave hull algorithm in metric space
        let concaveHull = ConcaveHull()
        let hullPoints = concaveHull.hullFromPoints(points: points, concavity: concavity)

        // Convert hull back to projected coordinates
        let hullProjected = hullPoints.map { ProjectedCoordinate(x: $0.x, y: $0.y, system: .nztm2000) }

        // Transform back to lat/lon for rendering
        var hullLatLon = transformer.batchInverseTransform(hullProjected)

        // Ensure clockwise ordering for MapKit
        if !isClockwise(coordinates: hullLatLon) {
            hullLatLon.reverse()
        }

        // Note: Not simplifying hull vertices to preserve tight concave boundaries
        // Stride-based simplification can skip important vertices at corners
        // Modern MapKit can handle hundreds of vertices efficiently

        return hullLatLon
    }

    // MARK: - Phase 4: Gradient Buffer Layers

    /// Generate multiple buffered polygons for gradient visualization
    /// Returns array of polygons from outermost to innermost
    /// Supports both inward (positive) and outward (negative) buffers
    /// NOTE: nonisolated to allow parallel execution across multiple clusters
    nonisolated func generateGradientLayers(
        polygon: [CLLocationCoordinate2D],
        bufferDistances: [Double]  // In meters, negative = outward, positive = inward
    ) -> [[CLLocationCoordinate2D]] {
        var layers: [[CLLocationCoordinate2D]] = []

        for distance in bufferDistances {
            if distance == 0 {
                // Original polygon
                layers.append(polygon)
            } else {
                // Buffered polygon (inward if positive, outward if negative)
                if let buffered = bufferPolygon(polygon: polygon, bufferMeters: distance) {
                    layers.append(buffered)
                } else {
                    // Buffer collapsed (only for inward) - stop generating layers
                    if distance > 0 {
                        break
                    }
                }
            }
        }

        return layers
    }

    /// Buffer polygon by specified distance in meters
    /// Positive = inward, negative = outward
    /// Returns nil if polygon collapses (becomes too small) - only for inward buffers
    nonisolated private func bufferPolygon(
        polygon: [CLLocationCoordinate2D],
        bufferMeters: Double
    ) -> [CLLocationCoordinate2D]? {
        guard polygon.count >= 3 else { return nil }

        // Convert buffer distance to approximate degrees
        // At equator: 1 degree ≈ 111,000 meters
        // This is approximate but sufficient for visualization
        let bufferDegrees = bufferMeters / 111_000.0

        // Compute inward normal offset for each vertex
        var bufferedVertices: [CLLocationCoordinate2D] = []

        for i in 0..<polygon.count {
            let prev = polygon[(i - 1 + polygon.count) % polygon.count]
            let curr = polygon[i]
            let next = polygon[(i + 1) % polygon.count]

            // Calculate edge vectors
            let v1 = (lat: curr.latitude - prev.latitude, lon: curr.longitude - prev.longitude)
            let v2 = (lat: next.latitude - curr.latitude, lon: next.longitude - curr.longitude)

            // Calculate perpendicular (inward normal) for each edge
            let n1 = normalizeVector((-v1.lon, v1.lat))  // Perpendicular to v1
            let n2 = normalizeVector((-v2.lon, v2.lat))  // Perpendicular to v2

            // Average the normals for vertex offset direction
            var avgNormal = (lat: (n1.lat + n2.lat) / 2.0, lon: (n1.lon + n2.lon) / 2.0)
            avgNormal = normalizeVector(avgNormal)

            // Ensure correct direction based on buffer type
            // For inward buffer (positive): normal points inward
            // For outward buffer (negative): normal points outward
            let isInward = bufferMeters > 0
            if isInward {
                // Inward buffer: ensure normal points inward
                if !isClockwise(coordinates: polygon) {
                    avgNormal = (-avgNormal.lat, -avgNormal.lon)
                }
            } else {
                // Outward buffer: ensure normal points outward (reverse of inward)
                if isClockwise(coordinates: polygon) {
                    avgNormal = (-avgNormal.lat, -avgNormal.lon)
                }
            }

            // Offset vertex by buffer distance
            let offsetLat = curr.latitude + avgNormal.lat * bufferDegrees
            let offsetLon = curr.longitude + avgNormal.lon * bufferDegrees

            bufferedVertices.append(CLLocationCoordinate2D(latitude: offsetLat, longitude: offsetLon))
        }

        // Check if polygon collapsed (area too small) - only for inward buffers
        guard bufferedVertices.count >= 3 else { return nil }

        // Compute area to detect collapse (only check for inward buffers)
        if bufferMeters > 0 {
            let area = computePolygonArea(bufferedVertices)
            guard area > 1e-10 else { return nil }  // Collapsed to nearly zero area
        }

        return bufferedVertices
    }

    /// Normalize a 2D vector
    nonisolated private func normalizeVector(_ v: (lat: Double, lon: Double)) -> (lat: Double, lon: Double) {
        let magnitude = sqrt(v.lat * v.lat + v.lon * v.lon)
        guard magnitude > 0 else { return (0, 0) }
        return (v.lat / magnitude, v.lon / magnitude)
    }

    /// Compute signed area of polygon (positive if clockwise)
    nonisolated private func computePolygonArea(_ polygon: [CLLocationCoordinate2D]) -> Double {
        guard polygon.count >= 3 else { return 0 }

        var area: Double = 0
        for i in 0..<polygon.count {
            let j = (i + 1) % polygon.count
            area += polygon[i].longitude * polygon[j].latitude
            area -= polygon[j].longitude * polygon[i].latitude
        }
        return abs(area) / 2.0
    }

    /// Point-in-polygon test using winding number algorithm
    /// More accurate than bounding box for confidence calculation
    nonisolated private func pointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }

        var wn = 0    // Winding number

        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]

            if a.latitude <= point.latitude {
                if b.latitude > point.latitude && isLeft(a, b, point) > 0 {
                    wn += 1
                }
            } else {
                if b.latitude <= point.latitude && isLeft(a, b, point) < 0 {
                    wn -= 1
                }
            }
        }

        return wn != 0
    }

    /// Test if point is left of line segment
    nonisolated private func isLeft(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        _ p: CLLocationCoordinate2D
    ) -> Double {
        return (b.longitude - a.longitude) * (p.latitude - a.latitude) -
               (p.longitude - a.longitude) * (b.latitude - a.latitude)
    }

    /// Apply farthest-point sampling to preserve cluster boundaries
    private func applySamplingToCluster(
        devices: [PowerSenseDeviceDTO],
        targetCount: Int
    ) -> [PowerSenseDeviceDTO] {
        guard devices.count > targetCount else { return devices }

        logger.debug("🔧 Applying farthest-point sampling: \(devices.count) → \(targetCount)")

        var sampled: [PowerSenseDeviceDTO] = []

        // Start with extrema points to preserve boundaries
        let lats = devices.map { $0.latitude }
        let lons = devices.map { $0.longitude }
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!

        // Find extreme points
        var extremeIndices: Set<Int> = []
        for (index, device) in devices.enumerated() {
            if device.latitude == minLat || device.latitude == maxLat ||
               device.longitude == minLon || device.longitude == maxLon {
                extremeIndices.insert(index)
                sampled.append(device)
            }
        }

        // For large clusters, use stratified random sampling instead of farthest-point
        // to avoid O(n²) performance hit
        let additionalCount = targetCount - sampled.count
        if additionalCount > 0 {
            // Remove extrema from pool
            let remaining = devices.enumerated().compactMap { index, device in
                extremeIndices.contains(index) ? nil : device
            }

            if !remaining.isEmpty {
                // Use stride-based sampling for performance (approximates farthest-point)
                let stride = Double(remaining.count) / Double(additionalCount)
                var additionalSampled: [PowerSenseDeviceDTO] = []

                for i in 0..<additionalCount {
                    let index = min(Int(Double(i) * stride), remaining.count - 1)
                    additionalSampled.append(remaining[index])
                }

                sampled.append(contentsOf: additionalSampled)
            }
        }

        logger.debug("🔧 Sampling complete: \(extremeIndices.count) extrema + \(sampled.count - extremeIndices.count) stride-sampled = \(sampled.count) total")
        return sampled
    }

    /// Calculate outage start time and duration with statistical outlier filtering
    /// Uses IQR (Interquartile Range) method - handles both short outages and multi-week disasters
    /// Zero additional database queries - uses eventTimestamp already in DTO
    /// NOTE: nonisolated to allow parallel execution across multiple clusters
    nonisolated private func calculateOutageTiming(clusterDevices: [PowerSenseDeviceDTO]) -> (startTime: Date?, duration: TimeInterval) {
        let allTimestamps = clusterDevices
            .compactMap { $0.eventTimestamp }
            .sorted()

        guard allTimestamps.count >= 3 else {
            // Too few samples for statistical filtering, use median
            if let median = allTimestamps.first {
                let duration = Date().timeIntervalSince(median)
                return (median, duration)
            }
            return (nil, 0)
        }

        // Calculate quartiles for IQR outlier detection
        let q1Index = allTimestamps.count / 4
        let q3Index = (3 * allTimestamps.count) / 4

        let q1 = allTimestamps[q1Index]
        let q3 = allTimestamps[q3Index]
        let iqr = q3.timeIntervalSince(q1)

        // IQR method: outliers are beyond Q1 - 1.5*IQR or Q3 + 1.5*IQR
        let lowerBound = q1.addingTimeInterval(-1.5 * iqr)
        let upperBound = q3.addingTimeInterval(1.5 * iqr)

        // Filter outliers using IQR bounds
        let filteredTimestamps = allTimestamps.filter { timestamp in
            timestamp >= lowerBound && timestamp <= upperBound
        }

        guard !filteredTimestamps.isEmpty else {
            // Fallback if all filtered out (shouldn't happen with IQR)
            return (allTimestamps[allTimestamps.count / 2], Date().timeIntervalSince(allTimestamps[allTimestamps.count / 2]))
        }

        // Calculate median of filtered timestamps
        let medianTimestamp: Date
        if filteredTimestamps.count % 2 == 0 {
            let mid = filteredTimestamps.count / 2
            let interval = filteredTimestamps[mid].timeIntervalSince(filteredTimestamps[mid - 1])
            medianTimestamp = filteredTimestamps[mid - 1].addingTimeInterval(interval / 2)
        } else {
            medianTimestamp = filteredTimestamps[filteredTimestamps.count / 2]
        }

        let duration = Date().timeIntervalSince(medianTimestamp)

        let filteredCount = allTimestamps.count - filteredTimestamps.count
        logger.debug("⏱️ Cluster outage: \(filteredTimestamps.count) timestamps (filtered \(filteredCount) outliers via IQR), median start: \(medianTimestamp), duration: \(String(format: "%.1f", duration / 60))min")

        return (medianTimestamp, duration)
    }

    /// Calculate cluster confidence using point-in-polygon test
    /// NOTE: nonisolated to allow parallel execution across multiple clusters
    nonisolated private func calculateClusterConfidence(
        clusterDevices: [PowerSenseDeviceDTO],
        hullVertices: [CLLocationCoordinate2D],
        allDevices: [PowerSenseDeviceDTO]
    ) -> Double {
        // For degenerate hulls (< 3 vertices), use cluster-only confidence
        guard hullVertices.count >= 3 else {
            // Calculate confidence based on cluster devices only
            let offlineCount = clusterDevices.filter { $0.isOffline == true }.count
            let confidence = clusterDevices.isEmpty ? 0.0 : Double(offlineCount) / Double(clusterDevices.count)
            return confidence
        }

        // Compute bounding box for pre-filtering (90%+ reduction in checks)
        let lats = hullVertices.map(\.latitude)
        let lons = hullVertices.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return 0.0
        }

        // Pre-filter candidates using bounding box (fast rejection)
        let candidates = allDevices.filter { device in
            device.latitude >= minLat && device.latitude <= maxLat &&
            device.longitude >= minLon && device.longitude <= maxLon
        }

        // Find all devices within the hull area (only checking candidates)
        var totalDevicesInHull = 0
        var offlineDevicesInHull = 0

        for device in candidates {
            let deviceCoord = CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
            if pointInPolygon(point: deviceCoord, polygon: hullVertices) {
                totalDevicesInHull += 1
                if device.isOffline == true {
                    offlineDevicesInHull += 1
                }
            }
        }

        // Confidence = ratio of offline devices to total devices in hull area
        // This represents how "dense" the outage is within the convex hull
        if totalDevicesInHull == 0 {
            return 0.0
        }

        let confidence = Double(offlineDevicesInHull) / Double(totalDevicesInHull)
        return confidence
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
//
//  ClusteringService.swift
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
import OSLog

/// App-level singleton service for spatial clustering
/// Maintains single actor instance with cached GPU buffers for performance
@Observable
final class ClusteringService: @unchecked Sendable {
    private let actor: SpatialClusteringActor
    private let logger = Logger(subsystem: "pulse", category: "clusteringService")

    init(modelContainer: ModelContainer) throws {
        self.actor = try SpatialClusteringActor(
            modelContainer: modelContainer,
            config: SpatialClusteringConfig.default
        )
        logger.info("🌍 ClusteringService initialized with persistent actor")
    }

    /// Perform clustering using the persistent actor instance
    /// GPU buffers are reused across calls for optimal performance
    func clusterDevices() async throws -> ClusterResult {
        return try await actor.clusterAllDevices()
    }

    /// Get performance metrics from the actor
    func getPerformanceMetrics() async -> SpatialIndexMetrics {
        return await actor.getIndexerPerformanceMetrics()
    }

    /// Check if indexer is ready
    func isReady() async -> Bool {
        return await actor.isIndexerReady()
    }
}

// Note: CLLocationCoordinate2D already conforms to Equatable in Swift
// Custom comparison for triangulation (fuzzy equality within epsilon)
private func coordinatesEqual(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
    return abs(lhs.latitude - rhs.latitude) < 1e-9 && abs(lhs.longitude - rhs.longitude) < 1e-9
}
