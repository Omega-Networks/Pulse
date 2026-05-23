//
//  SpatialClusteringSystem.swift
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

public import CoreLocation
import MapKit
import OSLog
import Metal

// MARK: - PowerSenseDevice Protocol

/// Protocol defining the minimum requirements for spatial clustering
public protocol SpatialDevice {
    var deviceId: String { get }
    var latitude: Double { get }
    var longitude: Double { get }
    var isOffline: Bool? { get }
}

// MARK: - Spatial Clustering Types

public struct DeviceCluster: Identifiable, @unchecked Sendable {
    public let id: Int
    public let clusterId: Int
    public let devices: [any SpatialDevice]
    public let centroid: ProjectedCoordinate
    public let boundingBox: BoundingBox
    public let severity: ClusterSeverity

    // Cache geographic coordinate to avoid repeated GPU transformations
    public let centroidCoordinate: CLLocationCoordinate2D

    // Confidence metrics for cluster quality assessment
    public let confidenceRating: Double    // 0.0 to 1.0 (offline devices / total devices in cluster area)
    public let totalDevicesInArea: Int     // Total devices considered for this cluster

    // Phase 3: Visualization polygons for MapKit rendering
    internal let polygon: MKPolygon?         // Convex hull polygon for map overlays
    public let hullVertices: [CLLocationCoordinate2D] // Raw hull vertices for debugging/export

    // Phase 4: Gradient layers for intensity visualization
    public let gradientLayers: [[CLLocationCoordinate2D]] // Multiple buffered polygons for gradient effect

    // Phase 5: Outage timing with anomaly filtering
    public let outageStartTime: Date?        // Median start time (outliers >7 days filtered)
    public let outageDuration: TimeInterval  // Time since filtered start time

    // Computed property for MapView compatibility
    public var deviceCount: Int { devices.count }

    public enum ClusterSeverity: Sendable {
        case minor      // 3-9 devices
        case moderate   // 10-49 devices
        case major      // 50-199 devices
        case critical   // 200+ devices
        
        public var priority: Int {
            switch self {
            case .minor: return 1
            case .moderate: return 2
            case .major: return 3
            case .critical: return 4
            }
        }
    }
    
    public init(clusterId: Int, devices: [any SpatialDevice], projectedCoordinates: [ProjectedCoordinate], projectionSystem: ProjectionSystem, confidenceRating: Double = 1.0, totalDevicesInArea: Int = 0, hullVertices: [CLLocationCoordinate2D] = [], gradientLayers: [[CLLocationCoordinate2D]] = [], outageStartTime: Date? = nil, outageDuration: TimeInterval = 0) {
        self.id = clusterId
        self.clusterId = clusterId
        self.devices = devices
        self.confidenceRating = confidenceRating
        self.totalDevicesInArea = totalDevicesInArea > 0 ? totalDevicesInArea : devices.count
        self.outageStartTime = outageStartTime
        self.outageDuration = outageDuration
        self.gradientLayers = gradientLayers

        guard !projectedCoordinates.isEmpty else {
            self.centroid = ProjectedCoordinate(x: 0, y: 0, system: projectionSystem)
            self.boundingBox = BoundingBox(minX: 0, maxX: 0, minY: 0, maxY: 0, projectionSystem: projectionSystem)
            self.centroidCoordinate = CLLocationCoordinate2D()
            self.severity = .minor
            self.hullVertices = []
            self.polygon = nil
            return
        }

        // Calculate centroid using pre-transformed coordinates
        let xSum = projectedCoordinates.map(\.x).reduce(0, +)
        let ySum = projectedCoordinates.map(\.y).reduce(0, +)
        self.centroid = ProjectedCoordinate(
            x: xSum / Double(projectedCoordinates.count),
            y: ySum / Double(projectedCoordinates.count),
            system: projectionSystem
        )

        // Convert projected centroid back to geographic coordinates using inverse transform
        self.centroidCoordinate = CLLocationCoordinate2D(
            latitude: centroid.y / 111000.0,  // Simplified conversion for Phase 1 compatibility
            longitude: centroid.x / 111000.0
        )

        // Calculate bounding box using pre-transformed coordinates
        let minX = projectedCoordinates.map(\.x).min() ?? 0
        let maxX = projectedCoordinates.map(\.x).max() ?? 0
        let minY = projectedCoordinates.map(\.y).min() ?? 0
        let maxY = projectedCoordinates.map(\.y).max() ?? 0

        self.boundingBox = BoundingBox(
            minX: minX, maxX: maxX,
            minY: minY, maxY: maxY,
            projectionSystem: projectionSystem
        )

        // Determine severity
        switch devices.count {
        case 3..<10:
            self.severity = .minor
        case 10..<50:
            self.severity = .moderate
        case 50..<200:
            self.severity = .major
        default:
            self.severity = .critical
        }

        // Phase 3: Initialize hull vertices and polygon
        self.hullVertices = hullVertices
        if hullVertices.count >= 3 {
            // Create MKPolygon from hull vertices (ensure clockwise for proper rendering)
            self.polygon = MKPolygon(coordinates: hullVertices, count: hullVertices.count)
        } else {
            self.polygon = nil
        }
    }
}

