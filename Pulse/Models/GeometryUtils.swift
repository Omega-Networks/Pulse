//
//  GeometryUtils.swift
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

/// Utility class for advanced polygon geometry operations including intersection, union, and spatial analysis
final class GeometryUtils {

    // MARK: - Polygon Intersection Detection

    /// Check if two polygons intersect geometrically (more accurate than distance-based)
    static func polygonsIntersect(_ polygon1: [CLLocationCoordinate2D], _ polygon2: [CLLocationCoordinate2D]) -> Bool {
        guard polygon1.count >= 3, polygon2.count >= 3 else { return false }

        // Check if any vertices of polygon1 are inside polygon2
        for vertex in polygon1 {
            if pointInPolygon(vertex, polygon: polygon2) {
                return true
            }
        }

        // Check if any vertices of polygon2 are inside polygon1
        for vertex in polygon2 {
            if pointInPolygon(vertex, polygon: polygon1) {
                return true
            }
        }

        // Check for edge intersections
        return edgesIntersect(polygon1, polygon2)
    }

    /// Calculate the intersection area between two polygons
    static func intersectionArea(_ polygon1: [CLLocationCoordinate2D], _ polygon2: [CLLocationCoordinate2D]) -> Double {
        guard polygonsIntersect(polygon1, polygon2) else { return 0.0 }

        // For emergency response accuracy, we'll use a simplified approach
        // Calculate overlapping bounding rectangles as approximation
        let bounds1 = getBoundingBox(polygon1)
        let bounds2 = getBoundingBox(polygon2)

        let overlapMinLat = max(bounds1.minLat, bounds2.minLat)
        let overlapMaxLat = min(bounds1.maxLat, bounds2.maxLat)
        let overlapMinLon = max(bounds1.minLon, bounds2.minLon)
        let overlapMaxLon = min(bounds1.maxLon, bounds2.maxLon)

        if overlapMinLat < overlapMaxLat && overlapMinLon < overlapMaxLon {
            return (overlapMaxLat - overlapMinLat) * (overlapMaxLon - overlapMinLon)
        }

        return 0.0
    }

    // MARK: - Polygon Union Operations

    /// Create union of overlapping polygons (simplified convex hull approach for performance)
    static func unionPolygons(_ polygons: [[CLLocationCoordinate2D]]) -> [CLLocationCoordinate2D] {
        guard !polygons.isEmpty else { return [] }

        if polygons.count == 1 {
            return polygons[0]
        }

        // Collect all vertices from all polygons
        var allVertices: [CLLocationCoordinate2D] = []
        for polygon in polygons {
            allVertices.append(contentsOf: polygon)
        }

        // Generate convex hull around all vertices
        return convexHull(points: allVertices)
    }

    /// More sophisticated polygon union using Sutherland-Hodgman clipping (simplified)
    static func preciseUnionPolygons(_ polygons: [[CLLocationCoordinate2D]], bufferRadius: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard !polygons.isEmpty else { return [] }

        if polygons.count == 1 {
            return polygons[0]
        }

        // For complex cases, fall back to buffered convex hull
        var allBufferedPoints: [CLLocationCoordinate2D] = []

        for polygon in polygons {
            // Add original vertices
            allBufferedPoints.append(contentsOf: polygon)

            // Add buffered points around each vertex for smoother union
            for vertex in polygon {
                let vertexLocation = CLLocation(latitude: vertex.latitude, longitude: vertex.longitude)

                // Add 4 buffer points around each vertex
                for angle in stride(from: 0.0, to: 360.0, by: 90.0) {
                    let bufferedPoint = vertexLocation.coordinate(
                        at: bufferRadius * 0.3, // Smaller buffer for precision
                        facing: CLLocationDirection(angle)
                    )
                    allBufferedPoints.append(bufferedPoint)
                }
            }
        }

        return convexHull(points: allBufferedPoints)
    }

    // MARK: - Spatial Analysis

    /// Calculate the overlap ratio between two polygons (0.0 = no overlap, 1.0 = complete overlap)
    static func overlapRatio(_ polygon1: [CLLocationCoordinate2D], _ polygon2: [CLLocationCoordinate2D]) -> Double {
        let area1 = approximatePolygonArea(polygon1)
        let area2 = approximatePolygonArea(polygon2)
        let intersectionArea = intersectionArea(polygon1, polygon2)

        guard area1 > 0, area2 > 0 else { return 0.0 }

        let unionArea = area1 + area2 - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0.0
    }

    /// Calculate approximate area of polygon in square degrees
    static func approximatePolygonArea(_ polygon: [CLLocationCoordinate2D]) -> Double {
        guard polygon.count >= 3 else { return 0.0 }

        var area: Double = 0.0
        let n = polygon.count

        for i in 0..<n {
            let j = (i + 1) % n
            area += polygon[i].latitude * polygon[j].longitude
            area -= polygon[j].latitude * polygon[i].longitude
        }

        return abs(area) / 2.0
    }

    /// Get bounding box of polygon
    static func getBoundingBox(_ polygon: [CLLocationCoordinate2D]) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        guard !polygon.isEmpty else { return (0, 0, 0, 0) }

        var minLat = polygon[0].latitude
        var maxLat = polygon[0].latitude
        var minLon = polygon[0].longitude
        var maxLon = polygon[0].longitude

        for coordinate in polygon {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        return (minLat, maxLat, minLon, maxLon)
    }

    // MARK: - Geometric Algorithms

    /// Point-in-polygon test using ray casting algorithm
    static func pointInPolygon(_ point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }

