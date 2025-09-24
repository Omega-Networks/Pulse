//
//  GrahamScanHullGenerator.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  High-performance convex hull generation using Graham scan algorithm
//  O(n log n) computational geometry for reliable polygon boundaries
//

import Foundation
import CoreLocation
import MapKit
import OSLog

/// Graham scan convex hull algorithm implementation
/// Industry-standard O(n log n) computational geometry for polygon generation
/// Used by major mapping and GIS systems for reliable boundary computation
public final class GrahamScanHullGenerator {

    // MARK: - Logging Infrastructure

    private let algorithmLogger = Logger(subsystem: "powersense.hull", category: "algorithms")
    private let performanceLogger = Logger(subsystem: "powersense.hull", category: "performance")
    private let geometryLogger = Logger(subsystem: "powersense.hull", category: "geometry")
    private let debugLogger = Logger(subsystem: "powersense.hull", category: "debug")
    private let errorLogger = Logger(subsystem: "powersense.hull", category: "errors")

    // MARK: - Configuration

    struct HullConfig {
        /// Minimum points required for hull generation
        let minimumPoints: Int

        /// Maximum processing time threshold for performance monitoring
        let maxProcessingTime: TimeInterval

        /// Whether to include detailed geometric validation
        let enableGeometricValidation: Bool

        /// Coordinate precision for duplicate point detection
        let coordinatePrecision: Double

        static let `default` = HullConfig(
            minimumPoints: 3,
            maxProcessingTime: 0.010,  // 10ms per hull
            enableGeometricValidation: true,
            coordinatePrecision: 1e-8
        )
    }

    // MARK: - Performance Metrics

    private struct HullMetrics {
        var inputPoints: Int = 0
        var outputPoints: Int = 0
        var processingTime: TimeInterval = 0
        var sortingTime: TimeInterval = 0
        var scanTime: TimeInterval = 0
        var validationTime: TimeInterval = 0
        var duplicatesRemoved: Int = 0
        var area: Double = 0
        var perimeter: Double = 0
        var convexityIndex: Double = 0
    }

    // MARK: - Main Hull Generation Interface

    /// Generate convex hull from device cluster using Graham scan algorithm
    /// Returns coordinates in counter-clockwise order suitable for polygon rendering
    func generateHull(
        from devices: [PowerSenseDevice],
        config: HullConfig = .default
    ) async -> [CLLocationCoordinate2D] {

        guard devices.count >= config.minimumPoints else {
            algorithmLogger.warning("⚠️ Insufficient points for hull generation: \(devices.count) < \(config.minimumPoints)")
            return []
        }

        let startTime = Date()
        algorithmLogger.info("🔺 Graham scan started with \(devices.count) devices")

        var metrics = HullMetrics()
        metrics.inputPoints = devices.count

        // Convert devices to coordinates and remove duplicates
        let coordinates = await preprocessCoordinates(devices, config: config, metrics: &metrics)

        guard coordinates.count >= config.minimumPoints else {
            algorithmLogger.warning("⚠️ Insufficient unique coordinates after preprocessing: \(coordinates.count)")
            return []
        }

        // Perform Graham scan algorithm
        let hull = await performGrahamScan(coordinates: coordinates, config: config, metrics: &metrics)

        // Calculate final metrics
        metrics.processingTime = Date().timeIntervalSince(startTime)
        metrics.outputPoints = hull.count

        if config.enableGeometricValidation {
            await validateAndAnalyzeHull(hull: hull, config: config, metrics: &metrics)
        }

        await logHullResults(metrics: metrics, config: config)

        // Performance validation
        if metrics.processingTime > config.maxProcessingTime {
            performanceLogger.warning("⚠️ Hull generation exceeded target time: \(String(format: "%.6f", metrics.processingTime))s > \(String(format: "%.6f", config.maxProcessingTime))s")
        }

        return hull
    }

    /// Generate hull with confidence score based on spatial coverage
    func generateHullWithConfidence(
        from devices: [PowerSenseDevice],
        spatialManager: SpatialDeviceManager,
        config: HullConfig = .default
    ) async -> (hull: [CLLocationCoordinate2D], confidence: Double) {

        let hull = await generateHull(from: devices, config: config)
        guard !hull.isEmpty else {
            return (hull: [], confidence: 0.0)
        }

        let confidence = await calculateConfidence(
            hull: hull,
            clusterDevices: devices,
            spatialManager: spatialManager
        )

        algorithmLogger.info("📊 Hull generated with confidence: \(String(format: "%.3f", confidence))")
        return (hull: hull, confidence: confidence)
    }

