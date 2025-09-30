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

    /// Modern GPU-accelerated clustering implementation using DBSCAN
    private func performModernClustering(devices: [PowerSenseDeviceDTO]) async throws -> [DeviceCluster] {
        logger.debug("🔬 Performing GPU-accelerated DBSCAN clustering on \(devices.count) devices")

        // Filter to offline devices only for clustering
        let offlineDevices = devices.filter { $0.isOffline == true }

        guard !offlineDevices.isEmpty else {
            logger.info("ℹ️ No offline devices found - returning empty cluster set")
            return []
        }

        logger.info("🧠 Using GPU DBSCAN for \(offlineDevices.count) offline devices")

        // Get GPU buffers from the spatial index (Apple Silicon - GPU integrated)
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

        // Phase 3: Generate hull and confidence for visualization
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

    /// Phase 3: Generate clusters with convex hull polygons and confidence scores
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

        logger.info("🔺 Phase 3: Starting hull & confidence generation")

        // Debug: Check coordinate ranges RIGHT AT FUNCTION ENTRY
        logger.info("🔍 FUNCTION-ENTRY: Checking coordinate buffer at generateClustersWithHullsAndConfidence entry...")
        await debugCoordinateBuffer(coordsBuffer: coordsBuffer, context: "FUNCTION-ENTRY")

        // Group devices by cluster label
        var clusterDevicesMap: [Int32: [PowerSenseDeviceDTO]] = [:]
        var clusterOffsets: [Int32] = []

        for (index, device) in devices.enumerated() {
            let label = dbscanResult.labels[index]
            if device.isOffline == true && label != -1 {
                if clusterDevicesMap[label] == nil {
                    clusterDevicesMap[label] = []
                }
                clusterDevicesMap[label]?.append(device)
            }
        }

        // Filter clusters meeting aggregation threshold and prepare offsets
        var validClusters: [(Int32, [PowerSenseDeviceDTO])] = []
        var currentOffset = 0

        for (label, clusterDevices) in clusterDevicesMap {
            if clusterDevices.count >= aggregationThreshold {
                validClusters.append((label, clusterDevices))
                // Add start and count for this cluster
                clusterOffsets.append(Int32(currentOffset))
                clusterOffsets.append(Int32(clusterDevices.count))
                currentOffset += clusterDevices.count
            }
        }

        guard !validClusters.isEmpty else {
            logger.info("⚠️ No clusters meet aggregation threshold - returning empty")
            return []
        }

        logger.info("📊 Phase 3: Processing \(validClusters.count) clusters with hulls")

        // Calculate maximum points per cluster for buffer allocation
        let maxPointsPerCluster = validClusters.map { $0.1.count }.max() ?? 100

        logger.info("🔧 About to call GPU hull computation with \(validClusters.count) clusters, maxPoints: \(maxPointsPerCluster)")
        logger.info("🔧 Cluster sizes: \(validClusters.map { $0.1.count }.prefix(5).map(String.init).joined(separator: ", "))\(validClusters.count > 5 ? "..." : "")")

        // Configurable sampling for large clusters - DISABLED for testing full dataset
        let samplingThreshold = 1024  // Conservative limit for Metal stack space (~32KB)
        let enableSampling = false // DISABLED: maxPointsPerCluster > samplingThreshold
        logger.info("Max points per cluster: \(maxPointsPerCluster), sampling enabled: \(enableSampling) (DISABLED for testing)")

        let optimizedClusters: [(Int32, [PowerSenseDeviceDTO])] = validClusters.map { (label, devices) in
            if enableSampling && devices.count > samplingThreshold {
                logger.info("🔧 Sampling cluster \(label): \(devices.count) → \(samplingThreshold) (boundary-preserving)")

                // Enhanced boundary preservation: preserve extremes AND convex hull candidate points
                let lats = devices.map { $0.latitude }
                let lons = devices.map { $0.longitude }
                let minLat = lats.min()!
                let maxLat = lats.max()!
                let minLon = lons.min()!
                let maxLon = lons.max()!

                // Find extreme boundary devices (min/max in each direction)
                var boundaryDevices = Set<String>()
                for device in devices {
                    if device.latitude == minLat || device.latitude == maxLat ||
                       device.longitude == minLon || device.longitude == maxLon {
                        boundaryDevices.insert(device.deviceId)
                    }
                }

                // Use random sampling for simplicity - preserves statistical properties
                let sampledDevices = Array(devices.shuffled().prefix(samplingThreshold))
                logger.info("🔧 Random sampling cluster \(label): \(devices.count) → \(sampledDevices.count)")

                return (label, sampledDevices)
            } else {
                // No sampling - use all points for maximum accuracy
                return (label, devices)
            }
        }

        // Recalculate maxPointsPerCluster after optimization
        let optimizedMaxPoints = optimizedClusters.map { $0.1.count }.max() ?? 0
        logger.info("🔧 Optimized maxPoints: \(maxPointsPerCluster) → \(optimizedMaxPoints) \(optimizedMaxPoints > samplingThreshold ? "Still exceeds threshold!" : "Safe for GPU")")

        // Rebuild buffers with optimized data if sampling occurred
        let finalClusters: [(Int32, [PowerSenseDeviceDTO])]
        let finalCoordBuffer: SendableBuffer
        let finalOfflineBuffer: SendableBuffer
        let finalClusterOffsets: [Int32]
        let finalMaxPoints: Int

        if optimizedMaxPoints != maxPointsPerCluster {
            finalClusters = optimizedClusters
            finalMaxPoints = optimizedMaxPoints

            logger.info("🔧 Rebuilding GPU buffers with optimized data...")

            // Rebuild coordinate and offline buffers with CORRECT offset tracking
            var allOptimizedCoords: [SIMD2<Float>] = []
            var allOptimizedFlags: [UInt8] = []
            var optimizedOffsets: [Int32] = []  // Changed to store start/count pairs

            // Get pointer to existing transformed coordinates
            let existingCoordsPointer = coordsBuffer.buffer.contents().bindMemory(
                to: SIMD2<Float>.self,
                capacity: devices.count
            )

            // Build device index map for fast lookup
            let deviceIndexMap: [String: Int] = Dictionary(
                uniqueKeysWithValues: devices.enumerated().map { ($1.deviceId, $0) }
            )

            for (_, clusterDevices) in optimizedClusters {
                let clusterStartOffset = Int32(allOptimizedCoords.count)

                // Copy already-transformed coordinates from the existing buffer
                for device in clusterDevices {
                    if let deviceIndex = deviceIndexMap[device.deviceId] {
                        let existingCoord = existingCoordsPointer[deviceIndex]
                        allOptimizedCoords.append(existingCoord)
                        allOptimizedFlags.append(device.isOffline == true ? 1 : 0)
                    } else {
                        logger.warning("⚠️ Device \(device.deviceId) not found in index map")
                    }
                }

                let clusterPointCount = Int32(allOptimizedCoords.count - Int(clusterStartOffset))

                // Store as start/count pairs (matching Phase 3 expectations)
                optimizedOffsets.append(clusterStartOffset)
                optimizedOffsets.append(clusterPointCount)

                logger.debug("📊 Cluster offsets: start=\(clusterStartOffset), count=\(clusterPointCount)")
            }

            // Validate offsets before creating buffers
            let totalPoints = allOptimizedCoords.count
            for i in stride(from: 0, to: optimizedOffsets.count, by: 2) {
                let start = Int(optimizedOffsets[i])
                let count = Int(optimizedOffsets[i + 1])
                if start + count > totalPoints {
                    logger.error("❌ Invalid offset detected: start=\(start), count=\(count), total=\(totalPoints)")
                    // Clamp to valid range
                    optimizedOffsets[i + 1] = Int32(max(0, totalPoints - start))
                }
            }

            // Create Metal buffers using the already-transformed coordinates
            finalCoordBuffer = try transformer.createCoordinatesBuffer(from: allOptimizedCoords)
            finalOfflineBuffer = try transformer.createOfflineFlagsBuffer(from: allOptimizedFlags)
            finalClusterOffsets = optimizedOffsets  // Use the complete offset array (start/count pairs)

            logger.info("✅ GPU buffers rebuilt: \(allOptimizedCoords.count) coords, \(finalClusters.count) clusters")
            logger.info("📊 Offset pairs: \(finalClusterOffsets)")
        } else {
            // No sampling needed - rebuild offsets as start/count pairs for original clusters
            finalClusters = validClusters
            finalCoordBuffer = coordsBuffer
            finalOfflineBuffer = offlineFlagsBuffer

            // Build proper start/count offset pairs
            var properOffsets: [Int32] = []
            var runningOffset: Int32 = 0

            for (_, clusterDevices) in validClusters {
                properOffsets.append(runningOffset)
                properOffsets.append(Int32(clusterDevices.count))
                runningOffset += Int32(clusterDevices.count)
            }

            finalClusterOffsets = properOffsets
            finalMaxPoints = maxPointsPerCluster
            logger.info("✅ No sampling needed - using original buffers with corrected offsets")
            logger.info("📊 Offset pairs: \(finalClusterOffsets)")
        }

        // Perform GPU hull and confidence computation with optimized data
        let hullResult = try await transformer.performGPUHullAndConfidence(
            coordsBuffer: finalCoordBuffer.buffer,
            offlineFlagsBuffer: finalOfflineBuffer.buffer,
            clusterOffsets: finalClusterOffsets,
            gridParams: gridParams,
            grid: gpuGrid,
            clusterCount: finalClusters.count,
            maxPointsPerCluster: finalMaxPoints
        )

        logger.info("✅ Phase 3 GPU complete: \(String(format: "%.1f", hullResult.totalTime * 1000))ms")

        // Debug: Analyze hull generation results before conversion
        await logHullGenerationMetrics(finalClusters, hullResult)

        // Convert to DeviceCluster objects with enhanced data using final clusters
        return try await convertHullResultToClusters(
            validClusters: finalClusters,
            hullResult: hullResult,
            transformer: transformer
        )
    }

    /// Convert hull computation results to DeviceCluster objects with polygons
    private func convertHullResultToClusters(
        validClusters: [(Int32, [PowerSenseDeviceDTO])],
        hullResult: GPUHullAndConfidenceResult,
        transformer: CoordinateTransformer
    ) async throws -> [DeviceCluster] {

        var enhancedClusters: [DeviceCluster] = []

        // Read hull vertices and counts from GPU buffers
        let hullCountsPointer = hullResult.hullBuffers.hullCounts.buffer.contents().bindMemory(to: Int32.self, capacity: validClusters.count)
        let hullCounts = Array(UnsafeBufferPointer(start: hullCountsPointer, count: validClusters.count))

        let confidencePairsPointer = hullResult.hullBuffers.confidencePairs.buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: validClusters.count)
        let confidencePairs = Array(UnsafeBufferPointer(start: confidencePairsPointer, count: validClusters.count))

        let maxHullVertices = 100 // Match updated Phase3Parameters.maxHullVertices
        let hullVerticesPointer = hullResult.hullBuffers.hullVertices.buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: validClusters.count * maxHullVertices)

        for (clusterIndex, (_, clusterDevices)) in validClusters.enumerated() {
            let hullCount = Int(hullCounts[clusterIndex])
            let confidencePair = confidencePairs[clusterIndex]

            // Extract hull vertices for this cluster
            var hullVerticesProjected: [ProjectedCoordinate] = []
            let hullOffset = clusterIndex * maxHullVertices

            for i in 0..<hullCount {
                let vertex = hullVerticesPointer[hullOffset + i]
                hullVerticesProjected.append(ProjectedCoordinate(
                    x: Double(vertex.x),
                    y: Double(vertex.y),
                    system: .nztm2000 // Using NZTM for Phase 3
                ))
            }

            // Debug: Log NZTM2000 coordinates before inverse transform
            if !hullVerticesProjected.isEmpty {
                let first = hullVerticesProjected[0]
                logger.info("🔍 INVERSE-DEBUG: Cluster \(clusterIndex) NZTM2000 input: (\(first.x), \(first.y))")
            }

            // Batch inverse transform hull vertices to lat/lon
            let hullVerticesLatLon = transformer.batchInverseTransform(hullVerticesProjected)

            // Debug: Log GPS coordinates after inverse transform
            if !hullVerticesLatLon.isEmpty {
                let first = hullVerticesLatLon[0]
                logger.info("🔍 INVERSE-DEBUG: Cluster \(clusterIndex) GPS output: (\(first.latitude), \(first.longitude))")
            }

            // Calculate confidence ratio
            let confidence = confidencePair.y > 0 ? Double(confidencePair.x / confidencePair.y) : 0.0

            // Skip clusters with very low confidence or degenerate hulls
            let minConfidence = 0.02 // 2% minimum confidence threshold - more permissive
            if confidence < minConfidence {
                logger.info("🔍 Skipping cluster with low confidence: \(String(format: "%.3f", confidence)) < \(minConfidence)")
                continue
            }

            // Handle clusters with degenerate or excessive hulls
            var hullCoordinates: [CLLocationCoordinate2D] = []
            var actualConfidence = confidence

            if hullCount == 0 {
                logger.warning("🚨 QuickHull failed for cluster with \(clusterDevices.count) devices - using fallback")
                hullCoordinates = generateFallbackHull(
                    clusterIndex: clusterIndex,
                    devices: clusterDevices
                )
                actualConfidence = 0.75  // Fixed confidence for fallback hull
            } else if hullCount > 200 {
                logger.warning("⚠️ Hull too complex (\(hullCount) vertices) - using simplified fallback")
                hullCoordinates = generateFallbackHull(
                    clusterIndex: clusterIndex,
                    devices: clusterDevices
                )
                actualConfidence = 0.50  // Lower confidence for simplified hull
            } else {
                // Normal hull processing - transform vertices to lat/lon
                let hullVerticesLatLon = transformer.batchInverseTransform(hullVerticesProjected)
                hullCoordinates = hullVerticesLatLon.map { coord in
                    CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude)
                }
            }

            // Skip empty hulls (shouldn't happen with fallback, but safety check)
            if hullCoordinates.isEmpty {
                logger.error("❌ Both QuickHull and fallback failed for cluster \(clusterIndex)")
                continue
            }

            // Transform all device coordinates to projected coordinates for DeviceCluster
            let deviceCoordinates = clusterDevices.map { device in
                CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
            }
            let projectedCoordinates = try transformer.batchTransform(deviceCoordinates)

            // Ensure clockwise ordering for MKPolygon compatibility (only if we have enough vertices)
            if hullCoordinates.count >= 3 && !isClockwise(coordinates: hullCoordinates) {
                hullCoordinates.reverse()
                logger.debug("🔄 Reversed hull vertices for clockwise ordering - cluster \(clusterIndex)")
            }

            // Create DeviceCluster with Phase 3 polygon and confidence data
            let deviceCluster = DeviceCluster(
                clusterId: clusterIndex,
                devices: clusterDevices, // PowerSenseDeviceDTO conforms to SpatialDevice
                projectedCoordinates: projectedCoordinates,
                projectionSystem: .nztm2000,
                confidenceRating: actualConfidence,
                totalDevicesInArea: Int(confidencePair.y), // Total devices from GPU confidence calculation
                hullVertices: hullCoordinates
            )

            // Log Phase 3 metrics with polygon creation status
            let hasPolygon = deviceCluster.polygon != nil
            let actualHullCount = hullCoordinates.count
            logger.debug("🔺 Cluster \(clusterIndex): \(actualHullCount) hull vertices, confidence: \(String(format: "%.2f", actualConfidence)), polygon: \(hasPolygon ? "✓" : "✗")")

            if actualHullCount >= 3 && !hasPolygon {
                logger.warning("⚠️ Cluster \(clusterIndex) has \(actualHullCount) hull vertices but no polygon created!")
            }

            enhancedClusters.append(deviceCluster)
        }

        logger.info("📈 Phase 3 complete: \(enhancedClusters.count) clusters with hulls & confidence")
        return enhancedClusters
    }

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

    /// Log hull generation metrics for debugging and performance analysis
    private func logHullGenerationMetrics(
        _ clusters: [(Int32, [PowerSenseDeviceDTO])],
        _ hullResult: GPUHullAndConfidenceResult
    ) async {
        logger.info("🔍 Hull Generation Debug Metrics:")

        // Read hull counts from GPU buffer
        let hullCountsPointer = hullResult.hullBuffers.hullCounts.buffer.contents().bindMemory(to: Int32.self, capacity: clusters.count)
        let hullCounts = Array(UnsafeBufferPointer(start: hullCountsPointer, count: clusters.count))

        // Read confidence data
        let confidencePairsPointer = hullResult.hullBuffers.confidencePairs.buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: clusters.count)
        let confidencePairs = Array(UnsafeBufferPointer(start: confidencePairsPointer, count: clusters.count))

        // Analyze results
        let totalClusters = clusters.count
        let zeroClusters = hullCounts.filter { $0 == 0 }.count
        let validClusters = hullCounts.filter { $0 >= 3 }.count
        let excessiveClusters = hullCounts.filter { $0 > 50 }.count
        let avgVertices = validClusters > 0 ? Double(hullCounts.filter { $0 > 0 }.reduce(0, +)) / Double(validClusters) : 0.0
        let maxVertices = hullCounts.max() ?? 0

        logger.info("📊 Hull Vertex Analysis:")
        logger.info("  • Total clusters: \(totalClusters)")
        logger.info("  • Valid hulls (≥3 vertices): \(validClusters)")
        logger.info("  • Degenerate hulls (0 vertices): \(zeroClusters)")
        logger.info("  • Excessive hulls (>50 vertices): \(excessiveClusters)")
        logger.info("  • Average vertices: \(String(format: "%.1f", avgVertices))")
        logger.info("  • Maximum vertices: \(maxVertices)")

        // Log specific problematic clusters
        for (index, (clusterLabel, devices)) in clusters.enumerated() {
            let hullCount = hullCounts[index]
            let confidence = confidencePairs[index].y > 0 ? confidencePairs[index].x / confidencePairs[index].y : 0.0

            if hullCount == 0 {
                logger.warning("🚨 Cluster \(clusterLabel): DEGENERATE hull (0 vertices) from \(devices.count) devices")
            } else if hullCount > 50 {
                logger.warning("⚠️ Cluster \(clusterLabel): EXCESSIVE hull (\(hullCount) vertices) from \(devices.count) devices")
            } else if confidence == 0.0 {
                logger.warning("🔍 Cluster \(clusterLabel): Zero confidence - hull: \(hullCount)v, devices: \(devices.count)")
            }
        }

        // Performance metrics
        logger.info("⏱️ Performance Breakdown:")
        logger.info("  • Total GPU time: \(String(format: "%.1f", hullResult.totalTime * 1000))ms")
        logger.info("  • Sort time: \(String(format: "%.1f", hullResult.sortTime * 1000))ms")
        logger.info("  • Hull compute time: \(String(format: "%.1f", hullResult.hullTime * 1000))ms")
        logger.info("  • Confidence time: \(String(format: "%.1f", hullResult.confidenceTime * 1000))ms")
        logger.info("  • Clusters processed: \(hullResult.clustersProcessed)")
        logger.info("  • Average vertices: \(String(format: "%.1f", avgVertices))")
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

    /// Debug coordinate buffer contents safely
    private func debugCoordinateBuffer(coordsBuffer: SendableBuffer, context: String) async {
        let bufferCapacity = coordsBuffer.length / MemoryLayout<SIMD2<Float>>.size
        let coordsPointer = coordsBuffer.buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: bufferCapacity)

        logger.info("📊 \(context) Buffer Info:")
        logger.info("   Buffer Length: \(coordsBuffer.length) bytes (\(bufferCapacity) coordinates)")

        // Sample first few coordinates safely
        if bufferCapacity > 0 {
            let sampleCount = min(bufferCapacity, 10)
            let coords = Array(UnsafeBufferPointer(start: coordsPointer, count: sampleCount))

            if !coords.isEmpty {
                let minX = coords.map { $0.x }.min() ?? 0
                let maxX = coords.map { $0.x }.max() ?? 0
                let minY = coords.map { $0.y }.min() ?? 0
                let maxY = coords.map { $0.y }.max() ?? 0

                logger.info("📍 \(context) Coordinate Sample (\(sampleCount) points):")
                logger.info("   X range: [\(String(format: "%.6f", minX)), \(String(format: "%.6f", maxX))] (span: \(String(format: "%.6f", maxX - minX)))")
                logger.info("   Y range: [\(String(format: "%.6f", minY)), \(String(format: "%.6f", maxY))] (span: \(String(format: "%.6f", maxY - minY)))")

                // Show first 3 actual coordinates
                let displayCount = min(coords.count, 3)
                for i in 0..<displayCount {
                    logger.info("   Point \(i): (\(String(format: "%.6f", coords[i].x)), \(String(format: "%.6f", coords[i].y)))")
                }

                // Check for degenerate coordinates
                if abs(maxX - minX) < 0.001 && abs(maxY - minY) < 0.001 {
                    logger.error("❌ \(context): DEGENERATE coordinates - all points collapsed!")
                } else {
                    logger.info("✅ \(context): Valid coordinate spread detected")
                }
            } else {
                logger.error("❌ \(context): No coordinates found in buffer")
            }
        } else {
            logger.error("❌ \(context): Empty coordinate buffer")
        }
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