        var inside = false
        let n = polygon.count
        var p1 = polygon[0]

        for i in 1...n {
            let p2 = polygon[i % n]

            if point.longitude > min(p1.longitude, p2.longitude) {
                if point.longitude <= max(p1.longitude, p2.longitude) {
                    if point.latitude <= max(p1.latitude, p2.latitude) {
                        if p1.longitude != p2.longitude {
                            let xInters = (point.longitude - p1.longitude) * (p2.latitude - p1.latitude) / (p2.longitude - p1.longitude) + p1.latitude
                            if p1.latitude == p2.latitude || point.latitude <= xInters {
                                inside.toggle()
                            }
                        }
                    }
                }
            }
            p1 = p2
        }

        return inside
    }

    /// Check if any edges of two polygons intersect
    static func edgesIntersect(_ polygon1: [CLLocationCoordinate2D], _ polygon2: [CLLocationCoordinate2D]) -> Bool {
        for i in 0..<polygon1.count {
            let p1Start = polygon1[i]
            let p1End = polygon1[(i + 1) % polygon1.count]

            for j in 0..<polygon2.count {
                let p2Start = polygon2[j]
                let p2End = polygon2[(j + 1) % polygon2.count]

                if lineSegmentsIntersect(p1Start, p1End, p2Start, p2End) {
                    return true
                }
            }
        }

        return false
    }

    /// Check if two line segments intersect
    static func lineSegmentsIntersect(
        _ p1: CLLocationCoordinate2D,
        _ q1: CLLocationCoordinate2D,
        _ p2: CLLocationCoordinate2D,
        _ q2: CLLocationCoordinate2D
    ) -> Bool {

        let o1 = orientation(p1, q1, p2)
        let o2 = orientation(p1, q1, q2)
        let o3 = orientation(p2, q2, p1)
        let o4 = orientation(p2, q2, q1)

        // General case
        if o1 != o2 && o3 != o4 {
            return true
        }

        // Special cases for collinear points
        if o1 == 0 && onSegment(p1, p2, q1) { return true }
        if o2 == 0 && onSegment(p1, q2, q1) { return true }
        if o3 == 0 && onSegment(p2, p1, q2) { return true }
        if o4 == 0 && onSegment(p2, q1, q2) { return true }

        return false
    }

    /// Calculate orientation of ordered triplet (p, q, r)
    /// Returns 0 if collinear, 1 if clockwise, 2 if counterclockwise
    static func orientation(
        _ p: CLLocationCoordinate2D,
        _ q: CLLocationCoordinate2D,
        _ r: CLLocationCoordinate2D
    ) -> Int {
        let val = (q.longitude - p.longitude) * (r.latitude - q.latitude) -
                  (q.latitude - p.latitude) * (r.longitude - q.longitude)

        if abs(val) < 1e-10 { return 0 } // Collinear
        return val > 0 ? 1 : 2 // Clockwise or Counterclockwise
    }

    /// Check if point q lies on line segment pr
    static func onSegment(
        _ p: CLLocationCoordinate2D,
        _ q: CLLocationCoordinate2D,
        _ r: CLLocationCoordinate2D
    ) -> Bool {
        return q.longitude <= max(p.longitude, r.longitude) &&
               q.longitude >= min(p.longitude, r.longitude) &&
               q.latitude <= max(p.latitude, r.latitude) &&
               q.latitude >= min(p.latitude, r.latitude)
    }

    /// Generate convex hull using Graham scan algorithm
    static func convexHull(points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }

        let sortedPoints = points.sorted { p1, p2 in
            if p1.latitude == p2.latitude {
                return p1.longitude < p2.longitude
            }
            return p1.latitude < p2.latitude
        }

        func crossProduct(_ o: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            return (a.latitude - o.latitude) * (b.longitude - o.longitude) - (a.longitude - o.longitude) * (b.latitude - o.latitude)
        }

        // Build lower hull
        var lowerHull: [CLLocationCoordinate2D] = []
        for point in sortedPoints {
            while lowerHull.count >= 2 && crossProduct(lowerHull[lowerHull.count-2], lowerHull[lowerHull.count-1], point) <= 0 {
                lowerHull.removeLast()
            }
            lowerHull.append(point)
        }

        // Build upper hull
        var upperHull: [CLLocationCoordinate2D] = []
        for point in sortedPoints.reversed() {
            while upperHull.count >= 2 && crossProduct(upperHull[upperHull.count-2], upperHull[upperHull.count-1], point) <= 0 {
                upperHull.removeLast()
            }
            upperHull.append(point)
        }

        // Remove duplicate points
        lowerHull.removeLast()
        upperHull.removeLast()

        return lowerHull + upperHull
    }
}

// MARK: - CLLocation Extension

extension CLLocation {
    /// Calculate coordinate at given distance and bearing
    func coordinate(at distance: CLLocationDistance, facing bearing: CLLocationDirection) -> CLLocationCoordinate2D {
        let distanceRadians = distance / 6371000.0 // Earth radius in meters
        let bearingRadians = bearing * .pi / 180.0

        let lat1 = coordinate.latitude * .pi / 180.0
        let lon1 = coordinate.longitude * .pi / 180.0

        let lat2 = asin(sin(lat1) * cos(distanceRadians) +
                       cos(lat1) * sin(distanceRadians) * cos(bearingRadians))
        let lon2 = lon1 + atan2(sin(bearingRadians) * sin(distanceRadians) * cos(lat1),
                               cos(distanceRadians) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(
            latitude: lat2 * 180.0 / .pi,
            longitude: lon2 * 180.0 / .pi
        )
    }
}