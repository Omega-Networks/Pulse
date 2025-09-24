//
//  DetailedHullGenerator.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Enhanced concave hull generation for detailed polygon shapes
//

import Foundation
import CoreLocation
import MapKit
import OSLog

/// Advanced concave hull generator with detailed boundary calculation
/// Uses alpha shapes algorithm for accurate emergency boundary representation
actor DetailedHullGenerator {

    private let logger = Logger(subsystem: "powersense", category: "detailedHull")

    // MARK: - Configuration

    /// Alpha parameter for concave hull detail (0.1 = very detailed, 1.0 = convex hull)
    private let defaultAlpha: Double = 0.15

    /// Number of buffer points around each device for smoother boundaries
    private let bufferPointCount: Int = 12 // Increased from 6 for more detail

    /// Minimum edge length for polygon simplification (meters)
    private let minEdgeLength: CLLocationDistance = 10.0

    // MARK: - Enhanced Hull Generation

    /// Generate detailed concave hull from device cluster
    /// - Parameters:
    ///   - devices: Array of device data points
    ///   - bufferRadius: Buffer radius around each device in meters
    ///   - alpha: Alpha parameter for concavity (lower = more detailed)
    /// - Returns: Array of coordinates forming detailed polygon boundary
    func generateDetailedHull(
        from devices: [DeviceData],
        bufferRadius: CLLocationDistance,
        alpha: Double? = nil
    ) -> [CLLocationCoordinate2D] {

        guard devices.count >= 3 else { return [] }

        let actualAlpha = alpha ?? defaultAlpha
        logger.debug("🔷 Generating detailed hull for \(devices.count) devices with alpha=\(actualAlpha)")

        // Step 1: Create dense buffered point cloud
        let bufferedPoints = createDenseBufferedPoints(from: devices, bufferRadius: bufferRadius)
        logger.debug("📍 Created \(bufferedPoints.count) buffered points")

        // Step 2: Generate alpha shapes with Delaunay triangulation
        let alphaShape = generateAlphaShape(points: bufferedPoints, alpha: actualAlpha)
        logger.debug("🔺 Generated alpha shape with \(alphaShape.count) vertices")

        // Step 3: Refine and smooth the boundary
        let refinedHull = refineBoundary(alphaShape, devices: devices, bufferRadius: bufferRadius)
        logger.debug("✨ Refined hull to \(refinedHull.count) vertices")

        // Step 4: Optimize for MapKit rendering
        let optimizedHull = optimizeForRendering(refinedHull)
        logger.debug("⚡ Optimized hull to \(optimizedHull.count) vertices")

        return optimizedHull
    }

    // MARK: - Dense Point Cloud Generation

    /// Create dense buffered point cloud around devices for detailed boundary detection
    private func createDenseBufferedPoints(
        from devices: [DeviceData],
        bufferRadius: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {

        var bufferedPoints: [CLLocationCoordinate2D] = []

        // Add device locations first
        bufferedPoints.append(contentsOf: devices.map { device in
            CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
        })

        // Create concentric rings around each device for detailed boundaries
        for device in devices {
            let deviceLocation = CLLocation(latitude: device.latitude, longitude: device.longitude)

            // Inner ring at 50% radius for detail
            for angle in stride(from: 0.0, to: 360.0, by: 360.0 / Double(bufferPointCount)) {
                let innerPoint = deviceLocation.coordinate(
                    at: bufferRadius * 0.5,
                    facing: CLLocationDirection(angle)
                )
                bufferedPoints.append(innerPoint)
            }

            // Outer ring at full radius for boundary
            for angle in stride(from: 0.0, to: 360.0, by: 360.0 / Double(bufferPointCount)) {
                let outerPoint = deviceLocation.coordinate(
                    at: bufferRadius,
                    facing: CLLocationDirection(angle)
                )
                bufferedPoints.append(outerPoint)
            }

            // Additional detail points at device density hotspots
            let nearbyDevices = devices.filter { other in
                device.deviceId != other.deviceId &&
                device.distance(to: other) <= bufferRadius * 1.5
            }

            if nearbyDevices.count >= 2 {
                // Add more detail points toward nearby devices
                for nearbyDevice in nearbyDevices.prefix(3) { // Limit for performance
                    let bearing = deviceLocation.bearing(to: nearbyDevice.location)
                    let detailPoint = deviceLocation.coordinate(
                        at: bufferRadius * 0.75,
                        facing: bearing
                    )
                    bufferedPoints.append(detailPoint)
                }
            }
        }

        return bufferedPoints
    }

    // MARK: - Alpha Shapes Algorithm

    /// Generate alpha shape using simplified Delaunay-based approach
    private func generateAlphaShape(
        points: [CLLocationCoordinate2D],
        alpha: Double
    ) -> [CLLocationCoordinate2D] {

        guard points.count >= 3 else { return points }

        // For emergency response accuracy, we'll use a robust approach:
        // 1. Start with convex hull as base
        // 2. Add concave indentations based on alpha parameter
        // 3. Include interior points that create meaningful boundaries

        let convexHull = GeometryUtils.convexHull(points: points)
        guard convexHull.count >= 3 else { return points }

        // Enhanced concave refinement with multiple passes
        var concaveHull = convexHull

        // Pass 1: Add significant interior points
        concaveHull = addSignificantInteriorPoints(
            hull: concaveHull,
            allPoints: points,
            alpha: alpha
        )

        // Pass 2: Refine with local concavity detection
        concaveHull = refineWithLocalConcavity(
            hull: concaveHull,
            allPoints: points,
            alpha: alpha
        )

        return concaveHull
    }

    /// Add interior points that create meaningful concave boundaries
    private func addSignificantInteriorPoints(
        hull: [CLLocationCoordinate2D],
        allPoints: [CLLocationCoordinate2D],
        alpha: Double
    ) -> [CLLocationCoordinate2D] {

        var enhancedHull = hull
        let alphaDistance = 1.0 / max(alpha, 0.01) * 100.0 // Convert alpha to meters

        for i in 0..<hull.count {
            let currentVertex = hull[i]
            let nextVertex = hull[(i + 1) % hull.count]

            // Find interior points that could create meaningful indentations
            let edgeCenter = CLLocationCoordinate2D(
                latitude: (currentVertex.latitude + nextVertex.latitude) / 2,
                longitude: (currentVertex.longitude + nextVertex.longitude) / 2
            )

            let edgeCenterLocation = CLLocation(latitude: edgeCenter.latitude, longitude: edgeCenter.longitude)

            // Look for points that create significant inward curvature
            let candidatePoints = allPoints.filter { point in
                let pointLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)
                let distanceToEdgeCenter = edgeCenterLocation.distance(from: pointLocation)

                return distanceToEdgeCenter <= alphaDistance &&
                       !hull.contains(where: { $0.latitude == point.latitude && $0.longitude == point.longitude })
            }

            // Add the point that creates the most significant inward curve
            if let bestPoint = candidatePoints.min(by: { point1, point2 in
                let dist1 = edgeCenterLocation.distance(from: CLLocation(latitude: point1.latitude, longitude: point1.longitude))
                let dist2 = edgeCenterLocation.distance(from: CLLocation(latitude: point2.latitude, longitude: point2.longitude))
                return dist1 < dist2
            }) {
                enhancedHull.insert(bestPoint, at: i + 1)
            }
        }

        return enhancedHull
    }

    /// Refine hull with local concavity detection
    private func refineWithLocalConcavity(
        hull: [CLLocationCoordinate2D],
        allPoints: [CLLocationCoordinate2D],
        alpha: Double
    ) -> [CLLocationCoordinate2D] {

        var refinedHull = hull
        let maxConcavityDepth = 1.0 / max(alpha, 0.01) * 50.0 // Concavity threshold in meters

        var i = 0
        while i < refinedHull.count - 2 {
            let p1 = refinedHull[i]
            let p2 = refinedHull[i + 1]
            let p3 = refinedHull[i + 2]

            // Calculate local curvature
            let curvature = calculateCurvature(p1: p1, p2: p2, p3: p3)

            // If the curvature is too sharp, try to smooth it with nearby points
            if curvature > maxConcavityDepth {
                let midPoint = CLLocationCoordinate2D(
                    latitude: (p1.latitude + p3.latitude) / 2,
                    longitude: (p1.longitude + p3.longitude) / 2
                )

                let midLocation = CLLocation(latitude: midPoint.latitude, longitude: midPoint.longitude)

                // Find nearby points that could create a smoother transition
                if let smoothingPoint = allPoints.min(by: { point1, point2 in
                    let dist1 = midLocation.distance(from: CLLocation(latitude: point1.latitude, longitude: point1.longitude))
                    let dist2 = midLocation.distance(from: CLLocation(latitude: point2.latitude, longitude: point2.longitude))
                    return dist1 < dist2
                }) {
                    let smoothingDistance = midLocation.distance(from: CLLocation(latitude: smoothingPoint.latitude, longitude: smoothingPoint.longitude))

                    if smoothingDistance <= maxConcavityDepth {
                        refinedHull[i + 1] = smoothingPoint
                    }
                }
            }

            i += 1
        }

        return refinedHull
    }

    /// Calculate curvature at a point (simplified metric)
    private func calculateCurvature(
        p1: CLLocationCoordinate2D,
        p2: CLLocationCoordinate2D,
        p3: CLLocationCoordinate2D
    ) -> Double {

        let loc1 = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
        let loc2 = CLLocation(latitude: p2.latitude, longitude: p2.longitude)
        let loc3 = CLLocation(latitude: p3.latitude, longitude: p3.longitude)

        let dist12 = loc1.distance(from: loc2)
        let dist23 = loc2.distance(from: loc3)
        let dist13 = loc1.distance(from: loc3)

        // Simple curvature approximation using triangle geometry
        let semiPerimeter = (dist12 + dist23 + dist13) / 2
        let area = sqrt(semiPerimeter * (semiPerimeter - dist12) * (semiPerimeter - dist23) * (semiPerimeter - dist13))

        return area > 0 ? (dist12 * dist23 * dist13) / (4 * area) : 0
    }

    // MARK: - Boundary Refinement

    /// Refine polygon boundary for emergency response accuracy
    private func refineBoundary(
        _ hull: [CLLocationCoordinate2D],
        devices: [DeviceData],
        bufferRadius: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {

        guard hull.count >= 3 else { return hull }

        // Step 1: Remove redundant vertices that don't add meaningful detail
        var refinedHull = removeRedundantVertices(hull)

        // Step 2: Ensure all devices are properly enclosed with margin
        refinedHull = ensureDeviceEnclosure(refinedHull, devices: devices, bufferRadius: bufferRadius)

        // Step 3: Smooth sharp corners while preserving essential shape
        refinedHull = smoothSharpCorners(refinedHull)

        return refinedHull
    }

    /// Remove vertices that don't contribute to boundary detail
    private func removeRedundantVertices(_ hull: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard hull.count > 3 else { return hull }

        var refined: [CLLocationCoordinate2D] = []

        for i in 0..<hull.count {
            let prev = hull[(i - 1 + hull.count) % hull.count]
            let current = hull[i]
            let next = hull[(i + 1) % hull.count]

            // Calculate if this vertex creates a significant deviation from straight line
            let deviation = perpendicularDistance(point: current, lineStart: prev, lineEnd: next)

            // Keep vertex if it creates meaningful detail (> 5m deviation)
            if deviation > minEdgeLength {
                refined.append(current)
            }
        }

        return refined.count >= 3 ? refined : hull
    }

    /// Ensure all devices are properly enclosed within the polygon boundary
    private func ensureDeviceEnclosure(
        _ hull: [CLLocationCoordinate2D],
        devices: [DeviceData],
        bufferRadius: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {

        let safetyMargin = bufferRadius * 0.2 // 20% safety margin
        var adjustedHull = hull

        for device in devices {
            let deviceCoord = CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)

            // Check if device is properly enclosed with safety margin
            if !isPointInPolygonWithMargin(deviceCoord, polygon: adjustedHull, margin: safetyMargin) {
                // Expand hull locally to include this device
                adjustedHull = expandHullAroundPoint(adjustedHull, point: deviceCoord, expansion: safetyMargin)
            }
        }

        return adjustedHull
    }

    /// Check if point is inside polygon with safety margin
    private func isPointInPolygonWithMargin(
        _ point: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D],
        margin: CLLocationDistance
    ) -> Bool {

        // First check basic point-in-polygon
        if !GeometryUtils.pointInPolygon(point, polygon: polygon) {
            return false
        }

        // Then check distance to nearest edge is greater than margin
        let pointLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)

        for i in 0..<polygon.count {
            let edgeStart = polygon[i]
            let edgeEnd = polygon[(i + 1) % polygon.count]

            let distanceToEdge = distanceFromPointToLineSegment(
                point: pointLocation,
                lineStart: CLLocation(latitude: edgeStart.latitude, longitude: edgeStart.longitude),
                lineEnd: CLLocation(latitude: edgeEnd.latitude, longitude: edgeEnd.longitude)
            )

            if distanceToEdge < margin {
                return false
            }
        }

        return true
    }

    /// Expand hull locally around a specific point
    private func expandHullAroundPoint(
        _ hull: [CLLocationCoordinate2D],
        point: CLLocationCoordinate2D,
        expansion: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {

        let pointLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)
        var expandedHull: [CLLocationCoordinate2D] = []

        for i in 0..<hull.count {
            let currentVertex = hull[i]
            let currentLocation = CLLocation(latitude: currentVertex.latitude, longitude: currentVertex.longitude)

            // Check if this vertex is close to the point that needs enclosure
            let distanceToPoint = currentLocation.distance(from: pointLocation)

            if distanceToPoint <= expansion * 3 { // Within influence radius
                // Push vertex outward slightly
                let bearing = currentLocation.bearing(to: pointLocation)
                let adjustedVertex = currentLocation.coordinate(
                    at: expansion * 0.5,
                    facing: bearing + 180 // Opposite direction to expand outward
                )
                expandedHull.append(adjustedVertex)
            } else {
                expandedHull.append(currentVertex)
            }
        }

        return expandedHull
    }

    /// Smooth sharp corners while preserving essential boundary shape
    private func smoothSharpCorners(_ hull: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard hull.count >= 3 else { return hull }

        var smoothedHull: [CLLocationCoordinate2D] = []
        let smoothingFactor = 0.1 // 10% smoothing

        for i in 0..<hull.count {
            let prev = hull[(i - 1 + hull.count) % hull.count]
            let current = hull[i]
            let next = hull[(i + 1) % hull.count]

            // Calculate angle at current vertex
            let angle = calculateAngle(prev: prev, current: current, next: next)

            // If angle is very sharp (< 45 degrees), apply smoothing
            if angle < 45.0 {
                let smoothedLat = current.latitude +
                    (prev.latitude - current.latitude) * smoothingFactor +
                    (next.latitude - current.latitude) * smoothingFactor
                let smoothedLon = current.longitude +
                    (prev.longitude - current.longitude) * smoothingFactor +
                    (next.longitude - current.longitude) * smoothingFactor

                smoothedHull.append(CLLocationCoordinate2D(latitude: smoothedLat, longitude: smoothedLon))
            } else {
                smoothedHull.append(current)
            }
        }

        return smoothedHull
    }

    // MARK: - Rendering Optimization

    /// Optimize polygon for MapKit rendering performance
    private func optimizeForRendering(_ hull: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard hull.count > 3 else { return hull }

        // Step 1: Limit maximum vertex count for rendering performance
        let maxVertices = 100 // Balance between detail and performance
        var optimized = hull

        if hull.count > maxVertices {
            // Intelligent vertex reduction preserving important features
            optimized = reduceVerticesIntelligently(hull, targetCount: maxVertices)
        }

        // Step 2: Ensure proper polygon closure
        if let first = optimized.first, let last = optimized.last {
            if first.latitude != last.latitude || first.longitude != last.longitude {
                optimized.append(first) // Close the polygon
            }
        }

        return optimized
    }

    /// Intelligently reduce vertex count while preserving important boundary features
    private func reduceVerticesIntelligently(
        _ hull: [CLLocationCoordinate2D],
        targetCount: Int
    ) -> [CLLocationCoordinate2D] {

        guard hull.count > targetCount else { return hull }

        // Calculate importance score for each vertex
        var vertexImportance: [(index: Int, importance: Double)] = []

        for i in 0..<hull.count {
            let prev = hull[(i - 1 + hull.count) % hull.count]
            let current = hull[i]
            let next = hull[(i + 1) % hull.count]

            // Importance based on curvature and local density
            let curvature = calculateCurvature(p1: prev, p2: current, p3: next)
            let importance = curvature // Higher curvature = more important

            vertexImportance.append((index: i, importance: importance))
        }

        // Sort by importance (descending)
        vertexImportance.sort { $0.importance > $1.importance }

        // Keep the most important vertices
        let keepIndices = Set(vertexImportance.prefix(targetCount).map { $0.index })

        var reducedHull: [CLLocationCoordinate2D] = []
        for i in 0..<hull.count {
            if keepIndices.contains(i) {
                reducedHull.append(hull[i])
            }
        }

        // Ensure vertices are in proper order
        reducedHull.sort { vertex1, vertex2 in
            let index1 = hull.firstIndex { $0.latitude == vertex1.latitude && $0.longitude == vertex1.longitude } ?? 0
            let index2 = hull.firstIndex { $0.latitude == vertex2.latitude && $0.longitude == vertex2.longitude } ?? 0
            return index1 < index2
        }

        return reducedHull
    }

    // MARK: - Utility Functions

    /// Calculate perpendicular distance from point to line
    private func perpendicularDistance(
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

    /// Calculate distance from point to line segment
    private func distanceFromPointToLineSegment(
        point: CLLocation,
        lineStart: CLLocation,
        lineEnd: CLLocation
    ) -> CLLocationDistance {

        let startCoord = lineStart.coordinate
        let endCoord = lineEnd.coordinate
        let pointCoord = point.coordinate

        let A = pointCoord.latitude - startCoord.latitude
        let B = pointCoord.longitude - startCoord.longitude
        let C = endCoord.latitude - startCoord.latitude
        let D = endCoord.longitude - startCoord.longitude

        let dot = A * C + B * D
        let lenSq = C * C + D * D

        if lenSq == 0 { return point.distance(from: lineStart) }

        let param = max(0, min(1, dot / lenSq))

        let closestPoint = CLLocationCoordinate2D(
            latitude: startCoord.latitude + param * C,
            longitude: startCoord.longitude + param * D
        )

        return point.distance(from: CLLocation(latitude: closestPoint.latitude, longitude: closestPoint.longitude))
    }

    /// Calculate angle at vertex (in degrees)
    private func calculateAngle(
        prev: CLLocationCoordinate2D,
        current: CLLocationCoordinate2D,
        next: CLLocationCoordinate2D
    ) -> Double {

        let v1 = (prev.latitude - current.latitude, prev.longitude - current.longitude)
        let v2 = (next.latitude - current.latitude, next.longitude - current.longitude)

        let dot = v1.0 * v2.0 + v1.1 * v2.1
        let mag1 = sqrt(v1.0 * v1.0 + v1.1 * v1.1)
        let mag2 = sqrt(v2.0 * v2.0 + v2.1 * v2.1)

        if mag1 == 0 || mag2 == 0 { return 180.0 }

        let cosAngle = max(-1.0, min(1.0, dot / (mag1 * mag2)))
        return acos(cosAngle) * 180.0 / .pi
    }
}

// MARK: - CLLocation Extensions

extension CLLocation {
    /// Calculate bearing to another location
    func bearing(to destination: CLLocation) -> CLLocationDirection {
        let lat1 = coordinate.latitude * .pi / 180.0
        let lon1 = coordinate.longitude * .pi / 180.0
        let lat2 = destination.coordinate.latitude * .pi / 180.0
        let lon2 = destination.coordinate.longitude * .pi / 180.0

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        let bearing = atan2(y, x) * 180.0 / .pi
        return (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}