public struct BoundingBox: Sendable {
    public let minX, maxX, minY, maxY: Double
    public let projectionSystem: ProjectionSystem

    public init(minX: Double, maxX: Double, minY: Double, maxY: Double, projectionSystem: ProjectionSystem) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.projectionSystem = projectionSystem
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var area: Double { width * height }

    public var center: ProjectedCoordinate {
        return ProjectedCoordinate(
            x: (minX + maxX) / 2,
            y: (minY + maxY) / 2,
            system: projectionSystem
        )
    }

    public func contains(_ coordinate: ProjectedCoordinate) -> Bool {
        guard coordinate.system == projectionSystem else { return false }
        return coordinate.x >= minX && coordinate.x <= maxX &&
               coordinate.y >= minY && coordinate.y <= maxY
    }

    public func expanded(by padding: Double) -> BoundingBox {
        return BoundingBox(
            minX: minX - padding,
            maxX: maxX + padding,
            minY: minY - padding,
            maxY: maxY + padding,
            projectionSystem: projectionSystem
        )
    }

    public func intersects(_ other: BoundingBox) -> Bool {
        guard projectionSystem == other.projectionSystem else { return false }
        return !(maxX < other.minX || minX > other.maxX ||
                maxY < other.minY || minY > other.maxY)
    }

    public func union(with other: BoundingBox) -> BoundingBox? {
        guard projectionSystem == other.projectionSystem else { return nil }
        return BoundingBox(
            minX: min(minX, other.minX), maxX: max(maxX, other.maxX),
            minY: min(minY, other.minY), maxY: max(maxY, other.maxY),
            projectionSystem: projectionSystem
        )
    }
}

// MARK: - GPU Spatial Index Manager (Phase 1)

