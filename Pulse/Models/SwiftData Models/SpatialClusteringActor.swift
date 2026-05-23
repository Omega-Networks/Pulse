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

// MARK: - Results

struct ClusterResult: Sendable, Equatable {
    let clusters: [DeviceCluster]
    let totalDevices: Int
    let offlineDevices: Int
    let processingTime: Double
    let totalEvents: Int
    let activeEvents: Int

    static func == (lhs: ClusterResult, rhs: ClusterResult) -> Bool {
        return lhs.totalDevices == rhs.totalDevices &&
               lhs.offlineDevices == rhs.offlineDevices &&
               lhs.totalEvents == rhs.totalEvents &&
               lhs.activeEvents == rhs.activeEvents &&
               lhs.clusters.count == rhs.clusters.count
    }
}

private struct PointKey: Hashable, Sendable {
    let coord: CLLocationCoordinate2D

    func hash(into hasher: inout Hasher) {
        hasher.combine(Int(coord.latitude * 1000000))
        hasher.combine(Int(coord.longitude * 1000000))
    }

    static func == (lhs: PointKey, rhs: PointKey) -> Bool {
        return abs(lhs.coord.latitude - rhs.coord.latitude) < 1e-6 &&
               abs(lhs.coord.longitude - rhs.coord.longitude) < 1e-6
    }
}

// MARK: - Spatial Confidence Index

private struct SpatialConfidenceIndex {
    private let cellSize: Double = 0.005
    private var grid: [GridKey: [PowerSenseDeviceDTO]] = [:]

    struct GridKey: Hashable {
        let row: Int, col: Int
    }

    init(devices: [PowerSenseDeviceDTO]) {
        for device in devices {
            let key = GridKey(
                row: Int(floor(device.latitude / cellSize)),
                col: Int(floor(device.longitude / cellSize))
            )
            grid[key, default: []].append(device)
        }
    }

    func confidence(
        forHull hull: [CLLocationCoordinate2D],
        using pipTest: (CLLocationCoordinate2D, [CLLocationCoordinate2D]) -> Bool
    ) -> Double {
        guard hull.count >= 3 else { return 0 }

        let lats = hull.map(\.latitude), lons = hull.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return 0 }

        let rowMin = Int(floor(minLat / cellSize)), rowMax = Int(floor(maxLat / cellSize))
        let colMin = Int(floor(minLon / cellSize)), colMax = Int(floor(maxLon / cellSize))

        var totalInHull = 0, offlineInHull = 0

        for row in rowMin...rowMax {
            for col in colMin...colMax {
                guard let candidates = grid[GridKey(row: row, col: col)] else { continue }
                for device in candidates {
                    let coord = CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
                    guard pipTest(coord, hull) else { continue }
                    totalInHull += 1
                    if device.isOffline == true { offlineInHull += 1 }
                }
            }
        }

        return totalInHull > 0 ? Double(offlineInHull) / Double(totalInHull) : 0
    }
}

// MARK: - Spatial Clustering Actor

