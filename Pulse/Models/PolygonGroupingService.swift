//
//  PolygonGroupingService.swift
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

import Foundation
import CoreLocation
import MapKit
import OSLog

/// Advanced polygon grouping service with spatial grid-based clustering and hierarchical merging
/// Optimizes polygon rendering by intelligently grouping overlapping outage areas
actor PolygonGroupingService {

    private let logger = Logger(subsystem: "powersense", category: "polygonGrouping")

    // MARK: - Spatial Grid Configuration

    /// Spatial grid cell size in meters for efficient proximity queries
    private let spatialGridCellSize: CLLocationDistance = 500.0 // 500m cells

    /// Maximum distance for polygon grouping consideration
    private let maxGroupingDistance: CLLocationDistance = 1000.0 // 1km

    /// Minimum overlap ratio required for polygon merging (0.0-1.0)
    private let minOverlapRatio: Double = 0.15 // 15% overlap threshold

    /// Privacy compliance: minimum device count per polygon
    private let minDeviceCount: Int = 3

    // MARK: - Main Processing Pipeline

    /// Generate optimized outage polygons with intelligent grouping and merging
    /// - Parameters:
    ///   - deviceData: Array of device data for polygon generation
    ///   - bufferRadius: Buffer radius around each device
    ///   - alpha: Concave hull alpha parameter
    /// - Returns: Array of optimized, merged outage polygons
    func generateOptimizedPolygons(
        _ deviceData: [DeviceData],
        bufferRadius: CLLocationDistance = 200.0,
        alpha: Double = 0.3
    ) -> [OutagePolygon] {

        logger.info("🚀 Starting optimized polygon generation for \(deviceData.count) devices")

        // Filter to offline devices only
        let offlineDevices = deviceData.filter { $0.isOffline == true }
        logger.info("📊 Processing \(offlineDevices.count) offline devices")

        guard offlineDevices.count >= minDeviceCount else {
            logger.info("✅ Insufficient offline devices for polygon generation")
            return []
        }

        // Phase 1: Spatial grid-based pre-clustering
        let spatialClusters = createSpatialClusters(offlineDevices)
        logger.info("🗂️ Created \(spatialClusters.count) spatial clusters")

        // Phase 2: Generate initial polygons from clusters
        let initialPolygons = generateInitialPolygons(
            from: spatialClusters,
            bufferRadius: bufferRadius,
            alpha: alpha,
            allDeviceData: deviceData
        )
        logger.info("🔷 Generated \(initialPolygons.count) initial polygons")

        // Phase 3: Hierarchical clustering for overlapping polygons
        let hierarchicalClusters = createHierarchicalClusters(initialPolygons)
        logger.info("🔗 Created \(hierarchicalClusters.count) hierarchical clusters")

        // Phase 4: Merge overlapping polygons with aggregated metadata
        let mergedPolygons = mergeOverlappingPolygons(
            hierarchicalClusters,
            allDeviceData: deviceData,
            bufferRadius: bufferRadius
        )
        logger.info("✅ Final result: \(mergedPolygons.count) optimized polygons")

        return mergedPolygons
    }

    // MARK: - Phase 1: Spatial Grid-Based Clustering

    /// Create spatial clusters using grid-based approach for O(n) performance
    private func createSpatialClusters(_ devices: [DeviceData]) -> [[DeviceData]] {
        guard !devices.isEmpty else { return [] }

        // Create spatial grid index
        var spatialGrid: [String: [DeviceData]] = [:]

        for device in devices {
            let gridKey = calculateGridKey(for: device.location)
            spatialGrid[gridKey, default: []].append(device)
        }

        logger.debug("📍 Created spatial grid with \(spatialGrid.count) cells")

        // Expand clusters by checking adjacent cells
        var processedCells: Set<String> = []
        var clusters: [[DeviceData]] = []

        for (gridKey, gridDevices) in spatialGrid {
            guard !processedCells.contains(gridKey) else { continue }

            let connectedCluster = findConnectedDevicesInGrid(
                startingCell: gridKey,
                spatialGrid: spatialGrid,
                processedCells: &processedCells
            )

            if connectedCluster.count >= minDeviceCount {
                clusters.append(connectedCluster)
            }
        }

        return clusters
    }

    /// Calculate spatial grid key for device location
    private func calculateGridKey(for location: CLLocation) -> String {
        let metersPerDegree = 111000.0 // Approximate meters per degree
        let cellSizeInDegrees = spatialGridCellSize / metersPerDegree

        let gridX = Int(location.coordinate.longitude / cellSizeInDegrees)
        let gridY = Int(location.coordinate.latitude / cellSizeInDegrees)

        return "\(gridX),\(gridY)"
    }

    /// Find all connected devices across adjacent grid cells
    private func findConnectedDevicesInGrid(
        startingCell: String,
        spatialGrid: [String: [DeviceData]],
        processedCells: inout Set<String>
    ) -> [DeviceData] {

        var connectedDevices: [DeviceData] = []
        var cellsToProcess: Set<String> = [startingCell]

        while !cellsToProcess.isEmpty {
            let currentCell = cellsToProcess.removeFirst()
            guard !processedCells.contains(currentCell) else { continue }

            processedCells.insert(currentCell)

            if let cellDevices = spatialGrid[currentCell] {
                connectedDevices.append(contentsOf: cellDevices)

                // Add adjacent cells to processing queue
                let adjacentCells = getAdjacentGridCells(currentCell)
                for adjacentCell in adjacentCells {
                    if spatialGrid[adjacentCell] != nil && !processedCells.contains(adjacentCell) {
                        // Check if cells are actually connected by device proximity
                        if areCellsConnected(currentCell, adjacentCell, spatialGrid: spatialGrid) {
                            cellsToProcess.insert(adjacentCell)
                        }
                    }
                }
            }
        }

        return connectedDevices
    }

    /// Get adjacent grid cell keys (8-connectivity)
    private func getAdjacentGridCells(_ cellKey: String) -> [String] {
        let components = cellKey.split(separator: ",")
        guard components.count == 2,
              let gridX = Int(components[0]),
              let gridY = Int(components[1]) else {
            return []
        }

        var adjacentCells: [String] = []
        for dx in -1...1 {
            for dy in -1...1 {
                if dx == 0 && dy == 0 { continue } // Skip self
                adjacentCells.append("\(gridX + dx),\(gridY + dy)")
            }
        }

        return adjacentCells
    }

    /// Check if two grid cells are connected by device proximity
    private func areCellsConnected(
        _ cell1: String,
        _ cell2: String,
        spatialGrid: [String: [DeviceData]]
    ) -> Bool {
        guard let devices1 = spatialGrid[cell1],
              let devices2 = spatialGrid[cell2] else {
            return false
        }

        // Check if any device in cell1 is within grouping distance of any device in cell2
        for device1 in devices1 {
            for device2 in devices2 {
                if device1.distance(to: device2) <= maxGroupingDistance {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Phase 2: Initial Polygon Generation

    /// Generate initial polygons from spatial clusters
    private func generateInitialPolygons(
        from clusters: [[DeviceData]],
        bufferRadius: CLLocationDistance,
        alpha: Double,
        allDeviceData: [DeviceData]
    ) -> [OutagePolygon] {

        let concaveHullGenerator = ConcaveHullGenerator()
        var polygons: [OutagePolygon] = []

        for cluster in clusters {
            guard cluster.count >= minDeviceCount else { continue }

            // Convert cluster to device data and generate detailed polygon
            let polygonCoordinates = await generateConcaveHullForCluster(
                cluster,
                bufferRadius: bufferRadius,
                alpha: alpha
            )

            guard polygonCoordinates.count >= 3 else { continue }

            // Calculate confidence and create polygon
            let confidence = calculateClusterConfidence(cluster, allDevices: allDeviceData)

            // Find all devices in polygon area for ratio calculation
            let polygonCenter = calculateClusterCenter(cluster)
            let devicesInArea = allDeviceData.filter { device in
                let distance = CLLocation(
                    latitude: polygonCenter.latitude,
                    longitude: polygonCenter.longitude
                ).distance(from: device.location)
                return distance <= bufferRadius * 1.5
            }

            let polygon = OutagePolygon(
                coordinates: polygonCoordinates,
                confidence: confidence,
                affectedDeviceData: cluster,
                allDevicesInArea: devicesInArea
            )

            polygons.append(polygon)
        }

        return polygons
    }

    /// Generate detailed concave hull for device cluster with enhanced algorithm
    private func generateConcaveHullForCluster(
        _ cluster: [DeviceData],
        bufferRadius: CLLocationDistance,
        alpha: Double
    ) async -> [CLLocationCoordinate2D] {

        guard cluster.count >= 3 else { return [] }

        // Use enhanced detailed hull generation for more accurate polygon shapes
        return await generateEnhancedDetailedHull(
            from: cluster,
            bufferRadius: bufferRadius,
            alpha: alpha
        )
    }

    /// Enhanced CONCAVE hull generation with utility-grade accuracy
    private func generateEnhancedDetailedHull(
        from devices: [DeviceData],
        bufferRadius: CLLocationDistance,
        alpha: Double
    ) async -> [CLLocationCoordinate2D] {

        guard devices.count >= 3 else { return [] }

        logger.info("🌊 GENERATING UTILITY-GRADE CONCAVE HULL for \(devices.count) devices")

        let performanceLogger = PolygonPerformanceLogger()
        await performanceLogger.startPhase("UtilityGrade_ConcaveHull", details: "\(devices.count) devices, α=\(String(format: "%.3f", alpha))")

        // Use the utility-grade concave hull algorithm
        let concaveHullGenerator = UtilityGradeConcaveHull()
        let hullResult = await concaveHullGenerator.generateUtilityGradeConcaveHull(
            from: devices,
            bufferRadius: bufferRadius,
            alpha: alpha
        )

        await performanceLogger.endPhase("UtilityGrade_ConcaveHull", itemCount: hullResult.coordinates.count, details: "Quality: \(String(format: "%.3f", hullResult.qualityMetrics.overallQuality))")

        // Log quality metrics for utility validation
        await performanceLogger.logPolygonQuality(
            polygonId: UUID(),
            vertices: hullResult.coordinates.count,
            area: GeometryUtils.approximatePolygonArea(hullResult.coordinates),
            perimeterLength: calculatePerimeterLength(hullResult.coordinates),
            deviceEnclosure: hullResult.qualityMetrics.deviceEnclosureScore,
            convexityRatio: hullResult.qualityMetrics.topologicalIntegrityScore,
            smoothnessScore: hullResult.qualityMetrics.boundaryAccuracyScore
        )

        logger.info("""
        ✅ CONCAVE HULL COMPLETED:
        • Vertices: \(hullResult.coordinates.count)
        • Quality Score: \(String(format: "%.3f", hullResult.qualityMetrics.overallQuality))/1.0
        • Utility Grade: \(hullResult.qualityMetrics.utilityGradeCompliant ? "✅ PASSED" : "❌ FAILED")
        • Emergency Ready: \(String(format: "%.1f", hullResult.qualityMetrics.emergencyResponseReadiness * 100))%
        """)

        return hullResult.coordinates
    }

    /// Calculate perimeter length for quality metrics
    private func calculatePerimeterLength(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0.0 }

        var totalLength = 0.0
        for i in 0..<coordinates.count {
            let current = coordinates[i]
            let next = coordinates[(i + 1) % coordinates.count]

            let distance = CLLocation(latitude: current.latitude, longitude: current.longitude)
                .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))

            totalLength += distance
        }

        return totalLength / 111000.0 // Convert to degrees for consistency
    }

    /// Legacy refinement method (keeping for reference)
    private func refineConcaveHull(
        _ hull: [CLLocationCoordinate2D],
        allPoints: [CLLocationCoordinate2D],
        alpha: Double
    ) -> [CLLocationCoordinate2D] {

        var refinedHull: [CLLocationCoordinate2D] = []
        let concavityThreshold = (1.0 - alpha) * 200.0 // Convert alpha to meters

        for i in 0..<hull.count {
            let current = hull[i]
            let next = hull[(i + 1) % hull.count]
            refinedHull.append(current)

            // Look for interior points that could create concave indentations
            let midpoint = CLLocationCoordinate2D(
                latitude: (current.latitude + next.latitude) / 2,
                longitude: (current.longitude + next.longitude) / 2
            )

            let midLocation = CLLocation(latitude: midpoint.latitude, longitude: midpoint.longitude)

            // Find nearby points that could add detail
            let candidatePoints = allPoints.filter { point in
                let distanceToMidpoint = CLLocation(latitude: point.latitude, longitude: point.longitude)
                    .distance(from: midLocation)

                return distanceToMidpoint <= concavityThreshold &&
                       !hull.contains(where: { $0.latitude == point.latitude && $0.longitude == point.longitude })
            }

            // Add the closest candidate point for detail
            if let closestCandidate = candidatePoints.min(by: { point1, point2 in
                let dist1 = CLLocation(latitude: point1.latitude, longitude: point1.longitude)
                    .distance(from: midLocation)
                let dist2 = CLLocation(latitude: point2.latitude, longitude: point2.longitude)
                    .distance(from: midLocation)
                return dist1 < dist2
            }) {
                refinedHull.append(closestCandidate)
            }
        }

        return refinedHull
    }

    /// Simplify polygon for MapKit rendering performance
    private func simplifyPolygonForRendering(
        _ points: [CLLocationCoordinate2D],
        tolerance: Double
    ) -> [CLLocationCoordinate2D] {

        guard points.count > 3 else { return points }

        var simplified: [CLLocationCoordinate2D] = [points[0]]

        for i in 1..<points.count-1 {
            let prev = simplified.last!
            let current = points[i]
            let next = points[i + 1]

            // Calculate perpendicular distance
            let distance = perpendicularDistanceToLine(
                point: current,
                lineStart: prev,
                lineEnd: next
            )

            // Keep point if it adds meaningful detail
            if distance > tolerance {
                simplified.append(current)
            }
        }

        // Always keep the last point
        if let last = points.last {
            simplified.append(last)
        }

        return simplified.count >= 3 ? simplified : points
    }

    /// Calculate perpendicular distance from point to line
    private func perpendicularDistanceToLine(
        point: CLLocationCoordinate2D,
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D
    ) -> Double {

        let A = point.latitude - lineStart.latitude
        let B = point.longitude - lineStart.longitude
        let C = lineEnd.latitude - lineStart.latitude
        let D = lineEnd.longitude - lineStart.longitude

        let dot = A * C + B * D
        let lenSq = C * C + D * D

        if lenSq == 0 { return sqrt(A * A + B * B) }

        let param = dot / lenSq

        let closestPoint: CLLocationCoordinate2D
        if param < 0 {
            closestPoint = lineStart
        } else if param > 1 {
            closestPoint = lineEnd
        } else {
            closestPoint = CLLocationCoordinate2D(
                latitude: lineStart.latitude + param * C,
                longitude: lineStart.longitude + param * D
            )
        }

        let dx = point.latitude - closestPoint.latitude
        let dy = point.longitude - closestPoint.longitude
        return sqrt(dx * dx + dy * dy) * 111000.0 // Convert to meters approximately
    }

    /// Calculate confidence level for device cluster
    private func calculateClusterConfidence(_ cluster: [DeviceData], allDevices: [DeviceData]) -> Double {
        let clusterCenter = calculateClusterCenter(cluster)
        let clusterRadius = calculateClusterRadius(cluster, center: clusterCenter)

        // Count devices in cluster area
        let devicesInArea = allDevices.filter { device in
            let distance = CLLocation(
                latitude: clusterCenter.latitude,
                longitude: clusterCenter.longitude
            ).distance(from: device.location)
            return distance <= clusterRadius * 1.2
        }

        let offlineInArea = devicesInArea.filter { $0.isOffline == true }.count
        let onlineInArea = devicesInArea.filter { $0.isOffline == false }.count
        let totalInArea = offlineInArea + onlineInArea

        guard totalInArea > 0 else { return 0.5 }

        // Base confidence from outage ratio
        let outageRatio = Double(offlineInArea) / Double(totalInArea)

        // Adjust for device count and density
        let deviceCountFactor = min(1.0, Double(cluster.count) / 15.0)
        let densityFactor = min(1.0, Double(totalInArea) / 25.0)

        return max(0.1, min(1.0, (outageRatio * 0.6) + (deviceCountFactor * 0.25) + (densityFactor * 0.15)))
    }

    /// Calculate center of device cluster
    private func calculateClusterCenter(_ cluster: [DeviceData]) -> CLLocationCoordinate2D {
        guard !cluster.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }

        let avgLat = cluster.map { $0.latitude }.reduce(0, +) / Double(cluster.count)
        let avgLon = cluster.map { $0.longitude }.reduce(0, +) / Double(cluster.count)

        return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
    }

    /// Calculate effective radius of device cluster
    private func calculateClusterRadius(_ cluster: [DeviceData], center: CLLocationCoordinate2D) -> CLLocationDistance {
        guard cluster.count > 1 else { return 200.0 }

        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let maxDistance = cluster.map { device in
            centerLocation.distance(from: device.location)
        }.max() ?? 200.0

        return maxDistance + 100.0 // Add buffer
    }

    // MARK: - Phase 3: Hierarchical Clustering

    /// Create hierarchical clusters of overlapping polygons
    private func createHierarchicalClusters(_ polygons: [OutagePolygon]) -> [[OutagePolygon]] {
        guard polygons.count > 1 else { return polygons.map { [$0] } }

        // Build adjacency graph of overlapping polygons
        var adjacencyList: [Int: Set<Int>] = [:]
        for i in 0..<polygons.count {
            adjacencyList[i] = []
        }

        // Check for geometric overlaps using improved intersection detection
        for i in 0..<polygons.count {
            for j in (i+1)..<polygons.count {
                if polygonsOverlap(polygons[i], polygons[j]) {
                    adjacencyList[i]!.insert(j)
                    adjacencyList[j]!.insert(i)
                }
            }
        }

        // Find connected components using depth-first search
        var visited: Set<Int> = []
        var clusters: [[OutagePolygon]] = []

        for i in 0..<polygons.count {
            guard !visited.contains(i) else { continue }

            var cluster: [OutagePolygon] = []
            var stack: [Int] = [i]

            while !stack.isEmpty {
                let current = stack.removeLast()
                guard !visited.contains(current) else { continue }

                visited.insert(current)
                cluster.append(polygons[current])

                for neighbor in adjacencyList[current]! {
                    if !visited.contains(neighbor) {
                        stack.append(neighbor)
                    }
                }
            }

            clusters.append(cluster)
        }

        logger.debug("🔗 Created \(clusters.count) hierarchical clusters from \(polygons.count) polygons")
        return clusters
    }

    /// Enhanced polygon overlap detection using geometric intersection
    private func polygonsOverlap(_ polygon1: OutagePolygon, _ polygon2: OutagePolygon) -> Bool {
        // Quick distance check first for performance
        let centerDistance = CLLocation(
            latitude: polygon1.center.latitude,
            longitude: polygon1.center.longitude
        ).distance(from: CLLocation(
            latitude: polygon2.center.latitude,
            longitude: polygon2.center.longitude
        ))

        let combinedRadius = polygon1.boundingRadius + polygon2.boundingRadius
        guard centerDistance <= combinedRadius else { return false }

        // Geometric intersection check
        let intersects = GeometryUtils.polygonsIntersect(polygon1.coordinates, polygon2.coordinates)
        if intersects {
            // Check if overlap ratio meets threshold
            let overlapRatio = GeometryUtils.overlapRatio(polygon1.coordinates, polygon2.coordinates)
            return overlapRatio >= minOverlapRatio
        }

        return false
    }

    // MARK: - Phase 4: Polygon Merging

    /// Merge overlapping polygons within each hierarchical cluster
    private func mergeOverlappingPolygons(
        _ clusters: [[OutagePolygon]],
        allDeviceData: [DeviceData],
        bufferRadius: CLLocationDistance
    ) -> [OutagePolygon] {

        var mergedPolygons: [OutagePolygon] = []

        for cluster in clusters {
            if cluster.count == 1 {
                // Single polygon - keep as is
                mergedPolygons.append(cluster[0])
            } else {
                // Multiple overlapping polygons - merge them
                if let mergedPolygon = mergePolygonCluster(cluster, allDeviceData: allDeviceData, bufferRadius: bufferRadius) {
                    mergedPolygons.append(mergedPolygon)
                    logger.debug("🔗 Merged \(cluster.count) polygons into 1 unified polygon")
                } else {
                    // Fallback: keep largest polygon
                    let largest = cluster.max { $0.affectedDeviceCount < $1.affectedDeviceCount }!
                    mergedPolygons.append(largest)
                    logger.warning("⚠️ Failed to merge \(cluster.count) polygons, kept largest")
                }
            }
        }

        return mergedPolygons
    }

    /// Merge a cluster of overlapping polygons into a unified polygon
    private func mergePolygonCluster(
        _ polygons: [OutagePolygon],
        allDeviceData: [DeviceData],
        bufferRadius: CLLocationDistance
    ) -> OutagePolygon? {

        guard !polygons.isEmpty else { return nil }

        // Create union of polygon coordinates
        let polygonCoordinates = polygons.map { $0.coordinates }
        let unionCoordinates = GeometryUtils.preciseUnionPolygons(polygonCoordinates, bufferRadius: bufferRadius)

        guard unionCoordinates.count >= 3 else { return nil }

        // Calculate overlap coefficient for the merge
        let totalArea = polygons.reduce(0.0) { total, polygon in
            total + GeometryUtils.approximatePolygonArea(polygon.coordinates)
        }
        let unionArea = GeometryUtils.approximatePolygonArea(unionCoordinates)
        let overlapCoefficient = totalArea > 0 ? min(1.0, max(0.0, (totalArea - unionArea) / totalArea)) : 0.0

        // Find all devices in the merged polygon area
        let bounds = GeometryUtils.getBoundingBox(unionCoordinates)
        let devicesInMergedArea = allDeviceData.filter { device in
            device.latitude >= bounds.minLat &&
            device.latitude <= bounds.maxLat &&
            device.longitude >= bounds.minLon &&
            device.longitude <= bounds.maxLon
        }

        // Create merged polygon with aggregated metadata
        let mergedPolygon = OutagePolygon(
            mergedCoordinates: unionCoordinates,
            contributingPolygons: polygons,
            allDevicesInArea: devicesInMergedArea,
            overlapCoefficient: overlapCoefficient
        )

        logger.debug("🔗 Created merged polygon: \(mergedPolygon.mergeDescription)")
        return mergedPolygon
    }
}

// MARK: - DeviceData Extension

extension DeviceData {
    /// Calculate distance to another device
    func distance(to other: DeviceData) -> CLLocationDistance {
        return location.distance(from: other.location)
    }

    /// CLLocation representation of device
    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}