/// GPU-accelerated spatial index manager using uniform grid
public actor GPUSpatialIndexManager<SpatialDeviceType: SpatialDevice & Sendable> {

    private let transformer: CoordinateTransformer
    private var cachedProjectedCoordinates: [String: ProjectedCoordinate] = [:]
    private var indexedDevices: [SpatialDeviceType] = []
    private var gridParams: GridIndexParameters?
    private var neighborResults: [GPUNeighborResult] = []
    private var metrics = SpatialIndexMetrics()
    private let logger = Logger.spatialIndexing

    // GPU buffers for on-demand neighbor queries
    private var gpuCoordsBuffer: SendableBuffer?
    private var gpuOfflineFlagsBuffer: SendableBuffer?
    private var gpuGrid: GPUGrid?
    private var deviceIdToIndex: [String: Int] = [:] // Maps deviceId to GLOBAL index in full coords buffer
    // Phase 1: Eliminated separate offline indices - using full coordinate buffer with flags

    private var _isIndexReady = false

    public var deviceCount: Int { indexedDevices.count }
    public var isIndexReady: Bool { _isIndexReady }
    public var performanceMetrics: SpatialIndexMetrics { metrics }

    public init(transformer: CoordinateTransformer) {
        self.transformer = transformer
        logger.info("🏗️ GPUSpatialIndexManager initialized")
    }

    public func buildIndex(devices: [SpatialDeviceType]) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("🚀 Building GPU spatial index for \(devices.count) devices...")

        _isIndexReady = false

        // Validate devices
        let validDevices = devices.validCoordinateDevices
        guard !validDevices.isEmpty else {
            throw ClusteringError.insufficientData(deviceCount: devices.count, minimum: 1)
        }

        // Transform all coordinates in batch for efficiency
        let coordinates = validDevices.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let projectedCoords = try transformer.batchTransform(coordinates)

        // Cache all projected coordinates
        cachedProjectedCoordinates.removeAll(keepingCapacity: true)
        for (index, device) in validDevices.enumerated() {
            cachedProjectedCoordinates[device.deviceId] = projectedCoords[index]
        }

        // Store all devices and filter offline for indexing
        indexedDevices = validDevices
        let offlineDevices = validDevices.offlineDevices

        logger.info("📊 Indexing \(offlineDevices.count) offline devices from \(validDevices.count) valid devices")

        if !validDevices.isEmpty {
            // Phase 1 Update: Index ALL projected coordinates with offline flags
            let allCoords = validDevices.compactMap { cachedProjectedCoordinates[$0.deviceId] }
            let offlineFlags = validDevices.map { $0.isOffline == true }

            logger.info("🔧 Phase 1: Building GPU grid with \(allCoords.count) coordinates, \(offlineFlags.filter { $0 }.count) offline")

            // Build persistent GPU grid with ALL coordinates and offline flags
            let (params, grid, coordsBuffer, offlineFlagsBuffer) = try transformer.buildPersistentGPUGrid(
                allCoordinates: allCoords, // ALL device coordinates for full grid coverage
                offlineFlags: offlineFlags, // Offline status for selective processing
                epsilon: 500.0
            )

            // Store GPU structures for on-demand queries
            self.gridParams = params
            self.gpuGrid = grid
            self.gpuCoordsBuffer = SendableBuffer(coordsBuffer)
            self.gpuOfflineFlagsBuffer = SendableBuffer(offlineFlagsBuffer)

            // Phase 1 Update: Build device ID to GLOBAL index mapping (for full coords buffer)
            self.deviceIdToIndex = Dictionary(uniqueKeysWithValues:
                validDevices.enumerated().map { (globalIndex, device) in (device.deviceId, globalIndex) }
            )

            // Phase 1 uses full coordinate buffer with offline flags

            // On-demand GPU queries eliminate need for precomputed neighbor results
            self.neighborResults = []
        } else {
            self.gridParams = nil
            self.gpuGrid = nil
            self.gpuCoordsBuffer = nil
            self.gpuOfflineFlagsBuffer = nil
            self.deviceIdToIndex = [:]
            self.neighborResults = []
        }

        _isIndexReady = true
        let buildTime = CFAbsoluteTimeGetCurrent() - startTime
        metrics.indexBuildTime = buildTime
        metrics.memoryUsage = estimateMemoryUsage()

        logger.info("GPU spatial index built in \(String(format: "%.3f", buildTime))s")
    }

    // MARK: - Neighbor Search (GPU Results)

    public func findNeighbors(for deviceId: String, within epsilon: Double) async throws -> [SpatialDeviceType] {
    let startTime = CFAbsoluteTimeGetCurrent()

    guard isIndexReady else {
        throw ClusteringError.indexingFailed("Index not ready for queries")
    }

    guard cachedProjectedCoordinates[deviceId] != nil else {
        throw ClusteringError.invalidCoordinates(deviceId: deviceId, latitude: 0, longitude: 0)
    }

    // GPU-only neighbor search using grid index
    guard let queryIndex = deviceIdToIndex[deviceId],
          let params = gridParams,
          let grid = gpuGrid,
          let coordsBuffer = gpuCoordsBuffer else {
        throw ClusteringError.invalidCoordinates(deviceId: deviceId, latitude: 0, longitude: 0)
    }


    // Dispatch GPU kernel for neighbor search
    let neighborIndices = try transformer.executeFindNeighborsKernel(
        coordsBuffer: coordsBuffer.buffer,
        grid: grid,
        gridParams: params,
        queryId: queryIndex
    )

    // Map indices back to device objects using the same indexing as GPU
    let neighbors: [SpatialDeviceType] = neighborIndices.compactMap { index in
        guard index < indexedDevices.count else { return nil }
        return indexedDevices[index]
    }.filter { $0.isOffline == true }

    // GPU neighbor search complete

    let queryTime = CFAbsoluteTimeGetCurrent() - startTime
    metrics.queryCount += 1
    metrics.lastQueryTime = queryTime
    metrics.averageQueryTime = (metrics.averageQueryTime * Double(metrics.queryCount - 1) + queryTime) / Double(metrics.queryCount)

    logger.debug("🔍 Found \(neighbors.count) neighbors for device \(deviceId) within \(epsilon)m in \(String(format: "%.6f", queryTime))s")

    return neighbors
}

    public func findNeighbors(at coordinate: CLLocationCoordinate2D, within epsilon: Double) async throws -> [SpatialDeviceType] {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard isIndexReady else {
            throw ClusteringError.indexingFailed("Index not ready for queries")
        }

        // Transform query coordinate
        let queryProjected = transformer.transform(coordinate)

        let offlineDevices = indexedDevices.offlineDevices
        var neighbors: [SpatialDeviceType] = []
        let epsilonSquared = epsilon * epsilon

        for device in offlineDevices {
            guard let deviceCoord = cachedProjectedCoordinates[device.deviceId] else { continue }

            let distanceSquared = queryProjected.distanceSquared(to: deviceCoord)
            if distanceSquared <= epsilonSquared {
                neighbors.append(device)
            }
        }

        let queryTime = CFAbsoluteTimeGetCurrent() - startTime
        metrics.queryCount += 1
        metrics.lastQueryTime = queryTime
        metrics.averageQueryTime = (metrics.averageQueryTime * Double(metrics.queryCount - 1) + queryTime) / Double(metrics.queryCount)

        logger.debug("🎯 Found \(neighbors.count) neighbors at coordinate (\(coordinate.latitude), \(coordinate.longitude)) within \(epsilon)m")

        return neighbors
    }

    public func queryDevices(in region: GeographicBounds) async throws -> [SpatialDeviceType] {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard isIndexReady else {
            throw ClusteringError.indexingFailed("Index not ready for queries")
        }

        let devicesInRegion = indexedDevices.filter { device in
            let coordinate = CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
            return region.contains(coordinate)
        }

        let queryTime = CFAbsoluteTimeGetCurrent() - startTime
        metrics.queryCount += 1
        metrics.lastQueryTime = queryTime
        metrics.averageQueryTime = (metrics.averageQueryTime * Double(metrics.queryCount - 1) + queryTime) / Double(metrics.queryCount)

        logger.debug("📍 Found \(devicesInRegion.count) devices in region")

        return devicesInRegion
    }

    // MARK: - Data Access Methods

    /// Get all indexed devices (legacy method for backward compatibility)
    public func getAllDevices() -> [SpatialDeviceType] {
        return indexedDevices
    }

    /// Get cached projected coordinates for devices
    public func getProjectedCoordinates(for deviceIds: [String]) -> [ProjectedCoordinate] {
        return deviceIds.compactMap { cachedProjectedCoordinates[$0] }
    }

    /// Get all cached projected coordinates
    public func getAllProjectedCoordinates() -> [String: ProjectedCoordinate] {
        return cachedProjectedCoordinates
    }

    /// Get GPU neighbor results for analysis
    public func getGPUNeighborResults() -> [GPUNeighborResult] {
        return neighborResults
    }

    /// Get grid parameters
    public func getGridParameters() -> GridIndexParameters? {
        return gridParams
    }

    // MARK: - GPU Buffer Access (for testing and DBSCAN integration)

    /// Get GPU coordinates buffer for DBSCAN processing
    internal func getGPUCoordsBuffer() -> SendableBuffer? {
        return gpuCoordsBuffer
    }

    /// Get GPU offline flags buffer for DBSCAN processing
    internal func getGPUOfflineFlagsBuffer() -> SendableBuffer? {
        return gpuOfflineFlagsBuffer
    }

    /// Get GPU grid structure for DBSCAN processing
    internal func getGPUGrid() -> GPUGrid? {
        return gpuGrid
    }

    /// Get coordinate transformer for DBSCAN processing
    internal func getTransformer() -> CoordinateTransformer {
        return transformer
    }

    // MARK: - Private Helpers

    private func estimateMemoryUsage() -> Int {
        let coordinatesCacheSize = cachedProjectedCoordinates.count * MemoryLayout<ProjectedCoordinate>.size
        let devicesSize = indexedDevices.count * MemoryLayout<SpatialDeviceType>.size
        let gridParamsSize = gridParams != nil ? MemoryLayout<GridIndexParameters>.size : 0
        let neighborResultsSize = neighborResults.count * MemoryLayout<GPUNeighborResult>.size

        return coordinatesCacheSize + devicesSize + gridParamsSize + neighborResultsSize
    }
}

