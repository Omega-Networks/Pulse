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

import Foundation
import GameplayKit
public import MapKit
import simd
import CoreLocation

// MARK: - PowerSenseDevice Protocol

/// Protocol defining the minimum requirements for spatial clustering
public protocol SpatialDevice {
    var deviceId: String { get }
    var latitude: Double { get }
    var longitude: Double { get }
    var isOffline: Bool? { get }
}

// MARK: - Spatial Clustering Types

public struct DeviceCluster: Identifiable {
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
    
    public init(clusterId: Int, devices: [any SpatialDevice], projectedCoordinates: [ProjectedCoordinate], projectionSystem: ProjectionSystem, confidenceRating: Double = 1.0, totalDevicesInArea: Int = 0) {
        self.id = clusterId
        self.clusterId = clusterId
        self.devices = devices
        self.confidenceRating = confidenceRating
        self.totalDevicesInArea = totalDevicesInArea > 0 ? totalDevicesInArea : devices.count

        guard !projectedCoordinates.isEmpty else {
            self.centroid = ProjectedCoordinate(x: 0, y: 0, system: projectionSystem)
            self.boundingBox = BoundingBox(minX: 0, maxX: 0, minY: 0, maxY: 0, projectionSystem: projectionSystem)
            self.centroidCoordinate = CLLocationCoordinate2D()
            self.severity = .minor
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

        // Pre-compute geographic coordinate to avoid repeated GPU transformations
        self.centroidCoordinate = CoordinateTransformerManager.shared.inverseTransform(self.centroid)

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

// MARK: - Spatial Index Manager

public final class SpatialIndexManager {

    private let transformer: CoordinateTransformer
    private let quadTree: GKQuadtree<GKAgent2D>
    private let indexedDevices: [String: (device: any SpatialDevice, agent: GKAgent2D)]
    private let agentToDeviceMap: [ObjectIdentifier: String] // Reverse lookup for O(1) performance
    private let cachedProjectedCoordinates: [String: ProjectedCoordinate] // Cached transformations
    
    public init(devices: [any SpatialDevice], projectionSystem: ProjectionSystem = .nztm2000) throws {
        self.transformer = try CoordinateTransformer(projectionSystem: projectionSystem)
        
        print("Building spatial index for \(devices.count) devices...")
        
        // Transform all coordinates in batch for efficiency
        let coordinates = devices.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let projectedCoords = try transformer.batchTransform(coordinates)
        
        // Calculate bounds for quad tree
        let minX = projectedCoords.map(\.x).min() ?? 0
        let maxX = projectedCoords.map(\.x).max() ?? 0
        let minY = projectedCoords.map(\.y).min() ?? 0
        let maxY = projectedCoords.map(\.y).max() ?? 0
        
        // Add padding to bounds
        let padding = 10000.0 // 10km padding
        let quadTreeBounds = GKQuad(
            quadMin: vector_float2(Float(minX - padding), Float(minY - padding)),
            quadMax: vector_float2(Float(maxX + padding), Float(maxY + padding))
        )
        
        // Create quad tree with optimal cell size
        let cellSize = Float(min(500.0, (maxX - minX) / 100.0)) // Adaptive cell size
        self.quadTree = GKQuadtree<GKAgent2D>(boundingQuad: quadTreeBounds, minimumCellSize: cellSize)
        
        // Build device index, reverse lookup, and cached coordinates
        var deviceIndex: [String: (device: any SpatialDevice, agent: GKAgent2D)] = [:]
        var reverseAgentMap: [ObjectIdentifier: String] = [:]
        var coordinateCache: [String: ProjectedCoordinate] = [:]

        for (index, device) in devices.enumerated() {
            let projectedCoord = projectedCoords[index]
            let agent = GKAgent2D()

            agent.position = projectedCoord.vector2
            agent.maxSpeed = 0 // Static devices

            // Store device reference and build reverse lookup
            deviceIndex[device.deviceId] = (device: device, agent: agent)
            reverseAgentMap[ObjectIdentifier(agent)] = device.deviceId
            coordinateCache[device.deviceId] = projectedCoord

            // Add to quad tree
            quadTree.add(agent, at: projectedCoord.vector2)
        }

        self.indexedDevices = deviceIndex
        self.agentToDeviceMap = reverseAgentMap
        self.cachedProjectedCoordinates = coordinateCache
        
        print("Spatial index built: \(devices.count) devices indexed")
        print("Quad tree bounds: (\(minX), \(minY)) to (\(maxX), \(maxY))")
        print("Cell size: \(cellSize)m")
    }
    
    // MARK: - Neighbor Search
    
    public func findNeighbors(for deviceId: String, within radius: Double) -> [any SpatialDevice] {
        guard let (_, agent) = indexedDevices[deviceId] else { return [] }

        let searchRadius = Float(radius)
        let searchBounds = GKQuad(
            quadMin: vector_float2(agent.position.x - searchRadius, agent.position.y - searchRadius),
            quadMax: vector_float2(agent.position.x + searchRadius, agent.position.y + searchRadius)
        )

        let nearbyAgents = quadTree.elements(in: searchBounds)
        let radiusSquared = radius * radius

        var neighbors: [any SpatialDevice] = []

        for nearbyAgent in nearbyAgents {
            // Calculate actual distance
            let dx = Double(agent.position.x - nearbyAgent.position.x)
            let dy = Double(agent.position.y - nearbyAgent.position.y)
            let distanceSquared = dx * dx + dy * dy

            if distanceSquared <= radiusSquared {
                // O(1) lookup using reverse dictionary
                if let nearbyDeviceId = agentToDeviceMap[ObjectIdentifier(nearbyAgent)],
                   let (device, _) = indexedDevices[nearbyDeviceId] {
                    neighbors.append(device)
                }
            }
        }

        return neighbors
    }
    
    public func getAllDevices() -> [any SpatialDevice] {
        return indexedDevices.values.map { $0.device }
    }

    /// Get cached projected coordinates for devices
    public func getProjectedCoordinates(for deviceIds: [String]) -> [ProjectedCoordinate] {
        return deviceIds.compactMap { cachedProjectedCoordinates[$0] }
    }

    /// Get all cached projected coordinates
    public func getAllProjectedCoordinates() -> [String: ProjectedCoordinate] {
        return cachedProjectedCoordinates
    }
}

// MARK: - DBSCAN Clustering Implementation

public final class DBSCANClusterer {
    
    public struct Parameters: Sendable {
        public let epsilon: Double      // Search radius in meters
        public let minPoints: Int       // Minimum points to form a cluster

        public init(epsilon: Double = 500.0, minPoints: Int = 3) {
            self.epsilon = epsilon
            self.minPoints = minPoints
        }

        // Predefined parameter sets for different scenarios
        public static let urban = Parameters(epsilon: 300.0, minPoints: 4)
        public static let suburban = Parameters(epsilon: 500.0, minPoints: 3)
        public static let rural = Parameters(epsilon: 1000.0, minPoints: 2)
    }
    
    private let spatialIndex: SpatialIndexManager
    private let parameters: Parameters
    
    public init(spatialIndex: SpatialIndexManager, parameters: Parameters = Parameters()) {
        self.spatialIndex = spatialIndex
        self.parameters = parameters
    }
    
    // MARK: - DBSCAN Implementation
    
    public func clusterOfflineDevices() -> [DeviceCluster] {
        print("Starting DBSCAN clustering...")
        print("Parameters: epsilon=\(parameters.epsilon)m, minPoints=\(parameters.minPoints)")
        
        let offlineDevices = spatialIndex.getAllDevices().filter { $0.isOffline == true }
        print("Found \(offlineDevices.count) offline devices to cluster")
        
        guard !offlineDevices.isEmpty else { return [] }
        
        var visited = Set<String>()
        var clusters: [Int: [any SpatialDevice]] = [:]
        var noise: Set<String> = []
        var currentClusterId = 0
        
        for device in offlineDevices {
            guard !visited.contains(device.deviceId) else { continue }
            
            visited.insert(device.deviceId)
            
            let neighbors = spatialIndex.findNeighbors(for: device.deviceId, within: parameters.epsilon)
            
            if neighbors.count < parameters.minPoints {
                noise.insert(device.deviceId)
            } else {
                // Start new cluster
                currentClusterId += 1
                expandCluster(
                    device: device,
                    neighbors: neighbors,
                    clusterId: currentClusterId,
                    visited: &visited,
                    clusters: &clusters,
                    noise: &noise
                )
            }
        }
        
        print("DBSCAN completed: \(clusters.count) clusters, \(noise.count) noise points")
        
        // Convert to DeviceCluster objects using cached coordinates with confidence ratings
        return clusters.map { clusterId, devices in
            let deviceIds = devices.map { $0.deviceId }
            let projectedCoords = spatialIndex.getProjectedCoordinates(for: deviceIds)

            // Calculate confidence based on cluster representative device
            var confidenceRating = 1.0  // Default high confidence
            var totalDevicesInArea = devices.count

            if let representativeDevice = devices.first {
                let allNeighbors = spatialIndex.findNeighbors(for: representativeDevice.deviceId, within: parameters.epsilon)
                let offlineNeighbors = allNeighbors.filter { $0.isOffline == true }

                totalDevicesInArea = allNeighbors.count
                confidenceRating = totalDevicesInArea > 0 ? Double(offlineNeighbors.count) / Double(totalDevicesInArea) : 1.0
            }

            return DeviceCluster(
                clusterId: clusterId,
                devices: devices,
                projectedCoordinates: projectedCoords,
                projectionSystem: .nztm2000,
                confidenceRating: confidenceRating,
                totalDevicesInArea: totalDevicesInArea
            )
        }.sorted { $0.severity.priority > $1.severity.priority }
    }
    
    private func expandCluster(
        device: any SpatialDevice,
        neighbors: [any SpatialDevice],
        clusterId: Int,
        visited: inout Set<String>,
        clusters: inout [Int: [any SpatialDevice]],
        noise: inout Set<String>
    ) {
        clusters[clusterId, default: []].append(device)
        
        var neighborQueue = neighbors
        var queueIndex = 0
        
        while queueIndex < neighborQueue.count {
            let currentNeighbor = neighborQueue[queueIndex]
            queueIndex += 1
            
            if !visited.contains(currentNeighbor.deviceId) {
                visited.insert(currentNeighbor.deviceId)
                
                let newNeighbors = spatialIndex.findNeighbors(for: currentNeighbor.deviceId, within: parameters.epsilon)
                
                if newNeighbors.count >= parameters.minPoints {
                    neighborQueue.append(contentsOf: newNeighbors)
                }
            }
            
            // If point is not yet in any cluster AND is offline, add it to current cluster
            let isInAnyCluster = clusters.values.contains { clusterDevices in
                clusterDevices.contains { $0.deviceId == currentNeighbor.deviceId }
            }

            // CRITICAL: Only cluster offline devices
            if !isInAnyCluster && currentNeighbor.isOffline == true {
                clusters[clusterId, default: []].append(currentNeighbor)
                noise.remove(currentNeighbor.deviceId)
            }
        }
    }
}

// MARK: - Viewport-Based Clustering Manager

public final class OutageClusteringManager {
    
    private let transformer: CoordinateTransformer
    private var cachedSpatialIndex: SpatialIndexManager?
    private var lastViewportBounds: MKMapRect?
    
    public init(projectionSystem: ProjectionSystem = .nztm2000) throws {
        self.transformer = try CoordinateTransformer(projectionSystem: projectionSystem)
    }
    
    // MARK: - Main Clustering Interface
    
    public func clusterDevicesInViewport(
        devices: [any SpatialDevice],
        viewport: MKMapRect,
        paddingKm: Double = 1000.0,
        clusteringParameters: DBSCANClusterer.Parameters = .suburban
    ) async throws -> [DeviceCluster] {
        
        print("Clustering devices for viewport with \(paddingKm)km padding...")
        
        // Calculate padded bounds
        let paddedBounds = calculatePaddedBounds(viewport: viewport, paddingKm: paddingKm)
        
        // Filter devices within padded bounds
        let devicesInBounds = filterDevicesInBounds(devices: devices, bounds: paddedBounds)
        print("Filtered to \(devicesInBounds.count) devices within bounds")
        
        // Check if we need to rebuild spatial index
        let shouldRebuildIndex = cachedSpatialIndex == nil ||
                                 lastViewportBounds == nil ||
                                 !viewport.intersects(lastViewportBounds!)
        
        let spatialIndex: SpatialIndexManager
        if shouldRebuildIndex {
            print("Building new spatial index...")
            spatialIndex = try SpatialIndexManager(devices: devicesInBounds)
            cachedSpatialIndex = spatialIndex
            lastViewportBounds = viewport
        } else {
            print("Using cached spatial index...")
            spatialIndex = cachedSpatialIndex!
        }
        
        // Perform DBSCAN clustering
        let clusterer = DBSCANClusterer(spatialIndex: spatialIndex, parameters: clusteringParameters)
        let clusters = clusterer.clusterOfflineDevices()
        
        print("Found \(clusters.count) outage clusters")
        for cluster in clusters.prefix(5) {
            print("  Cluster \(cluster.clusterId): \(cluster.devices.count) devices (\(cluster.severity))")
        }
        
        return clusters
    }
    
    // MARK: - Bounds Calculation
    
    private func calculatePaddedBounds(viewport: MKMapRect, paddingKm: Double) -> GeographicBounds {
        // Convert MKMapRect to geographic bounds
        let topLeft = MKMapPoint(x: viewport.minX, y: viewport.minY)
        let bottomRight = MKMapPoint(x: viewport.maxX, y: viewport.maxY)
        
        let topLeftCoord = topLeft.coordinate
        let bottomRightCoord = bottomRight.coordinate
        
        // Apply padding in degrees (rough approximation)
        let paddingDegrees = paddingKm / 111.0 // Approximately 111km per degree
        
        return GeographicBounds(
            minLatitude: bottomRightCoord.latitude - paddingDegrees,
            maxLatitude: topLeftCoord.latitude + paddingDegrees,
            minLongitude: topLeftCoord.longitude - paddingDegrees,
            maxLongitude: bottomRightCoord.longitude + paddingDegrees
        )
    }
    
    private func filterDevicesInBounds(devices: [any SpatialDevice], bounds: GeographicBounds) -> [any SpatialDevice] {
        return devices.filter { device in
            device.latitude >= bounds.minLatitude &&
            device.latitude <= bounds.maxLatitude &&
            device.longitude >= bounds.minLongitude &&
            device.longitude <= bounds.maxLongitude
        }
    }
}

// MARK: - Supporting Types

public struct GeographicBounds {
    public let minLatitude, maxLatitude: Double
    public let minLongitude, maxLongitude: Double
    
    public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
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

// MARK: - Example PowerSenseDevice Implementation

public struct MockPowerSenseDevice: SpatialDevice {
    public let deviceId: String
    public let latitude: Double
    public let longitude: Double
    public let isOffline: Bool?
    
    public init(deviceId: String, latitude: Double, longitude: Double, isOffline: Bool?) {
        self.deviceId = deviceId
        self.latitude = latitude
        self.longitude = longitude
        self.isOffline = isOffline
    }
}