    // MARK: - Graham Scan Algorithm Implementation

    /// Preprocess coordinates: remove duplicates and handle edge cases
    private func preprocessCoordinates(
        _ devices: [PowerSenseDevice],
        config: HullConfig,
        metrics: inout HullMetrics
    ) async -> [CLLocationCoordinate2D] {

        let startTime = Date()

        // Extract coordinates
        var coordinates = devices.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }

        let originalCount = coordinates.count
        debugLogger.debug("🔧 Preprocessing \(originalCount) coordinates")

        // Remove duplicates with precision tolerance
        coordinates = removeDuplicates(coordinates, precision: config.coordinatePrecision)
        metrics.duplicatesRemoved = originalCount - coordinates.count

        // Handle edge cases
        if coordinates.count <= 2 {
            algorithmLogger.warning("⚠️ Insufficient unique points after duplicate removal: \(coordinates.count)")
            return coordinates
        }

        let preprocessTime = Date().timeIntervalSince(startTime)
        debugLogger.debug("🔧 Preprocessing completed in \(String(format: "%.6f", preprocessTime))s, removed \(metrics.duplicatesRemoved) duplicates")

        return coordinates
    }

    /// Core Graham scan algorithm implementation
    private func performGrahamScan(
        coordinates: [CLLocationCoordinate2D],
        config: HullConfig,
        metrics: inout HullMetrics
    ) async -> [CLLocationCoordinate2D] {

        guard coordinates.count >= 3 else { return coordinates }

        let sortStart = Date()

        // Step 1: Find the bottommost point (lowest y, leftmost if tie)
        let bottomPoint = coordinates.min { first, second in
            if abs(first.latitude - second.latitude) < config.coordinatePrecision {
                return first.longitude < second.longitude
            }
            return first.latitude < second.latitude
        }!

        debugLogger.debug("🎯 Bottom point selected: (\(String(format: "%.6f", bottomPoint.latitude)), \(String(format: "%.6f", bottomPoint.longitude)))")

        // Step 2: Sort points by polar angle with respect to bottom point
        let sortedPoints = coordinates.filter { !coordinatesEqual($0, bottomPoint, precision: config.coordinatePrecision) }
            .sorted { first, second in
                let cross = crossProduct(bottomPoint, first, second)
                if abs(cross) < config.coordinatePrecision {
                    // Collinear points - choose closer one
                    return distanceSquared(bottomPoint, first) < distanceSquared(bottomPoint, second)
                }
                return cross > 0 // Counter-clockwise order
            }

        metrics.sortingTime = Date().timeIntervalSince(sortStart)
        debugLogger.debug("🔄 Sorted \(sortedPoints.count) points by polar angle in \(String(format: "%.6f", metrics.sortingTime))s")

        let scanStart = Date()

        // Step 3: Graham scan main algorithm
        var hull: [CLLocationCoordinate2D] = [bottomPoint]

        for point in sortedPoints {
            // Remove points that create clockwise turn
            while hull.count > 1 {
                let prev = hull[hull.count - 2]
                let curr = hull[hull.count - 1]
                let cross = crossProduct(prev, curr, point)

                if cross > config.coordinatePrecision {
                    break // Left turn (counter-clockwise) - keep point
                } else {
                    hull.removeLast() // Right turn or collinear - remove point
                    debugLogger.debug("↩️ Removed point from hull (clockwise turn detected)")
                }
            }
            hull.append(point)
        }

        metrics.scanTime = Date().timeIntervalSince(scanStart)
        geometryLogger.info("🔺 Graham scan completed: \(coordinates.count) → \(hull.count) vertices")

        return hull
    }

    // MARK: - Confidence Calculation

    /// Calculate confidence score based on spatial coverage and density
    private func calculateConfidence(
        hull: [CLLocationCoordinate2D],
        clusterDevices: [PowerSenseDevice],
        spatialManager: SpatialDeviceManager
    ) async -> Double {

        guard !hull.isEmpty else { return 0.0 }

        let startTime = Date()

        // Calculate hull area and bounds
        let hullArea = calculatePolygonArea(hull)
        let bounds = calculateBounds(hull)

        // Query all devices within hull bounds
        let boundsRect = MKMapRect(
            x: MKMapPoint(CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLon)).x,
            y: MKMapPoint(CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.maxLon)).y,
            width: MKMapPoint(CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.maxLon)).x - MKMapPoint(CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLon)).x,
            height: MKMapPoint(CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLon)).y - MKMapPoint(CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.maxLon)).y
        )

        let allDevicesInBounds = await spatialManager.getOfflineDevices(in: boundsRect)
        let offlineDevicesInBounds = allDevicesInBounds.filter { $0.isOffline }

        // Confidence factors
        let coverageRatio = Double(clusterDevices.count) / Double(max(1, allDevicesInBounds.count))
        let densityScore = Double(clusterDevices.count) / max(hullArea, 0.0001)
        let spatialCoherence = calculateSpatialCoherence(devices: clusterDevices)

        // Weighted confidence score
        let confidence = (coverageRatio * 0.4 + min(1.0, densityScore * 0.001) * 0.3 + spatialCoherence * 0.3)

        let confidenceTime = Date().timeIntervalSince(startTime)
        geometryLogger.debug("📊 Confidence calculation: coverage=\(String(format: "%.3f", coverageRatio)), density=\(String(format: "%.6f", densityScore)), coherence=\(String(format: "%.3f", spatialCoherence))")
        debugLogger.debug("⏱️ Confidence calculated in \(String(format: "%.6f", confidenceTime))s")

        return min(1.0, max(0.0, confidence))
    }

    // MARK: - Geometric Calculations

    /// Calculate cross product for determining turn direction
    private func crossProduct(_ o: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        return (a.latitude - o.latitude) * (b.longitude - o.longitude) - (a.longitude - o.longitude) * (b.latitude - o.latitude)
    }

    /// Calculate squared distance between two points (for efficiency)
    private func distanceSquared(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let deltaLat = a.latitude - b.latitude
        let deltaLon = a.longitude - b.longitude
        return deltaLat * deltaLat + deltaLon * deltaLon
    }

    /// Calculate actual distance between two coordinates in meters
    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let locationA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locationB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locationA.distance(from: locationB)
    }

    /// Check if coordinates are equal within precision tolerance
    private func coordinatesEqual(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, precision: Double) -> Bool {
        return abs(a.latitude - b.latitude) < precision && abs(a.longitude - b.longitude) < precision
    }

    /// Remove duplicate coordinates within precision tolerance
    private func removeDuplicates(_ coordinates: [CLLocationCoordinate2D], precision: Double) -> [CLLocationCoordinate2D] {
        var unique: [CLLocationCoordinate2D] = []

        for coord in coordinates {
            let isDuplicate = unique.contains { existing in
                coordinatesEqual(coord, existing, precision: precision)
            }

            if !isDuplicate {
                unique.append(coord)
            }
        }

        return unique
    }

    /// Calculate polygon area using shoelace formula
    private func calculatePolygonArea(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 3 else { return 0.0 }

        var area: Double = 0.0
        let n = coordinates.count

        for i in 0..<n {
            let j = (i + 1) % n
            area += coordinates[i].latitude * coordinates[j].longitude
            area -= coordinates[j].latitude * coordinates[i].longitude
        }

        return abs(area) / 2.0
    }

    /// Calculate bounding box of coordinates
    private func calculateBounds(_ coordinates: [CLLocationCoordinate2D]) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        guard !coordinates.isEmpty else { return (0, 0, 0, 0) }

        let lats = coordinates.map { $0.latitude }
        let lons = coordinates.map { $0.longitude }

        return (
            minLat: lats.min() ?? 0,
            maxLat: lats.max() ?? 0,
            minLon: lons.min() ?? 0,
            maxLon: lons.max() ?? 0
        )
    }

    /// Calculate spatial coherence of device cluster
    private func calculateSpatialCoherence(devices: [PowerSenseDevice]) -> Double {
        guard devices.count > 1 else { return 1.0 }

        // Calculate centroid
        let centerLat = devices.map { $0.latitude }.reduce(0, +) / Double(devices.count)
        let centerLon = devices.map { $0.longitude }.reduce(0, +) / Double(devices.count)
        let centroid = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)

        // Calculate distances from centroid
        let distances = devices.map { device in
            distance(CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude), centroid)
        }

        // Lower standard deviation = higher coherence
        let mean = distances.reduce(0, +) / Double(distances.count)
        let variance = distances.map { pow($0 - mean, 2) }.reduce(0, +) / Double(distances.count)
        let stdDev = sqrt(variance)

        // Normalize coherence score (lower stdDev = higher coherence)
        return max(0.0, 1.0 - (stdDev / max(mean, 1.0)))
    }

    // MARK: - Validation and Analysis

    /// Validate hull geometry and calculate quality metrics
    private func validateAndAnalyzeHull(
        hull: [CLLocationCoordinate2D],
        config: HullConfig,
        metrics: inout HullMetrics
    ) async {

        let startTime = Date()

        guard hull.count >= 3 else {
            errorLogger.warning("⚠️ Invalid hull: insufficient vertices (\(hull.count))")
            return
        }

        // Calculate geometric properties
        metrics.area = calculatePolygonArea(hull)
        metrics.perimeter = calculatePerimeter(hull)

        // Validate convexity
        let isConvex = validateConvexity(hull, precision: config.coordinatePrecision)
        metrics.convexityIndex = isConvex ? 1.0 : 0.0

        metrics.validationTime = Date().timeIntervalSince(startTime)

        geometryLogger.info("📐 Hull validation completed")
        debugLogger.debug("📊 Area: \(String(format: "%.6f", metrics.area)) deg²")
        debugLogger.debug("📊 Perimeter: \(String(format: "%.6f", metrics.perimeter)) deg")
        debugLogger.debug("📊 Convex: \(isConvex)")

        if !isConvex {
            errorLogger.error("❌ Generated hull is not convex - algorithm error!")
        }
    }

    /// Calculate polygon perimeter
    private func calculatePerimeter(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0.0 }

        var perimeter: Double = 0.0
        for i in 0..<coordinates.count {
            let current = coordinates[i]
            let next = coordinates[(i + 1) % coordinates.count]
            perimeter += distance(current, next)
        }

        return perimeter
    }

    /// Validate that hull is actually convex
    private func validateConvexity(_ coordinates: [CLLocationCoordinate2D], precision: Double) -> Bool {
        guard coordinates.count >= 3 else { return true }

        var sign: Int? = nil

        for i in 0..<coordinates.count {
            let o = coordinates[i]
            let a = coordinates[(i + 1) % coordinates.count]
            let b = coordinates[(i + 2) % coordinates.count]

            let cross = crossProduct(o, a, b)

            if abs(cross) < precision { continue } // Skip collinear points

            let currentSign = cross > 0 ? 1 : -1

            if let existingSign = sign {
                if currentSign != existingSign {
                    return false // Direction changed - not convex
                }
            } else {
                sign = currentSign
            }
        }

        return true
    }

    // MARK: - Results Logging

    /// Log comprehensive hull generation results
    private func logHullResults(metrics: HullMetrics, config: HullConfig) async {

        algorithmLogger.info("""
        🔺 GRAHAM SCAN HULL GENERATION COMPLETED:
        ========================================
        • Input Points: \(metrics.inputPoints)
        • Output Vertices: \(metrics.outputPoints)
        • Duplicates Removed: \(metrics.duplicatesRemoved)
        • Vertex Reduction: \(String(format: "%.1f", (1.0 - Double(metrics.outputPoints) / Double(metrics.inputPoints)) * 100))%

        ⏱️ PERFORMANCE BREAKDOWN:
        • Total Time: \(String(format: "%.6f", metrics.processingTime))s
        • Sorting Phase: \(String(format: "%.6f", metrics.sortingTime))s (\(String(format: "%.1f", metrics.sortingTime / metrics.processingTime * 100))%)
        • Scanning Phase: \(String(format: "%.6f", metrics.scanTime))s (\(String(format: "%.1f", metrics.scanTime / metrics.processingTime * 100))%)
        • Validation Phase: \(String(format: "%.6f", metrics.validationTime))s (\(String(format: "%.1f", metrics.validationTime / metrics.processingTime * 100))%)

        📐 GEOMETRIC PROPERTIES:
        • Hull Area: \(String(format: "%.6f", metrics.area)) deg²
        • Hull Perimeter: \(String(format: "%.6f", metrics.perimeter)) deg
        • Convexity Index: \(String(format: "%.3f", metrics.convexityIndex))
        • Processing Rate: \(String(format: "%.0f", Double(metrics.inputPoints) / metrics.processingTime)) points/sec
        """)

        // Performance assessment
        if metrics.processingTime < config.maxProcessingTime {
            performanceLogger.info("🎯 Hull generation within performance target: \(String(format: "%.6f", metrics.processingTime))s < \(String(format: "%.6f", config.maxProcessingTime))s")
        }

        // Quality assessment
        let reductionRatio = 1.0 - Double(metrics.outputPoints) / Double(metrics.inputPoints)
        if reductionRatio > 0.5 {
            geometryLogger.info("✅ Good vertex reduction: \(String(format: "%.1f", reductionRatio * 100))%")
        } else if reductionRatio < 0.1 {
            geometryLogger.warning("⚠️ Low vertex reduction: \(String(format: "%.1f", reductionRatio * 100))% - input points may already be on hull")
        }
    }
}

