//
//  ConcaveHull.swift
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
import CoreLocation
import Darwin

/// Efficient concave hull implementation using grid-based spatial indexing
/// Much faster than Delaunay triangulation for large point sets
final class ConcaveHull {

    // MARK: - Configuration

    private let maxConcaveAngleCos = Darwin.cos(90 / (180 / Double.pi))
    private let maxSearchBboxSizePercent = 0.6

    // MARK: - Public API

    /// Compute concave hull from metric Point coordinates (e.g., NZTM2000 meters)
    /// - Parameters:
    ///   - points: Input points in metric space
    ///   - concavity: Maximum edge length in same units as points (e.g., meters)
    /// - Returns: Hull vertices as Points
    func hullFromPoints(points: [Point], concavity: Double) -> [Point] {
        guard points.count >= 4 else { return points }

        let uniquePoints = filterDuplicates(points)

        // Get convex hull as starting point
        var convex = Convex(uniquePoints).convex

        // Find inner points (not on convex hull)
        let innerPoints = uniquePoints.filter { point in
            !convex.contains { $0.x == point.x && $0.y == point.y }
        }.sorted { a, b in
            a.x == b.x ? a.y > b.y : a.x > b.x
        }

        // Build spatial grid for fast neighbor lookup
        let occupiedArea = occupiedArea(uniquePoints)
        let cellSize = ceil(occupiedArea.x * occupiedArea.y / Double(uniquePoints.count))
        let grid = Grid(innerPoints, cellSize: cellSize)

        let maxSearchArea = [
            occupiedArea.x * maxSearchBboxSizePercent,
            occupiedArea.y * maxSearchBboxSizePercent
        ]

        var skipList: Set<String> = []
        let concaveResult = makeConcave(
            &convex,
            maxSqEdgeLen: pow(concavity, 2),
            maxSearchArea: maxSearchArea,
            grid: grid,
            skipList: &skipList
        )

        return concaveResult
    }

    // MARK: - Private Helpers

    private func filterDuplicates(_ points: [Point]) -> [Point] {
        let sorted = points.sorted { a, b in
            a.x == b.x ? a.y < b.y : a.x < b.x
        }

        var result: [Point] = []
        var lastPoint: Point?

        for point in sorted {
            if let last = lastPoint, last.x == point.x && last.y == point.y {
                continue
            }
            result.append(point)
            lastPoint = point
        }

        return result
    }

    private func occupiedArea(_ points: [Point]) -> Point {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return Point(x: maxX - minX, y: maxY - minY)
    }

    private func sqLength(_ a: Point, _ b: Point) -> Double {
        return pow(b.x - a.x, 2) + pow(b.y - a.y, 2)
    }

    private func cos(_ o: Point, _ a: Point, _ b: Point) -> Double {
        let aShifted = (x: a.x - o.x, y: a.y - o.y)
        let bShifted = (x: b.x - o.x, y: b.y - o.y)
        let sqALen = sqLength(o, a)
        let sqBLen = sqLength(o, b)
        // Guard against degenerate point sets where a == o or b == o
        // (zero-length vector has no defined angle — return 0 = perpendicular)
        guard sqALen > 0, sqBLen > 0 else { return 0 }
        let dot = aShifted.x * bShifted.x + aShifted.y * bShifted.y
        return dot / sqrt(sqALen * sqBLen)
    }

    private func intersects(_ seg1: [Point], _ seg2: [Point]) -> Bool {
        func ccw(_ a: Point, _ b: Point, _ c: Point) -> Bool {
            let val = ((c.y - a.y) * (b.x - a.x)) - ((b.y - a.y) * (c.x - a.x))
            return val > 0 ? true : val < 0 ? false : true
        }

        return ccw(seg1[0], seg2[0], seg2[1]) != ccw(seg1[1], seg2[0], seg2[1]) &&
               ccw(seg1[0], seg1[1], seg2[0]) != ccw(seg1[0], seg1[1], seg2[1])
    }

    private func bboxAround(_ edge: [Point]) -> [Double] {
        return [
            min(edge[0].x, edge[1].x),
            min(edge[0].y, edge[1].y),
            max(edge[0].x, edge[1].x),
            max(edge[0].y, edge[1].y)
        ]
    }

    private func midPoint(_ edge: [Point], _ innerPoints: [Point], _ convex: [Point]) -> Point? {
        var bestPoint: Point?
        var angle1Cos = maxConcaveAngleCos
        var angle2Cos = maxConcaveAngleCos

        for innerPoint in innerPoints {
            let a1Cos = cos(edge[0], edge[1], innerPoint)
            let a2Cos = cos(edge[1], edge[0], innerPoint)

            if a1Cos > angle1Cos &&
               a2Cos > angle2Cos &&
               !intersectsSegment([edge[0], innerPoint], convex) &&
               !intersectsSegment([edge[1], innerPoint], convex) {
                angle1Cos = a1Cos
                angle2Cos = a2Cos
                bestPoint = innerPoint
            }
        }

        return bestPoint
    }