actor SpatialClusteringActor {

    private let modelContainer: ModelContainer
    private let config: SpatialClusteringConfig
    private let indexer: GPUSpatialIndexManager<PowerSenseDeviceDTO>
    private let logger = Logger.spatialClustering

    private var dtoCache: [PowerSenseDeviceDTO] = []

    func invalidateDTOCache() {
        dtoCache = []
        logger.info("DTO cache invalidated")
    }

    init(
        modelContainer: ModelContainer,
        config: SpatialClusteringConfig = .default,
        transformer: CoordinateTransformer
    ) {
        self.modelContainer = modelContainer
        self.config = config
        self.indexer = GPUSpatialIndexManager(transformer: transformer)
    }

    init(
        modelContainer: ModelContainer,
        config: SpatialClusteringConfig = .default
    ) throws {
        let transformer = try CoordinateTransformer(projectionSystem: config.projectionSystem)
        self.init(modelContainer: modelContainer, config: config, transformer: transformer)
    }

    // MARK: - Public Interface

    func clusterAllDevices() async throws -> ClusterResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        try config.clusteringParameters.validate()

        let devices = try await getSpatialDeviceDTOs()
        let offlineCount = devices.filter { $0.isOffline == true }.count
        let (totalEvents, activeEvents) = try await getEventStats()

        logger.info("Clustering \(devices.count) devices, \(offlineCount) offline, \(activeEvents) active events")

        guard offlineCount >= config.clusteringParameters.minPoints else {
            logger.info("No offline devices meet minimum threshold — returning empty result")
            return ClusterResult(
                clusters: [],
                totalDevices: devices.count,
                offlineDevices: offlineCount,
                processingTime: CFAbsoluteTimeGetCurrent() - startTime,
                totalEvents: totalEvents,
                activeEvents: activeEvents
            )
        }

        try await indexer.buildIndex(devices: devices)
        let clusters = try await performClustering(devices: devices)

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("Clustering complete in \(String(format: "%.2f", processingTime))s — \(clusters.count) clusters")

        return ClusterResult(
            clusters: clusters,
            totalDevices: devices.count,
            offlineDevices: offlineCount,
            processingTime: processingTime,
            totalEvents: totalEvents,
            activeEvents: activeEvents
        )
    }

    // MARK: - DTO Fetch with Cache

    func getSpatialDeviceDTOs() async throws -> [PowerSenseDeviceDTO] {
        if !dtoCache.isEmpty {
            return dtoCache
        }

        let modelContext = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<PowerSenseDevice>(
            sortBy: [SortDescriptor(\.deviceId)]
        )
        descriptor.fetchLimit = config.clusteringParameters.maxDevices

        let devices = try modelContext.fetch(descriptor)

        // Warm up power status cache for devices that haven't been cached yet
        for device in devices where device.cachedIsOffline == nil && !device.events.isEmpty {
            device.refreshPowerStatus()
        }

        dtoCache = devices.map { $0.toDTO() }
        logger.debug("Fetched and cached \(devices.count) device DTOs")
        return dtoCache
    }

    // MARK: - Event Stats

    private func getEventStats() async throws -> (totalEvents: Int, activeEvents: Int) {
        let modelContext = ModelContext(modelContainer)
        let totalCount = try modelContext.fetchCount(FetchDescriptor<PowerSenseEvent>())
        let activeCount = try modelContext.fetchCount(FetchDescriptor<PowerSenseEvent>(
            predicate: #Predicate { $0.resolvedAt == nil }
        ))
        return (totalCount, activeCount)
    }

    // MARK: - GPU DBSCAN

    private func performClustering(devices: [PowerSenseDeviceDTO]) async throws -> [DeviceCluster] {
        let offlineDevices = devices.filter { $0.isOffline == true }
        guard !offlineDevices.isEmpty else { return [] }

        guard let gridParams = await indexer.getGridParameters(),
              let gpuGrid = await indexer.getGPUGrid(),
              let coordsBuffer = await indexer.getGPUCoordsBuffer(),
              let offlineFlagsBuffer = await indexer.getGPUOfflineFlagsBuffer() else {
            throw ClusteringError.clusteringFailed("Failed to access GPU buffers on Apple Silicon")
        }

        let transformer = await indexer.getTransformer()

        let dbscanResult = try transformer.performGPUDBSCAN(
            coordsBuffer: coordsBuffer.buffer,
            offlineFlagsBuffer: offlineFlagsBuffer.buffer,
            grid: gpuGrid,
            gridParams: gridParams,
            dbscanParams: DBSCANParameters(
                epsilon: config.clusteringParameters.epsilon,
                minPoints: config.clusteringParameters.minPoints,
                aggregationThreshold: config.clusteringParameters.aggregationThreshold
            ),
            deviceCount: devices.count
        )

        logger.debug("GPU DBSCAN: \(dbscanResult.clusterCount) clusters in \(String(format: "%.1f", dbscanResult.processingTime * 1000))ms")

        return try await generateClustersWithHullsAndConfidence(
            dbscanResult: dbscanResult,
            devices: devices,
            transformer: transformer,
            coordsBuffer: coordsBuffer,
            offlineFlagsBuffer: offlineFlagsBuffer,
            gridParams: gridParams,
            gpuGrid: gpuGrid,
            aggregationThreshold: config.clusteringParameters.aggregationThreshold
        )
    }

    // MARK: - Hull + Confidence Generation

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

        // Group devices by cluster label
        var clusterDevicesMap: [Int32: [PowerSenseDeviceDTO]] = [:]
        for (index, device) in devices.enumerated() {
            let label = dbscanResult.labels[index]
            if device.isOffline == true && label != -1 {
                clusterDevicesMap[label, default: []].append(device)
            }
        }

        let validClusters = clusterDevicesMap
            .filter { $0.value.count >= aggregationThreshold }
            .map { ($0.key, $0.value) }

        guard !validClusters.isEmpty else { return [] }

        let samplingThreshold = 500
        let finalClusters = validClusters.map { (label, devices) -> (Int32, [PowerSenseDeviceDTO]) in
            devices.count > samplingThreshold
                ? (label, applySamplingToCluster(devices: devices, targetCount: samplingThreshold))
                : (label, devices)
        }

        // Batch transform all coordinates once
        var allCoordinates: [CLLocationCoordinate2D] = []
        for (_, clusterDevices) in finalClusters {
            allCoordinates.append(contentsOf: clusterDevices.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            })
        }

        let allProjected = try transformer.batchTransform(allCoordinates)
        var deviceToProjected: [String: ProjectedCoordinate] = [:]
        var coordIndex = 0
        for (_, clusterDevices) in finalClusters {
            for device in clusterDevices {
                deviceToProjected[device.deviceId] = allProjected[coordIndex]
                coordIndex += 1
            }
        }

        let confidenceIndex = SpatialConfidenceIndex(devices: devices)
        let useConcaveHull = config.clusteringParameters.useConcaveHull

        let enhancedClusters = try await withThrowingTaskGroup(of: DeviceCluster?.self) { group in
            for (clusterIndex, (_, clusterDevices)) in finalClusters.enumerated() {
                group.addTask { [deviceToProjected, transformer, confidenceIndex] in

                    let projectedCoordinates = clusterDevices.compactMap { deviceToProjected[$0.deviceId] }
                    guard projectedCoordinates.count == clusterDevices.count else { return nil }

                    let deviceCoordinates = clusterDevices.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }

                    let deviceCount = Double(clusterDevices.count)
                    let dynamicConcavity: Double
                    if deviceCount <= 10 {
                        dynamicConcavity = 300.0
                    } else if deviceCount >= 10000 {
                        dynamicConcavity = 50.0
                    } else {
                        let logScale = log10(deviceCount / 10.0) / log10(10000.0 / 10.0)
                        dynamicConcavity = 300.0 - (250.0 * logScale)
                    }

                    let hullVertices: [CLLocationCoordinate2D]
                    if useConcaveHull {
                        hullVertices = try self.computeConcaveHull(
                            projectedCoordinates: projectedCoordinates,
                            concavity: dynamicConcavity,
                            transformer: transformer
                        )
                    } else {
                        hullVertices = self.computeConvexHull(points: deviceCoordinates)
                    }

                    let confidence = confidenceIndex.confidence(
                        forHull: hullVertices,
                        using: self.pointInPolygon
                    )

                    guard confidence >= 0.02 else { return nil }

                    let (startTime, duration) = self.calculateOutageTiming(clusterDevices: clusterDevices)

                    let gradientLayers = self.generateGradientLayers(
                        polygon: hullVertices,
                        bufferDistances: [-100, -50, 0]
                    )

                    return DeviceCluster(
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
                }
            }

            var results: [DeviceCluster] = []
            for try await cluster in group {
                if let cluster = cluster { results.append(cluster) }
            }
            return results
        }

        logger.debug("Hull generation complete: \(enhancedClusters.count) valid clusters")
        return enhancedClusters
    }

    // MARK: - Geometry Helpers

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

    nonisolated private func pointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var wn = 0
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            if a.latitude <= point.latitude {
                if b.latitude > point.latitude && isLeft(a, b, point) > 0 { wn += 1 }
            } else {
                if b.latitude <= point.latitude && isLeft(a, b, point) < 0 { wn -= 1 }
            }
        }
        return wn != 0
    }

    nonisolated private func isLeft(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        _ p: CLLocationCoordinate2D
    ) -> Double {
        return (b.longitude - a.longitude) * (p.latitude - a.latitude) -
               (p.longitude - a.longitude) * (b.latitude - a.latitude)
    }

    nonisolated private func crossProduct(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        _ c: CLLocationCoordinate2D
    ) -> Double {
        return (b.longitude - a.longitude) * (c.latitude - a.latitude) -
               (b.latitude - a.latitude) * (c.longitude - a.longitude)
    }

    nonisolated private func computeConvexHull(points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard points.count >= 3 else { return createBoundingBoxFromPoints(points) }
        
        let set = Set(points.map { PointKey(coord: $0) })
        let uniquePoints = Array(set)
            .map { $0.coord }
            .sorted { a, b in
                abs(a.longitude - b.longitude) < 1e-10 ? a.latitude < b.latitude : a.longitude < b.longitude
            }

        guard uniquePoints.count >= 3 else { return createBoundingBoxFromPoints(uniquePoints) }

        var lower: [CLLocationCoordinate2D] = []
        for point in uniquePoints {
            while lower.count >= 2 && crossProduct(lower[lower.count-2], lower[lower.count-1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }

        var upper: [CLLocationCoordinate2D] = []
        for point in uniquePoints.reversed() {
            while upper.count >= 2 && crossProduct(upper[upper.count-2], upper[upper.count-1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }

        lower.removeLast()
        upper.removeLast()
        var hull = lower + upper

        if hull.count < 3 { return createBoundingBoxFromPoints(uniquePoints) }
        if !isClockwise(coordinates: hull) { hull.reverse() }
        return hull
    }

    nonisolated private func computeConcaveHull(
        projectedCoordinates: [ProjectedCoordinate],
        concavity: Double,
        transformer: CoordinateTransformer
    ) throws -> [CLLocationCoordinate2D] {
        let points = projectedCoordinates.map { Point(x: $0.x, y: $0.y) }
        let hullPoints = ConcaveHull().hullFromPoints(points: points, concavity: concavity)
        let hullProjected = hullPoints.map { ProjectedCoordinate(x: $0.x, y: $0.y, system: .nztm2000) }
        var hullLatLon = transformer.batchInverseTransform(hullProjected)
        if !isClockwise(coordinates: hullLatLon) { hullLatLon.reverse() }
        return hullLatLon
    }

    nonisolated private func createBoundingBoxFromPoints(_ points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard !points.isEmpty else { return [] }
        if points.count == 1 {
            let p = points[0], e = 0.0001
            return [
                CLLocationCoordinate2D(latitude: p.latitude - e, longitude: p.longitude - e),
                CLLocationCoordinate2D(latitude: p.latitude - e, longitude: p.longitude + e),
                CLLocationCoordinate2D(latitude: p.latitude + e, longitude: p.longitude + e),
                CLLocationCoordinate2D(latitude: p.latitude + e, longitude: p.longitude - e)
            ]
        }
        if points.count == 2 {
            let p1 = points[0], p2 = points[1], e = 0.0001
            return [
                CLLocationCoordinate2D(latitude: min(p1.latitude,p2.latitude)-e, longitude: min(p1.longitude,p2.longitude)-e),
                CLLocationCoordinate2D(latitude: min(p1.latitude,p2.latitude)-e, longitude: max(p1.longitude,p2.longitude)+e),
                CLLocationCoordinate2D(latitude: max(p1.latitude,p2.latitude)+e, longitude: max(p1.longitude,p2.longitude)+e),
                CLLocationCoordinate2D(latitude: max(p1.latitude,p2.latitude)+e, longitude: min(p1.longitude,p2.longitude)-e)
            ]
        }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        return [
            CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!),
            CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.max()!),
            CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!),
            CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.min()!)
        ]
    }

    private func createBoundingBox(_ devices: [PowerSenseDeviceDTO]) -> [CLLocationCoordinate2D] {
        createBoundingBoxFromPoints(devices.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        })
    }

    // MARK: - Gradient Layers

    nonisolated func generateGradientLayers(
        polygon: [CLLocationCoordinate2D],
        bufferDistances: [Double]
    ) -> [[CLLocationCoordinate2D]] {
        var layers: [[CLLocationCoordinate2D]] = []
        for distance in bufferDistances {
            if distance == 0 {
                layers.append(polygon)
            } else if let buffered = bufferPolygon(polygon: polygon, bufferMeters: distance) {
                layers.append(buffered)
            } else if distance > 0 {
                break
            }
        }
        return layers
    }

    nonisolated private func bufferPolygon(polygon: [CLLocationCoordinate2D], bufferMeters: Double) -> [CLLocationCoordinate2D]? {
        guard polygon.count >= 3 else { return nil }
        let bufferDegrees = bufferMeters / 111_000.0
        var bufferedVertices: [CLLocationCoordinate2D] = []

        for i in 0..<polygon.count {
            let prev = polygon[(i - 1 + polygon.count) % polygon.count]
            let curr = polygon[i]
            let next = polygon[(i + 1) % polygon.count]

            let v1 = (lat: curr.latitude - prev.latitude, lon: curr.longitude - prev.longitude)
            let v2 = (lat: next.latitude - curr.latitude, lon: next.longitude - curr.longitude)

            let n1 = normalizeVector((-v1.lon, v1.lat))
            let n2 = normalizeVector((-v2.lon, v2.lat))
            var avgNormal = (lat: (n1.lat + n2.lat) / 2.0, lon: (n1.lon + n2.lon) / 2.0)
            avgNormal = normalizeVector(avgNormal)

            if bufferMeters > 0 {
                if !isClockwise(coordinates: polygon) { avgNormal = (-avgNormal.lat, -avgNormal.lon) }
            } else {
                if isClockwise(coordinates: polygon) { avgNormal = (-avgNormal.lat, -avgNormal.lon) }
            }

            bufferedVertices.append(CLLocationCoordinate2D(
                latitude: curr.latitude + avgNormal.lat * bufferDegrees,
                longitude: curr.longitude + avgNormal.lon * bufferDegrees
            ))
        }

        guard bufferedVertices.count >= 3 else { return nil }
        if bufferMeters > 0 {
            guard computePolygonArea(bufferedVertices) > 1e-10 else { return nil }
        }
        return bufferedVertices
    }

    nonisolated private func normalizeVector(_ v: (lat: Double, lon: Double)) -> (lat: Double, lon: Double) {
        let magnitude = sqrt(v.lat * v.lat + v.lon * v.lon)
        guard magnitude > 0 else { return (0, 0) }
        return (v.lat / magnitude, v.lon / magnitude)
    }

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

    // MARK: - Sampling

    private func applySamplingToCluster(devices: [PowerSenseDeviceDTO], targetCount: Int) -> [PowerSenseDeviceDTO] {
        guard devices.count > targetCount else { return devices }

        var sampled: [PowerSenseDeviceDTO] = []
        let lats = devices.map { $0.latitude }, lons = devices.map { $0.longitude }
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!

        var extremeIndices: Set<Int> = []
        for (index, device) in devices.enumerated() {
            if device.latitude == minLat || device.latitude == maxLat ||
               device.longitude == minLon || device.longitude == maxLon {
                extremeIndices.insert(index)
                sampled.append(device)
            }
        }

        let additionalCount = targetCount - sampled.count
        if additionalCount > 0 {
            let remaining = devices.enumerated().compactMap { extremeIndices.contains($0.offset) ? nil : $0.element }
            if !remaining.isEmpty {
                let stride = Double(remaining.count) / Double(additionalCount)
                for i in 0..<additionalCount {
                    sampled.append(remaining[min(Int(Double(i) * stride), remaining.count - 1)])
                }
            }
        }
        return sampled
    }

    // MARK: - Outage Timing

    nonisolated private func calculateOutageTiming(clusterDevices: [PowerSenseDeviceDTO]) -> (startTime: Date?, duration: TimeInterval) {
        let allTimestamps = clusterDevices.compactMap { $0.eventTimestamp }.sorted()
        guard allTimestamps.count >= 3 else {
            if let first = allTimestamps.first { return (first, Date().timeIntervalSince(first)) }
            return (nil, 0)
        }

        let q1 = allTimestamps[allTimestamps.count / 4]
        let q3 = allTimestamps[(3 * allTimestamps.count) / 4]
        let iqr = q3.timeIntervalSince(q1)
        let filtered = allTimestamps.filter {
            $0 >= q1.addingTimeInterval(-1.5 * iqr) && $0 <= q3.addingTimeInterval(1.5 * iqr)
        }

        guard !filtered.isEmpty else {
            let mid = allTimestamps[allTimestamps.count / 2]
            return (mid, Date().timeIntervalSince(mid))
        }

        let medianTimestamp: Date
        if filtered.count % 2 == 0 {
            let mid = filtered.count / 2
            medianTimestamp = filtered[mid - 1].addingTimeInterval(
                filtered[mid].timeIntervalSince(filtered[mid - 1]) / 2
            )
        } else {
            medianTimestamp = filtered[filtered.count / 2]
        }
        return (medianTimestamp, Date().timeIntervalSince(medianTimestamp))
    }

    // MARK: - Performance and Diagnostics

    func getIndexerPerformanceMetrics() async -> SpatialIndexMetrics {
        return await indexer.performanceMetrics
    }

    func isIndexerReady() async -> Bool {
        return await indexer.isIndexReady
    }

    func getIndexedDeviceCount() async -> Int {
        return await indexer.deviceCount
    }
}

// MARK: - ClusteringService

@Observable
final class ClusteringService: @unchecked Sendable {
    private let actor: SpatialClusteringActor
    private let logger = Logger(subsystem: "pulse", category: "clusteringService")

    init(modelContainer: ModelContainer) throws {
        self.actor = try SpatialClusteringActor(
            modelContainer: modelContainer,
            config: SpatialClusteringConfig.default
        )
        Task.detached(priority: .background) {
            try? await self.actor.getSpatialDeviceDTOs()
        }
        logger.info("ClusteringService initialized")
    }

    func clusterDevices() async throws -> ClusterResult {
        return try await actor.clusterAllDevices()
    }

    func invalidateCache() async {
        await actor.invalidateDTOCache()
    }

    func getPerformanceMetrics() async -> SpatialIndexMetrics {
        return await actor.getIndexerPerformanceMetrics()
    }

    func isReady() async -> Bool {
        return await actor.isIndexerReady()
    }
}
