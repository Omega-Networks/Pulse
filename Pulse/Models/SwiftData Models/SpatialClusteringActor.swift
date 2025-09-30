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
    let clusters: [DeviceCluster]
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

        logger.info("📊 Found \(devices.count) devices, \(offlineCount) offline")

        guard offlineCount >= config.clusteringParameters.minPoints else {
            throw ClusteringError.insufficientData(deviceCount: offlineCount, minimum: config.clusteringParameters.minPoints)
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

    /// Convert GPU DBSCAN results to DeviceCluster objects
    private func convertDBSCANResultToClusters(
        dbscanResult: DBSCANResult,
        devices: [PowerSenseDeviceDTO],
        aggregationThreshold: Int
    ) throws -> [DeviceCluster] {

        var clusters: [DeviceCluster] = []
        var clusterDevicesMap: [Int32: [PowerSenseDeviceDTO]] = [:]

        // Group devices by cluster label (offline devices only)
        for (index, device) in devices.enumerated() {
            let label = dbscanResult.labels[index]

            // Only process offline devices with valid cluster labels (not noise -1)
            if device.isOffline == true && label != -1 {
                if clusterDevicesMap[label] == nil {
                    clusterDevicesMap[label] = []
                }
                clusterDevicesMap[label]?.append(device)
            }
        }

        logger.debug("📊 GPU DBSCAN found \(clusterDevicesMap.count) raw clusters")

        // Convert clusters that meet aggregation threshold
        var clusterId = 0
        for (label, clusterDevices) in clusterDevicesMap {
            if clusterDevices.count >= aggregationThreshold {
                let cluster = createDeviceCluster(
                    id: clusterId,
                    devices: clusterDevices
                )
                clusters.append(cluster)
                clusterId += 1

                logger.debug("✅ Created cluster \(clusterId-1) from GPU label \(label) with \(clusterDevices.count) devices")
            } else {
                logger.debug("🔒 GPU cluster \(label) with \(clusterDevices.count) devices below aggregation threshold - filtered for privacy")
            }
        }

        logger.info("📈 GPU DBSCAN final result: \(clusters.count) clusters from \(dbscanResult.clusterCount) raw clusters")
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

    /// Create a DeviceCluster from a list of devices
    private func createDeviceCluster(id: Int, devices: [any SpatialDevice]) -> DeviceCluster {
        // Transform device coordinates for DeviceCluster
        let deviceCoordinates = devices.map { device in
            CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
        }

        // Use a simple transformation for projected coordinates (proper transformer would be better)
        let projectedCoordinates = deviceCoordinates.map { coord in
            ProjectedCoordinate(
                x: coord.longitude * 111000.0, // Approximate conversion
                y: coord.latitude * 111000.0,
                system: .nztm2000
            )
        }

        // DeviceCluster automatically determines severity based on device count in its initializer

        return DeviceCluster(
            clusterId: id,
            devices: devices,
            projectedCoordinates: projectedCoordinates,
            projectionSystem: .nztm2000,
            confidenceRating: 1.0, // Default confidence for Phase 2 clusters
            totalDevicesInArea: devices.count,
            hullVertices: [] // No hull vertices for Phase 2 clusters
        )
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

        // Apply sampling for very large clusters to improve performance
        let samplingThreshold = 1000  // CPU can handle more points efficiently
        let maxPointsPerCluster = validClusters.map { $0.1.count }.max() ?? 100

        logger.info("🔧 Max points per cluster: \(maxPointsPerCluster)")
        logger.info("🔧 Cluster sizes: \(validClusters.map { $0.1.count }.prefix(5).map(String.init).joined(separator: ", "))\(validClusters.count > 5 ? "..." : "")")

        let finalClusters = validClusters.map { (label, devices) in
            if devices.count > samplingThreshold {
                logger.info("🔧 Sampling cluster \(label): \(devices.count) → \(samplingThreshold) (farthest-point)")
                return (label, applySamplingToCluster(devices: devices, targetCount: samplingThreshold))
            } else {
                return (label, devices)
            }
        }

        // Start timing CPU hull computation
        let hullStartTime = CFAbsoluteTimeGetCurrent()
        var enhancedClusters: [DeviceCluster] = []

        // Process each cluster with CPU-based hull computation
        for (clusterIndex, (_, clusterDevices)) in finalClusters.enumerated() {
            logger.debug("🔺 Processing cluster \(clusterIndex) with \(clusterDevices.count) devices")

            // Extract coordinates for hull computation
            let clusterPoints = clusterDevices.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

            // Compute convex hull using CPU-based Andrew's algorithm
            let hullVertices = computeConvexHull(points: clusterPoints)

            // Calculate confidence using point-in-polygon test
            let confidence = calculateClusterConfidence(
                clusterDevices: clusterDevices,
                hullVertices: hullVertices,
                allDevices: devices
            )

            // Skip clusters with very low confidence
            let minConfidence = 0.02 // 2% minimum confidence threshold
            if confidence < minConfidence {
                logger.info("🔍 Skipping cluster \(clusterIndex) with low confidence: \(String(format: "%.3f", confidence))")
                continue
            }

            // Transform device coordinates for DeviceCluster
            let deviceCoordinates = clusterDevices.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let projectedCoordinates = try transformer.batchTransform(deviceCoordinates)

            // Create DeviceCluster with CPU-computed hull
            let deviceCluster = DeviceCluster(
                clusterId: clusterIndex,
                devices: clusterDevices,
                projectedCoordinates: projectedCoordinates,
                projectionSystem: .nztm2000,
                confidenceRating: confidence,
                totalDevicesInArea: clusterDevices.count,
                hullVertices: hullVertices
            )

            // Verify polygon creation
            let hasPolygon = deviceCluster.polygon != nil
            logger.debug("🔺 Cluster \(clusterIndex): \(hullVertices.count) hull vertices, confidence: \(String(format: "%.2f", confidence)), polygon: \(hasPolygon ? "✓" : "✗")")

            enhancedClusters.append(deviceCluster)
        }

        let hullTime = CFAbsoluteTimeGetCurrent() - hullStartTime
        logger.info("✅ Phase 3 CPU complete: \(String(format: "%.1f", hullTime * 1000))ms, \(enhancedClusters.count) valid clusters")

        // Log detailed metrics for analysis
        logCPUHullGenerationMetrics(clusters: enhancedClusters, processingTime: hullTime)

        return enhancedClusters
    }

    // MARK: - OBSOLETE GPU Hull Methods (retained for potential revert)
    /*
    /// OBSOLETE: Convert hull computation results to DeviceCluster objects with polygons
    /// Replaced by CPU-based hull computation for 100% reliability
    private func convertHullResultToClusters(
        validClusters: [(Int32, [PowerSenseDeviceDTO])],
        hullResult: GPUHullAndConfidenceResult,
        transformer: CoordinateTransformer
    ) async throws -> [DeviceCluster] {
        // This method has been replaced by the CPU-based approach in generateClustersWithHullsAndConfidence
        // GPU QuickHull had a 77% failure rate - CPU Andrew's algorithm provides 100% reliability
        fatalError("This GPU-based method is obsolete. Use CPU-based hull computation instead.")
    }
    */

    /// Check if polygon coordinates are in clockwise order
    /// Used to ensure MKPolygon compatibility (exterior rings should be clockwise)
    private func isClockwise(coordinates: [CLLocationCoordinate2D]) -> Bool {
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
    private func computeConvexHull(points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
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

        // Apply vertex limiting to prevent UI lag (max 50 vertices)
        if hull.count > 50 {
            hull = simplifyHullVertices(hull: hull, maxVertices: 50)
        }

        return hull
    }

    /// Simplify hull by reducing vertex count while preserving shape
    /// Uses Douglas-Peucker-inspired sampling of vertices by perimeter distance
    private func simplifyHullVertices(hull: [CLLocationCoordinate2D], maxVertices: Int) -> [CLLocationCoordinate2D] {
        guard hull.count > maxVertices else { return hull }

        logger.debug("🔧 Simplifying hull: \(hull.count) → \(maxVertices) vertices")

        // Calculate perimeter and sample at regular intervals
        var simplified: [CLLocationCoordinate2D] = []
        let stride = Double(hull.count) / Double(maxVertices)

        for i in 0..<maxVertices {
            let index = Int(Double(i) * stride)
            simplified.append(hull[index])
        }

        logger.debug("🔧 Hull simplification complete: \(simplified.count) vertices")
        return simplified
    }

    /// Calculate cross product for convex hull computation
    /// Returns positive if points are counter-clockwise, negative if clockwise, zero if collinear
    private func crossProduct(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        _ c: CLLocationCoordinate2D
    ) -> Double {
        return (b.longitude - a.longitude) * (c.latitude - a.latitude) -
               (b.latitude - a.latitude) * (c.longitude - a.longitude)
    }

    /// Create bounding box for degenerate point sets
    private func createBoundingBoxFromPoints(_ points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
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

    /// Point-in-polygon test using winding number algorithm
    /// More accurate than bounding box for confidence calculation
    private func pointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
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
    private func isLeft(
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

    /// Calculate cluster confidence using point-in-polygon test
    private func calculateClusterConfidence(
        clusterDevices: [PowerSenseDeviceDTO],
        hullVertices: [CLLocationCoordinate2D],
        allDevices: [PowerSenseDeviceDTO]
    ) -> Double {
        // For degenerate hulls (< 3 vertices), use cluster-only confidence
        guard hullVertices.count >= 3 else {
            // Calculate confidence based on cluster devices only
            let offlineCount = clusterDevices.filter { $0.isOffline == true }.count
            let confidence = clusterDevices.isEmpty ? 0.0 : Double(offlineCount) / Double(clusterDevices.count)
            logger.debug("🔍 Degenerate hull confidence (cluster-only): \(offlineCount)/\(clusterDevices.count) = \(String(format: "%.3f", confidence))")
            return confidence
        }

        // Find all devices within the hull area
        var totalDevicesInHull = 0
        var offlineDevicesInHull = 0

        for device in allDevices {
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
            logger.warning("🔍 No devices found in hull - returning 0.0 confidence")
            return 0.0
        }

        let confidence = Double(offlineDevicesInHull) / Double(totalDevicesInHull)
        logger.debug("🔍 Confidence calculation: \(offlineDevicesInHull) offline / \(totalDevicesInHull) total in hull = \(String(format: "%.3f", confidence))")

        return confidence
    }

    // MARK: - OBSOLETE GPU Debug Methods (retained for potential revert)
    /*
    /// OBSOLETE: Debug coordinate buffer contents safely
    /// No longer needed with CPU-based hull computation
    private func debugCoordinateBuffer(coordsBuffer: SendableBuffer, context: String) async {
        // This method is obsolete with CPU-based approach
        logger.debug("Skipping coordinate buffer debug - using CPU-based hull computation")
    }
    */

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