    private func intersectsSegment(_ segment: [Point], _ pointSet: [Point]) -> Bool {
        for i in 0..<pointSet.count - 1 {
            let seg = [pointSet[i], pointSet[i + 1]]
            if (segment[0].x == seg[0].x && segment[0].y == seg[0].y) ||
               (segment[0].x == seg[1].x && segment[0].y == seg[1].y) {
                continue
            }
            if intersects(segment, seg) {
                return true
            }
        }
        return false
    }

    private func makeConcave(
        _ convex: inout [Point],
        maxSqEdgeLen: Double,
        maxSearchArea: [Double],
        grid: Grid,
        skipList: inout Set<String>
    ) -> [Point] {
        var midPointInserted = false

        for i in 0..<convex.count - 1 {
            let edge = [convex[i], convex[i + 1]]
            let key = "\(edge[0].x),\(edge[0].y)-\(edge[1].x),\(edge[1].y)"

            if sqLength(edge[0], edge[1]) < maxSqEdgeLen || skipList.contains(key) {
                continue
            }

            var bbox = bboxAround(edge)
            var scaleFactor: Double = 0
            var midPt: Point?

            repeat {
                bbox = grid.extendBbox(bbox, scaleFactor: scaleFactor)
                let bboxWidth = bbox[2] - bbox[0]
                let bboxHeight = bbox[3] - bbox[1]
                midPt = midPoint(edge, grid.rangePoints(bbox), convex)
                scaleFactor += 1

                if bboxWidth >= maxSearchArea[0] && bboxHeight >= maxSearchArea[1] {
                    skipList.insert(key)
                    break
                }
            } while midPt == nil && (maxSearchArea[0] > bbox[2] - bbox[0] || maxSearchArea[1] > bbox[3] - bbox[1])

            if let midPt = midPt {
                convex.insert(midPt, at: i + 1)
                grid.removePoint(midPt)
                midPointInserted = true
            }
        }

        if midPointInserted {
            return makeConcave(&convex, maxSqEdgeLen: maxSqEdgeLen, maxSearchArea: maxSearchArea, grid: grid, skipList: &skipList)
        }

        return convex
    }
}

// MARK: - Supporting Types

// Simple 2D point for hull computation
struct Point: Equatable {
    let x: Double
    let y: Double
}

private class Convex {
    var convex: [Point] = []

    init(_ pointSet: [Point]) {
        let upper = upperTangent(pointSet)
        let lower = lowerTangent(pointSet)
        convex = lower + upper
        convex.append(convex[0])
    }

    private func cross(_ o: Point, _ a: Point, _ b: Point) -> Double {
        return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    private func upperTangent(_ pointSet: [Point]) -> [Point] {
        var lower: [Point] = []
        for point in pointSet {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        lower.removeLast()
        return lower
    }

    private func lowerTangent(_ pointSet: [Point]) -> [Point] {
        var upper: [Point] = []
        for point in pointSet.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        upper.removeLast()
        return upper
    }
}

private class Grid {
    private var cells: [Int: [Int: [Point]]] = [:]
    private let cellSize: Double

    init(_ points: [Point], cellSize: Double) {
        self.cellSize = cellSize
        for point in points {
            let xy = point2CellXY(point)
            if cells[xy.x] == nil {
                cells[xy.x] = [:]
            }
            if cells[xy.x]![xy.y] == nil {
                cells[xy.x]![xy.y] = []
            }
            cells[xy.x]![xy.y]!.append(point)
        }
    }

    private func point2CellXY(_ point: Point) -> (x: Int, y: Int) {
        // Use floor() not Int() — Int truncates toward zero, so adjacent
        // negative coordinates land in the wrong grid cell (e.g. -0.5 and
        // 0.5 both → 0). NZTM eastings/northings can be negative at margins.
        return (Int(floor(point.x / cellSize)), Int(floor(point.y / cellSize)))
    }

    func extendBbox(_ bbox: [Double], scaleFactor: Double) -> [Double] {
        let offset = scaleFactor * cellSize
        return [
            bbox[0] - offset,
            bbox[1] - offset,
            bbox[2] + offset,
            bbox[3] + offset
        ]
    }

    func removePoint(_ point: Point) {
        let xy = point2CellXY(point)
        guard let cell = cells[xy.x]?[xy.y] else { return }
        if let idx = cell.firstIndex(where: { $0.x == point.x && $0.y == point.y }) {
            cells[xy.x]![xy.y]!.remove(at: idx)
        }
    }

    func rangePoints(_ bbox: [Double]) -> [Point] {
        let tlXY = point2CellXY(Point(x: bbox[0], y: bbox[1]))
        let brXY = point2CellXY(Point(x: bbox[2], y: bbox[3]))
        var points: [Point] = []

        for x in tlXY.x...brXY.x {
            for y in tlXY.y...brXY.y {
                if let cellPoints = cells[x]?[y] {
                    points += cellPoints
                }
            }
        }

        return points
    }
}