// MARK: - Batch Processing Extension

extension GrahamScanHullGenerator {

    /// Generate multiple hulls in parallel for improved performance
    public func generateHullsBatch(
        clusters: [[PowerSenseDevice]],
        config: HullConfig = .default
    ) async -> [(hull: [CLLocationCoordinate2D], clusterIndex: Int)] {

        let startTime = Date()
        algorithmLogger.info("🔄 Batch hull generation started for \(clusters.count) clusters")

        guard !clusters.isEmpty else {
            algorithmLogger.warning("⚠️ No clusters provided for batch processing")
            return []
        }

        // Use TaskGroup for concurrent processing
        return await withTaskGroup(of: (hull: [CLLocationCoordinate2D], clusterIndex: Int).self) { group in
            var results: [(hull: [CLLocationCoordinate2D], clusterIndex: Int)] = []

            // Add tasks for each cluster
            for (index, cluster) in clusters.enumerated() {
                group.addTask { [weak self] in
                    let hull = await self?.generateHull(from: cluster, config: config) ?? []
                    return (hull: hull, clusterIndex: index)
                }
            }

            // Collect results as they complete
            for await result in group {
                results.append(result)
            }

            // Sort results by cluster index to maintain order
            results.sort { $0.clusterIndex < $1.clusterIndex }

            let totalTime = Date().timeIntervalSince(startTime)
            let avgTimePerHull = totalTime / Double(clusters.count)

            performanceLogger.info("🔄 Parallel batch processing completed in \(String(format: "%.3f", totalTime))s")
            performanceLogger.info("📊 Average time per hull: \(String(format: "%.6f", avgTimePerHull))s")
            performanceLogger.info("⚡ Parallel efficiency: Processing \(clusters.count) clusters concurrently")

            return results
        }
    }