// MARK: - GPU-Only Architecture
// Pure GPU implementation with Metal compute shaders
// All CPU fallbacks and legacy components have been removed



// MARK: - Supporting Types

public struct GeographicBounds: Sendable {
    public let minLatitude, maxLatitude: Double
    public let minLongitude, maxLongitude: Double

    public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    public func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        return coordinate.latitude >= minLatitude &&
               coordinate.latitude <= maxLatitude &&
               coordinate.longitude >= minLongitude &&
               coordinate.longitude <= maxLongitude
    }
}

// MARK: - Performance Metrics

public struct ClusteringMetrics {
    public let totalDevices: Int
    public let offlineDevices: Int
    public let clustersFound: Int
    public let largestClusterSize: Int
    public let indexBuildTime: Double
    public let clusteringTime: Double
    public let totalTime: Double
    
    public var description: String {
        return """
        Clustering Performance:
        - Total devices: \(totalDevices)
        - Offline devices: \(offlineDevices)
        - Clusters found: \(clustersFound)
        - Largest cluster: \(largestClusterSize) devices
        - Index build: \(String(format: "%.3f", indexBuildTime))s
        - Clustering: \(String(format: "%.3f", clusteringTime))s
        - Total time: \(String(format: "%.3f", totalTime))s
        """
    }
}

// GPU-only architecture - All validation performed via Metal kernels