    /// Generate hulls with controlled concurrency for resource management
    public func generateHullsBatchWithConcurrencyLimit(
        clusters: [[PowerSenseDevice]],
        maxConcurrency: Int = 4,
        config: HullConfig = .default
    ) async -> [(hull: [CLLocationCoordinate2D], clusterIndex: Int)] {

        let startTime = Date()
        algorithmLogger.info("🔄 Batch hull generation with concurrency limit (\(maxConcurrency)) for \(clusters.count) clusters")

        guard !clusters.isEmpty else { return [] }

        var results: [(hull: [CLLocationCoordinate2D], clusterIndex: Int)] = []

        // Process clusters in batches to control memory usage
        let batchSize = maxConcurrency
        let totalBatches = (clusters.count + batchSize - 1) / batchSize

        for batchIndex in 0..<totalBatches {
            let startIndex = batchIndex * batchSize
            let endIndex = min(startIndex + batchSize, clusters.count)
            let batchClusters = Array(clusters[startIndex..<endIndex])

            performanceLogger.debug("🔄 Processing batch \(batchIndex + 1)/\(totalBatches) (\(batchClusters.count) clusters)")

            // Process current batch in parallel
            let batchResults = await withTaskGroup(of: (hull: [CLLocationCoordinate2D], clusterIndex: Int).self) { group in
                var batchResults: [(hull: [CLLocationCoordinate2D], clusterIndex: Int)] = []

                for (localIndex, cluster) in batchClusters.enumerated() {
                    let globalIndex = startIndex + localIndex
                    group.addTask { [weak self] in
                        let hull = await self?.generateHull(from: cluster, config: config) ?? []
                        return (hull: hull, clusterIndex: globalIndex)
                    }
                }

                for await result in group {
                    batchResults.append(result)
                }

                return batchResults.sorted { $0.clusterIndex < $1.clusterIndex }
            }

            results.append(contentsOf: batchResults)
        }

        let totalTime = Date().timeIntervalSince(startTime)
        let avgTimePerHull = totalTime / Double(clusters.count)

        performanceLogger.info("🔄 Controlled concurrency batch processing completed in \(String(format: "%.3f", totalTime))s")
        performanceLogger.info("📊 Average time per hull: \(String(format: "%.6f", avgTimePerHull))s")
        performanceLogger.info("⚡ Processed \(totalBatches) batches with max \(maxConcurrency) concurrent operations")

        return results
    }
}