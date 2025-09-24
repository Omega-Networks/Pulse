//
//  OutagePolygon.swift
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
import SwiftUI
import MapKit

/// Represents an outage area polygon with confidence-based styling for MapPolygon rendering
/// Implements privacy-by-design principles with minimum device thresholds
/// Enhanced with aggregated metadata from merged polygons
struct OutagePolygon: Identifiable, Hashable, Equatable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let confidence: Double
    let affectedDeviceCount: Int
    let onlineDeviceCount: Int // Total online devices in the area
    let center: CLLocationCoordinate2D
    let boundingRadius: CLLocationDistance
    let timestamp: Date
    let outageStartDate: Date
    let recentOutageDevices: Int // Devices with recent outages (not long-term offline)

    // MARK: - Enhanced Aggregation Properties

    /// Array of original polygon IDs that were merged to create this polygon
    let contributingPolygonIds: [UUID]

    /// Individual confidence ratings from each contributing polygon for drill-down
    let individualConfidences: [Double]

    /// Device counts from each contributing polygon before merging
    let individualDeviceCounts: [Int]

    /// Outage start times from each contributing polygon
    let individualOutageStartDates: [Date]

    /// Total number of unique devices across all merged polygons
    let aggregatedDeviceCount: Int

    /// Weighted confidence based on device counts from contributing polygons
    let aggregatedConfidence: Double

    /// Earliest outage start time from all contributing polygons
    let earliestOutageStartDate: Date

    /// Overlap coefficient indicating how much the polygons overlapped (0.0-1.0)
    let overlapCoefficient: Double

    init(coordinates: [CLLocationCoordinate2D], confidence: Double, affectedDeviceData: [DeviceData], allDevicesInArea: [DeviceData] = []) {
        self.coordinates = coordinates
        self.confidence = max(0.1, min(1.0, confidence)) // Clamp to 10%-100% as per design
        self.affectedDeviceCount = affectedDeviceData.count

        // Count online devices in the same area for ratio calculation
        self.onlineDeviceCount = allDevicesInArea.filter { $0.isOffline == false }.count

        self.timestamp = Date()

        // Calculate smart outage start date (removing ONT anomalies)
        let (smartStartDate, recentCount) = Self.calculateSmartOutageStart(deviceData: affectedDeviceData)
        self.outageStartDate = smartStartDate
        self.recentOutageDevices = recentCount

        // Initialize single-polygon aggregation properties (no merging yet)
        self.contributingPolygonIds = [] // Single polygon, no contributors
        self.individualConfidences = [confidence]
        self.individualDeviceCounts = [affectedDeviceData.count]
        self.individualOutageStartDates = [smartStartDate]
        self.aggregatedDeviceCount = affectedDeviceData.count
        self.aggregatedConfidence = confidence
        self.earliestOutageStartDate = smartStartDate
        self.overlapCoefficient = 0.0 // No overlap for single polygon

        // Calculate privacy-safe center point
        guard !affectedDeviceData.isEmpty else {
            self.center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
            self.boundingRadius = 0
            return
        }

        let avgLat = affectedDeviceData.map { $0.latitude }.reduce(0, +) / Double(affectedDeviceData.count)
        let avgLon = affectedDeviceData.map { $0.longitude }.reduce(0, +) / Double(affectedDeviceData.count)
        self.center = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)

        // Calculate bounding radius for viewport optimization
        let centerLocation = CLLocation(latitude: avgLat, longitude: avgLon)
        self.boundingRadius = affectedDeviceData.map { device in
            centerLocation.distance(from: device.location)
        }.max() ?? 200.0 // Default to buffer radius if no devices
    }

    // MARK: - Aggregated Polygon Initializer

    /// Initialize polygon from multiple merged polygons with aggregated metadata
    init(
        mergedCoordinates: [CLLocationCoordinate2D],
        contributingPolygons: [OutagePolygon],
        allDevicesInArea: [DeviceData],
        overlapCoefficient: Double
    ) {
        self.coordinates = mergedCoordinates
        self.timestamp = Date()

        // Aggregate metadata from contributing polygons
        self.contributingPolygonIds = contributingPolygons.map { $0.id }
        self.individualConfidences = contributingPolygons.map { $0.confidence }
        self.individualDeviceCounts = contributingPolygons.map { $0.affectedDeviceCount }
        self.individualOutageStartDates = contributingPolygons.map { $0.outageStartDate }

        // Calculate aggregated values
        self.aggregatedDeviceCount = contributingPolygons.reduce(0) { $0 + $1.affectedDeviceCount }

        // Weighted confidence based on device counts
        let totalWeight = Double(self.aggregatedDeviceCount)
        self.aggregatedConfidence = totalWeight > 0 ?
            contributingPolygons.reduce(0.0) { total, polygon in
                total + (polygon.confidence * Double(polygon.affectedDeviceCount))
            } / totalWeight : 0.0

        // Earliest outage start date
        self.earliestOutageStartDate = contributingPolygons.map { $0.outageStartDate }.min() ?? Date()

        // Use aggregated values for main properties
        self.confidence = max(0.1, min(1.0, self.aggregatedConfidence))
        self.affectedDeviceCount = self.aggregatedDeviceCount
        self.outageStartDate = self.earliestOutageStartDate
        self.overlapCoefficient = max(0.0, min(1.0, overlapCoefficient))

        // Count recent outage devices across all contributing polygons
        self.recentOutageDevices = contributingPolygons.reduce(0) { $0 + $1.recentOutageDevices }

        // Count online devices in merged area
        self.onlineDeviceCount = allDevicesInArea.filter { $0.isOffline == false }.count

        // Calculate merged polygon center
        guard !mergedCoordinates.isEmpty else {
            self.center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
            self.boundingRadius = 0
            return
        }

        let avgLat = mergedCoordinates.map { $0.latitude }.reduce(0, +) / Double(mergedCoordinates.count)
        let avgLon = mergedCoordinates.map { $0.longitude }.reduce(0, +) / Double(mergedCoordinates.count)
        self.center = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)

        // Calculate bounding radius for merged polygon
        let centerLocation = CLLocation(latitude: avgLat, longitude: avgLon)
        self.boundingRadius = mergedCoordinates.map { coordinate in
            centerLocation.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }.max() ?? 200.0
    }

    // MARK: - Design-Compliant Properties

    /// Percentage-based color: offline devices / (offline + online) devices in area
    var outagePercentage: Double {
        let totalDevices = affectedDeviceCount + onlineDeviceCount
        guard totalDevices > 0 else { return 0.0 }
        return Double(affectedDeviceCount) / Double(totalDevices)
    }

    /// Traffic light color based on outage percentage: Yellow (low%) → Orange (medium%) → Red (high%)
    var confidenceColor: Color {
        let percentage = outagePercentage

        switch percentage {
        case 0.0..<0.3:
            // Low outage rate (0-30%): Yellow to Light Orange
            let t = percentage / 0.3 // 0.0 to 1.0
            let red: Double = 1.0
            let green: Double = 1.0 - (t * 0.3) // 1.0 to 0.7 (yellow to light orange)
            let blue: Double = 0.0
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
        case 0.3..<0.6:
            // Medium outage rate (30-60%): Light Orange to Deep Orange
            let t = (percentage - 0.3) / 0.3 // 0.0 to 1.0
            let red: Double = 1.0
            let green: Double = 0.7 - (t * 0.4) // 0.7 to 0.3 (light orange to deep orange)
            let blue: Double = 0.0
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
        case 0.6..<0.8:
            // High outage rate (60-80%): Deep Orange to Red-Orange
            let t = (percentage - 0.6) / 0.2 // 0.0 to 1.0
            let red: Double = 1.0
            let green: Double = 0.3 - (t * 0.2) // 0.3 to 0.1 (deep orange to red-orange)
            let blue: Double = 0.0
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
        default:
            // Very high outage rate (80%+): Deep Red
            return Color(.sRGB, red: 1.0, green: 0.05, blue: 0.0, opacity: 1.0)
        }
    }

    /// Meets minimum confidence threshold for display (10% as per design)
    var shouldDisplay: Bool {
        confidence >= 0.10
    }

    /// Privacy compliance check (minimum 3 devices as per design)
    var isPrivacyCompliant: Bool {
        affectedDeviceCount >= 3
    }

    /// True Gaussian blur distribution for natural edge falloff
    var gaussianOpacities: [Double] {
        // Base opacity varies with outage percentage - higher percentage = more visible
        let baseOpacity = min(0.9, outagePercentage * 0.8 + 0.4)

        // True Gaussian curve: e^(-(x^2)/(2*sigma^2))
        // Using sigma = 0.3 for smooth falloff over the radius
        let sigma: Double = 0.35
        let sigmaSquared = sigma * sigma

        var opacities: [Double] = []

        // Generate 16 stops for smooth Gaussian falloff
        for i in 0..<16 {
            let normalizedRadius = Double(i) / 15.0 // 0.0 to 1.0
            let gaussianValue = exp(-(normalizedRadius * normalizedRadius) / (2.0 * sigmaSquared))
            let opacity = baseOpacity * gaussianValue
            opacities.append(max(0.0, opacity))
        }

        // Ensure final stop is completely transparent
        opacities[15] = 0.0

        return opacities
    }

    /// Simplified 4-stop gradient for MapKit compatibility (Phase 1 fix)
    var simplifiedGradientOpacities: [Double] {
        let baseOpacity = min(0.8, outagePercentage * 0.6 + 0.3)
        return [
            baseOpacity,        // Center: solid
            baseOpacity * 0.6,  // Mid: semi-transparent
            baseOpacity * 0.2,  // Edge: very transparent
            0.0                 // Border: clear
        ]
    }

    /// Legacy gradient opacities - kept for backward compatibility
    var gradientOpacities: [Double] {
        return gaussianOpacities
    }

    /// Stroke width based on confidence level
    var strokeWidth: CGFloat {
        1.0 + (confidence * 2.0) // 1-3px range based on confidence
    }

    // MARK: - Smart Outage Analysis

    /// Calculate smart outage start date, filtering out long-term anomalies
    /// Returns: (outage start date, count of recent outage devices)
    private static func calculateSmartOutageStart(deviceData: [DeviceData]) -> (Date, Int) {
        let now = Date()
        let recentThreshold: TimeInterval = 24 * 60 * 60 // 24 hours
        let anomalyThreshold: TimeInterval = 7 * 24 * 60 * 60 // 7 days

        // Get all recent power-off events (within last 24 hours)
        var recentOutageEvents: [(deviceId: String, eventDate: Date)] = []
        var longTermOfflineCount = 0

        for device in deviceData {
            // Find the most recent power-off event for this device
            let powerOffEvents = device.events.filter { event in
                event.eventDescription?.contains("Power Off") == true
            }

            let sortedEvents = powerOffEvents.sorted { event1, event2 in
                event1.timestamp > event2.timestamp
            }

            if let mostRecentEvent = sortedEvents.first {
                let eventAge = now.timeIntervalSince(mostRecentEvent.timestamp)

                if eventAge <= recentThreshold {
                    // Recent outage (within 24 hours)
                    recentOutageEvents.append((deviceId: device.deviceId, eventDate: mostRecentEvent.timestamp))
                } else if eventAge >= anomalyThreshold {
                    // Long-term anomaly (offline for 7+ days) - don't count for timing
                    longTermOfflineCount += 1
                } else {
                    // Medium-term outage (1-7 days) - include but don't weight heavily
                    recentOutageEvents.append((deviceId: device.deviceId, eventDate: mostRecentEvent.timestamp))
                }
            }
        }

        guard !recentOutageEvents.isEmpty else {
            // Fallback: use current time if no events found
            return (now, 0)
        }

        // Find the cluster of recent outages (street-level outage pattern)
        let sortedEvents = recentOutageEvents.sorted { $0.eventDate > $1.eventDate }

        // Look for the main outage cluster (most devices going offline around the same time)
        if sortedEvents.count >= 3 {
            // Find the time window with the most events (indicating street outage)
            let clusterWindow: TimeInterval = 2 * 60 * 60 // 2 hour window
            var bestClusterStart = sortedEvents[0].eventDate
            var bestClusterCount = 1

            for i in 0..<sortedEvents.count - 2 {
                let windowStart = sortedEvents[i].eventDate
                let windowEnd = windowStart.addingTimeInterval(-clusterWindow)

                let clusterCount = sortedEvents.filter { event in
                    event.eventDate >= windowEnd && event.eventDate <= windowStart
                }.count

                if clusterCount > bestClusterCount {
                    bestClusterStart = windowStart
                    bestClusterCount = clusterCount
                }
            }

            return (bestClusterStart, recentOutageEvents.count)
        } else {
            // Small outage - use most recent event
            return (sortedEvents[0].eventDate, recentOutageEvents.count)
        }
    }

    /// Human-readable outage duration
    var outageDuration: String {
        let duration = Date().timeIntervalSince(outageStartDate)
        let hours = Int(duration / 3600)
        let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    // MARK: - Aggregated Polygon Utilities

    /// Check if this polygon was created by merging multiple polygons
    var isMergedPolygon: Bool {
        return !contributingPolygonIds.isEmpty
    }

    /// Number of polygons that were merged to create this polygon
    var contributingPolygonCount: Int {
        return max(1, contributingPolygonIds.count) // At least 1 (itself)
    }

    /// Average confidence of contributing polygons
    var averageContributingConfidence: Double {
        guard !individualConfidences.isEmpty else { return confidence }
        return individualConfidences.reduce(0, +) / Double(individualConfidences.count)
    }

    /// Total duration since earliest outage in contributing polygons
    var aggregatedOutageDuration: String {
        let duration = Date().timeIntervalSince(earliestOutageStartDate)
        let hours = Int(duration / 3600)
        let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Description of merge details for debugging/logging
    var mergeDescription: String {
        if isMergedPolygon {
            return "Merged from \(contributingPolygonCount) polygons with \(aggregatedDeviceCount) total devices (overlap: \(Int(overlapCoefficient * 100))%)"
        } else {
            return "Single polygon with \(affectedDeviceCount) devices"
        }
    }

    // MARK: - Hashable & Equatable Conformance

    func hash(into hasher: inout Hasher) {
        // Use UUID for efficient hashing since it's unique per instance
        hasher.combine(id)
    }

    static func == (lhs: OutagePolygon, rhs: OutagePolygon) -> Bool {
        // UUID-based equality for performance
        lhs.id == rhs.id
    }
}

/// Lightweight device data for polygon generation (Sendable)
struct DeviceData: Sendable {
    let deviceId: String
    let latitude: Double
    let longitude: Double
    let isOffline: Bool?
    let events: [EventData]

    init(from device: PowerSenseDevice) {
        self.deviceId = device.deviceId
        self.latitude = device.latitude
        self.longitude = device.longitude
        self.isOffline = device.isOffline
        self.events = device.events.map { EventData(from: $0) }
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    func distance(to other: DeviceData) -> CLLocationDistance {
        return location.distance(from: other.location)
    }
}

/// Lightweight event data for polygon generation (Sendable)
struct EventData: Sendable {
    let eventId: String
    let timestamp: Date
    let eventDescription: String?
    let severity: Int?
    let isActive: Bool?

    init(from event: PowerSenseEvent) {
        self.eventId = event.eventId
        self.timestamp = event.timestamp
        self.eventDescription = event.eventDescription
        self.severity = event.severity
        self.isActive = event.isActive
    }
}

/// Service for generating concave hull polygons around affected PowerSense devices
actor ConcaveHullGenerator {

    /// Generate outage polygons from offline device data
    /// - Parameters:
    ///   - deviceData: Lightweight device data (Sendable)
    ///   - bufferRadius: Buffer radius around each device in meters (default: 200m)
    ///   - alpha: Concave hull alpha parameter (0.1-1.0, lower = more concave)
    /// - Returns: Array of privacy-compliant outage polygons
    func generateOutagePolygons(
        _ deviceData: [DeviceData],
        bufferRadius: CLLocationDistance = 200.0,
        alpha: Double = 0.3
    ) -> [OutagePolygon] {
        // Filter to offline devices only
        let offlineDevices = deviceData.filter { $0.isOffline == true }

        // Group offline devices by proximity using buffer zones
        let offlineGroups = groupOfflineDevices(offlineDevices, bufferRadius: bufferRadius)

        // Generate polygons for each group with device ratio calculation
        let initialPolygons: [OutagePolygon] = offlineGroups.compactMap { group in
            // Privacy control: minimum 3 devices
            guard group.count >= 3 else { return nil }

            let hull = generateConcaveHull(for: group, alpha: alpha, bufferRadius: bufferRadius)
            let confidence = calculateConfidence(group: group, allDevices: deviceData)

            // Find all devices in the same area as this group for ratio calculation
            let groupCenter = CLLocation(
                latitude: group.map { $0.latitude }.reduce(0, +) / Double(group.count),
                longitude: group.map { $0.longitude }.reduce(0, +) / Double(group.count)
            )

            let devicesInArea = deviceData.filter { device in
                return groupCenter.distance(from: device.location) <= bufferRadius * 1.8 // Slightly larger area
            }

            return OutagePolygon(
                coordinates: hull,
                confidence: confidence,
                affectedDeviceData: group,
                allDevicesInArea: devicesInArea
            )
        }

        // Filter by confidence threshold
        let validPolygons = initialPolygons.filter { $0.shouldDisplay && $0.isPrivacyCompliant }

        // Merge overlapping polygons for cleaner visualization with device ratio calculation
        return mergeOverlappingPolygons(validPolygons, bufferRadius: bufferRadius, allDeviceData: deviceData)
    }

    /// Group offline devices by proximity using optimized spatial grid
    /// Performance: O(n) instead of O(n²) using spatial grid pre-grouping
    private func groupOfflineDevices(
        _ devices: [DeviceData],
        bufferRadius: CLLocationDistance
    ) -> [[DeviceData]] {
        guard !devices.isEmpty else { return [] }

        // Pre-group devices into spatial grid cells (major performance optimization)
        let gridSize = bufferRadius // Use buffer radius as grid cell size
        let metersPerDegree = 111000.0 // Approximate meters per degree at equator
        let gridSizeInDegrees = gridSize / metersPerDegree

        let gridGroups = Dictionary(grouping: devices) { device in
            let gridX = Int(device.longitude / gridSizeInDegrees)
            let gridY = Int(device.latitude / gridSizeInDegrees)
            return "\(gridX),\(gridY)"
        }

        // Now group within and between adjacent grid cells only
        var finalGroups: [[DeviceData]] = []
        var processedGrids: Set<String> = []

        for (gridKey, gridDevices) in gridGroups {
            guard !processedGrids.contains(gridKey) else { continue }

            // Find connected devices across adjacent grid cells
            let connectedDevices = findConnectedDevicesInAdjacentCells(
                startingDevices: gridDevices,
                allGridGroups: gridGroups,
                processedGrids: &processedGrids,
                bufferRadius: bufferRadius,
                gridSizeInDegrees: gridSizeInDegrees
            )

            if connectedDevices.count >= 3 {
                finalGroups.append(connectedDevices)
            }
        }

        return finalGroups
    }

    /// Find connected devices across adjacent grid cells
    private func findConnectedDevicesInAdjacentCells(
        startingDevices: [DeviceData],
        allGridGroups: [String: [DeviceData]],
        processedGrids: inout Set<String>,
        bufferRadius: CLLocationDistance,
        gridSizeInDegrees: Double
    ) -> [DeviceData] {
        var connectedGroup = startingDevices
        var gridsToCheck = Set<String>()

        // Add starting grid and its neighbors to check list
        for device in startingDevices {
            let gridX = Int(device.longitude / gridSizeInDegrees)
            let gridY = Int(device.latitude / gridSizeInDegrees)

            // Check 3x3 grid neighborhood
            for dx in -1...1 {
                for dy in -1...1 {
                    let neighborKey = "\(gridX + dx),\(gridY + dy)"
                    gridsToCheck.insert(neighborKey)
                }
            }
        }

        // Check connections only within adjacent grid cells
        for gridKey in gridsToCheck {
            guard !processedGrids.contains(gridKey),
                  let neighborDevices = allGridGroups[gridKey] else { continue }

            // Check if any device in this grid connects to our group
            let hasConnection = neighborDevices.contains { neighborDevice in
                connectedGroup.contains { groupDevice in
                    groupDevice.distance(to: neighborDevice) <= bufferRadius
                }
            }

            if hasConnection {
                // Add all devices from this connected grid
                connectedGroup.append(contentsOf: neighborDevices)
                processedGrids.insert(gridKey)
            }
        }

        return connectedGroup
    }


    /// Generate concave hull around device group with individual device buffers
    private func generateConcaveHull(
        for devices: [DeviceData],
        alpha: Double,
        bufferRadius: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        guard devices.count >= 3 else { return [] }

        // Create buffered points around each device
        var bufferedPoints: [CLLocationCoordinate2D] = []

        for device in devices {
            let deviceLocation = device.location

            // Create circular buffer around device (4 points at 90° intervals to reduce Metal buffer usage)
            for angle in stride(from: 0.0, to: 360.0, by: 90.0) { // Reduced from 60° to 90° for fewer vertices
                let radians = angle * .pi / 180.0
                let bufferedLocation = deviceLocation.coordinate(
                    at: bufferRadius,
                    facing: CLLocationDirection(radians * 180.0 / .pi)
                )
                bufferedPoints.append(bufferedLocation)
            }
        }

        // Generate concave hull using alpha shapes algorithm
        return generateAlphaShape(points: bufferedPoints, alpha: alpha)
    }

    /// Simplified alpha shapes algorithm that avoids triangulation issues
    private func generateAlphaShape(points: [CLLocationCoordinate2D], alpha: Double) -> [CLLocationCoordinate2D] {
        guard points.count >= 3 else { return points }

        // Start with convex hull as base
        var hull = convexHull(points: points)

        // Apply refinement for more accurate emergency representation
        if points.count >= 6 {
            hull = refineConcaveHull(hull, allPoints: points, alpha: alpha, pass: 0)
        }

        // Very light simplification - only remove obviously redundant points for emergency accuracy
        hull = simplifyPolygon(hull, tolerance: 0.00005) // ~5m tolerance - much more accurate

        // Ensure minimum vertex count for valid polygon
        if hull.count < 3 {
            hull = convexHull(points: points) // Fallback to convex hull
        }

        return hull
    }

    /// Simplify polygon using Douglas-Peucker algorithm to reduce complexity
    private func simplifyPolygon(_ points: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }

        // Find the point with maximum distance from line segment
        var maxDistance = 0.0
        var maxIndex = 0
        let start = points.first!
        let end = points.last!

        for i in 1..<points.count-1 {
            let distance = perpendicularDistance(point: points[i], lineStart: start, lineEnd: end)
            if distance > maxDistance {
                maxDistance = distance
                maxIndex = i
            }
        }

        // If max distance is greater than tolerance, recursively simplify
        if maxDistance > tolerance {
            let leftPart = Array(points[0...maxIndex])
            let rightPart = Array(points[maxIndex..<points.count])

            let leftSimplified = simplifyPolygon(leftPart, tolerance: tolerance)
            let rightSimplified = simplifyPolygon(rightPart, tolerance: tolerance)

            // Combine results, avoiding duplicate middle point
            return leftSimplified + Array(rightSimplified.dropFirst())
        } else {
            // Return simplified line segment
            return [start, end]
        }
    }

    /// Calculate perpendicular distance from point to line segment
    private func perpendicularDistance(point: CLLocationCoordinate2D, lineStart: CLLocationCoordinate2D, lineEnd: CLLocationCoordinate2D) -> Double {
        let A = point.latitude - lineStart.latitude
        let B = point.longitude - lineStart.longitude
        let C = lineEnd.latitude - lineStart.latitude
        let D = lineEnd.longitude - lineStart.longitude

        let dot = A * C + B * D
        let lenSq = C * C + D * D

        if lenSq == 0 { return sqrt(A * A + B * B) } // Line is a point

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
        return sqrt(dx * dx + dy * dy)
    }

    /// Generate convex hull using Graham scan algorithm
    private func convexHull(points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
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

    /// Refine convex hull to be more concave for higher resolution
    private func refineConcaveHull(_ hull: [CLLocationCoordinate2D], allPoints: [CLLocationCoordinate2D], alpha: Double, pass: Int) -> [CLLocationCoordinate2D] {
        guard hull.count > 3 else { return hull }

        var refinedHull: [CLLocationCoordinate2D] = []
        let concavityThreshold = alpha * 200.0 // Maximum distance for concave indentations

        for i in 0..<hull.count {
            let current = hull[i]
            let next = hull[(i + 1) % hull.count]
            refinedHull.append(current)

            // Look for points between current and next that could create concave indentations
            let midpoint = CLLocationCoordinate2D(
                latitude: (current.latitude + next.latitude) / 2,
                longitude: (current.longitude + next.longitude) / 2
            )

            // Find nearby points that could add detail
            let candidatePoints = allPoints.filter { point in
                let distanceToMidpoint = CLLocation(latitude: point.latitude, longitude: point.longitude)
                    .distance(from: CLLocation(latitude: midpoint.latitude, longitude: midpoint.longitude))

                return distanceToMidpoint <= concavityThreshold &&
                       !hull.contains(where: { $0.latitude == point.latitude && $0.longitude == point.longitude })
            }

            // Add the closest candidate point for higher resolution detail
            if let closestCandidate = candidatePoints.min(by: { point1, point2 in
                let dist1 = CLLocation(latitude: point1.latitude, longitude: point1.longitude)
                    .distance(from: CLLocation(latitude: midpoint.latitude, longitude: midpoint.longitude))
                let dist2 = CLLocation(latitude: point2.latitude, longitude: point2.longitude)
                    .distance(from: CLLocation(latitude: midpoint.latitude, longitude: midpoint.longitude))
                return dist1 < dist2
            }) {
                refinedHull.append(closestCandidate)
            }
        }

        return refinedHull
    }

    /// Smooth hull shape based on alpha parameter
    private func smoothHull(_ hull: [CLLocationCoordinate2D], factor: Double) -> [CLLocationCoordinate2D] {
        guard hull.count > 4 else { return hull }

        var smoothed: [CLLocationCoordinate2D] = []
        let smoothFactor = max(0.1, factor) // Ensure some smoothing even with low alpha

        for i in 0..<hull.count {
            let current = hull[i]
            let next = hull[(i + 1) % hull.count]

            // Interpolate points for smoother curves
            let midLat = current.latitude + (next.latitude - current.latitude) * smoothFactor
            let midLon = current.longitude + (next.longitude - current.longitude) * smoothFactor

            smoothed.append(CLLocationCoordinate2D(latitude: midLat, longitude: midLon))
        }

        return smoothed
    }

    /// Calculate confidence level based on device counts and distribution in polygon
    private func calculateConfidence(group: [DeviceData], allDevices: [DeviceData]) -> Double {
        guard !group.isEmpty else { return 0.0 }

        let groupCenter = CLLocation(
            latitude: group.map { $0.latitude }.reduce(0, +) / Double(group.count),
            longitude: group.map { $0.longitude }.reduce(0, +) / Double(group.count)
        )

        // Find all devices in the polygon area (expanded slightly for context)
        let polygonRadius = calculatePolygonRadius(for: group)
        let devicesInPolygon = allDevices.filter { device in
            return groupCenter.distance(from: device.location) <= polygonRadius * 1.3
        }

        guard !devicesInPolygon.isEmpty else { return 0.5 }

        // Primary confidence factor: Device count-based outage ratio in polygon
        let offlineInPolygon = devicesInPolygon.filter { $0.isOffline == true }.count
        let onlineInPolygon = devicesInPolygon.filter { $0.isOffline == false }.count
        let totalInPolygon = offlineInPolygon + onlineInPolygon

        guard totalInPolygon > 0 else { return 0.5 }

        // Base confidence from outage percentage in polygon area
        let outageRatio = Double(offlineInPolygon) / Double(totalInPolygon)

        // Factor 1: Outage ratio (primary factor for emergency assessment)
        let ratioConfidence = outageRatio

        // Factor 2: Absolute device count (more devices = more reliable assessment)
        let deviceCountFactor = min(1.0, Double(group.count) / 15.0) // Scale up to 15 devices

        // Factor 3: Density factor (tight clusters in populated areas = higher confidence)
        let densityFactor = min(1.0, Double(totalInPolygon) / 25.0) // Scale up to 25 total devices

        // Weighted combination optimized for emergency response
        let emergencyConfidence = (ratioConfidence * 0.6) + (deviceCountFactor * 0.25) + (densityFactor * 0.15)

        return max(0.1, min(1.0, emergencyConfidence))
    }

    /// Calculate effective radius of polygon for device area assessment
    private func calculatePolygonRadius(for group: [DeviceData]) -> CLLocationDistance {
        guard group.count > 1 else { return 120.0 } // Default buffer radius

        let center = CLLocation(
            latitude: group.map { $0.latitude }.reduce(0, +) / Double(group.count),
            longitude: group.map { $0.longitude }.reduce(0, +) / Double(group.count)
        )

        let maxDistance = group.map { device in
            center.distance(from: device.location)
        }.max() ?? 120.0

        // Return radius that encompasses the group plus buffer
        return maxDistance + 120.0
    }

    /// Calculate how tightly clustered devices are (tighter = higher confidence)
    private func calculateClusteringFactor(group: [DeviceData]) -> Double {
        guard group.count > 1 else { return 0.5 }

        let distances = group.flatMap { device1 in
            group.compactMap { device2 in
                device1.deviceId != device2.deviceId ? device1.distance(to: device2) : nil
            }
        }

        guard !distances.isEmpty else { return 0.5 }

        let averageDistance = distances.reduce(0, +) / Double(distances.count)

        // Closer devices = higher confidence (inverse relationship)
        // 50m average = 1.0 confidence, 500m average = 0.1 confidence
        return max(0.1, min(1.0, 500.0 / (averageDistance + 50.0)))
    }

    /// Properly merge overlapping polygons into unified outage areas with device ratio calculation
    private func mergeOverlappingPolygons(_ polygons: [OutagePolygon], bufferRadius: CLLocationDistance, allDeviceData: [DeviceData]) -> [OutagePolygon] {
        guard polygons.count > 1 else { return polygons }

        // Build adjacency graph of overlapping polygons
        var adjacencyList: [Int: Set<Int>] = [:]
        for i in 0..<polygons.count {
            adjacencyList[i] = []
        }

        // Check for actual polygon overlaps or close proximity
        for i in 0..<polygons.count {
            for j in (i+1)..<polygons.count {
                if polygonsOverlapOrTouch(polygons[i], polygons[j], bufferRadius: bufferRadius) {
                    adjacencyList[i]!.insert(j)
                    adjacencyList[j]!.insert(i)
                }
            }
        }

        // Find connected components (groups of overlapping polygons)
        var visited: Set<Int> = []
        var connectedGroups: [[Int]] = []

        for i in 0..<polygons.count {
            guard !visited.contains(i) else { continue }

            var group: [Int] = []
            var stack: [Int] = [i]

            while !stack.isEmpty {
                let current = stack.removeLast()
                guard !visited.contains(current) else { continue }

                visited.insert(current)
                group.append(current)

                for neighbor in adjacencyList[current]! {
                    if !visited.contains(neighbor) {
                        stack.append(neighbor)
                    }
                }
            }

            connectedGroups.append(group)
        }

        // Create unified polygons for each connected group
        var mergedPolygons: [OutagePolygon] = []
        for group in connectedGroups {
            let groupPolygons = group.map { polygons[$0] }

            if group.count == 1 {
                // Single polygon - keep as is
                mergedPolygons.append(groupPolygons[0])
            } else {
                // Multiple overlapping polygons - create unified outage area with proper device counts
                if let unified = createUnifiedOutageArea(from: groupPolygons, bufferRadius: bufferRadius, allDeviceData: allDeviceData) {
                    mergedPolygons.append(unified)
                } else {
                    // Fallback: keep the largest polygon
                    let largest = groupPolygons.max { $0.affectedDeviceCount < $1.affectedDeviceCount }!
                    mergedPolygons.append(largest)
                }
            }
        }

        return mergedPolygons
    }

    /// Check if two polygons overlap or are close enough to be treated as one outage
    private func polygonsOverlapOrTouch(_ polygon1: OutagePolygon, _ polygon2: OutagePolygon, bufferRadius: CLLocationDistance) -> Bool {
        let distance = CLLocation(
            latitude: polygon1.center.latitude,
            longitude: polygon1.center.longitude
        ).distance(from: CLLocation(
            latitude: polygon2.center.latitude,
            longitude: polygon2.center.longitude
        ))

        // Consider polygons as overlapping if:
        // 1. Centers are closer than combined bounding radii
        // 2. Or centers are within buffer radius (ensures connection)
        let combinedRadius = polygon1.boundingRadius + polygon2.boundingRadius
        return distance <= max(combinedRadius * 0.8, bufferRadius * 1.2)
    }

    /// Create unified outage area that wraps around all overlapping polygons with accurate device ratios
    private func createUnifiedOutageArea(from polygons: [OutagePolygon], bufferRadius: CLLocationDistance, allDeviceData: [DeviceData]) -> OutagePolygon? {
        guard !polygons.isEmpty else { return nil }

        // Collect all points from all polygon boundaries
        var allBoundaryPoints: [CLLocationCoordinate2D] = []

        for polygon in polygons {
            allBoundaryPoints.append(contentsOf: polygon.coordinates)
        }

        // Also add expanded boundary points to ensure full coverage
        for polygon in polygons {
            let centerLocation = CLLocation(latitude: polygon.center.latitude, longitude: polygon.center.longitude)
            let expandedRadius = polygon.boundingRadius + (bufferRadius * 0.3) // Slight expansion

            // Add fewer boundary points to reduce Metal buffer usage
            for angle in stride(from: 0.0, to: 360.0, by: 60.0) { // 6 points instead of more
                let radians = angle * .pi / 180.0
                let boundPoint = centerLocation.coordinate(
                    at: expandedRadius,
                    facing: CLLocationDirection(radians * 180.0 / .pi)
                )
                allBoundaryPoints.append(boundPoint)
            }
        }

        // Create unified hull that wraps around all polygons
        var unifiedHull = convexHull(points: allBoundaryPoints)

        // Minimal simplification for emergency accuracy - only remove truly redundant points
        unifiedHull = simplifyPolygon(unifiedHull, tolerance: 0.00005) // Very light simplification (~5m)

        // Calculate polygon bounds for device counting
        let polygonBounds = calculateUnifiedPolygonBounds(from: polygons, expandedRadius: bufferRadius * 1.5)

        // Count all devices within the unified polygon area
        let devicesInArea = allDeviceData.filter { device in
            isDeviceInPolygonBounds(device: device, bounds: polygonBounds)
        }

        let offlineDevicesInArea = devicesInArea.filter { $0.isOffline == true }
        let _ = devicesInArea.filter { $0.isOffline == false } // Count calculated differently

        // Calculate weighted confidence from merged polygons
        let totalAffectedDevices = polygons.reduce(0) { $0 + $1.affectedDeviceCount }
        let weightedConfidence = polygons.reduce(0.0) { total, polygon in
            total + (polygon.confidence * Double(polygon.affectedDeviceCount))
        } / Double(max(1, totalAffectedDevices))

        return OutagePolygon(
            coordinates: unifiedHull,
            confidence: min(1.0, max(0.1, weightedConfidence)),
            affectedDeviceData: offlineDevicesInArea,
            allDevicesInArea: devicesInArea
        )
    }

    /// Calculate unified polygon bounds for device counting
    private func calculateUnifiedPolygonBounds(from polygons: [OutagePolygon], expandedRadius: CLLocationDistance) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        guard !polygons.isEmpty else { return (0, 0, 0, 0) }

        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude

        // Expand bounds to include buffer areas around each polygon center
        for polygon in polygons {
            let expandedBounds = expandBounds(
                center: polygon.center,
                radius: polygon.boundingRadius + expandedRadius
            )

            minLat = min(minLat, expandedBounds.minLat)
            maxLat = max(maxLat, expandedBounds.maxLat)
            minLon = min(minLon, expandedBounds.minLon)
            maxLon = max(maxLon, expandedBounds.maxLon)
        }

        return (minLat, maxLat, minLon, maxLon)
    }

    /// Expand bounds around a center point by radius
    private func expandBounds(center: CLLocationCoordinate2D, radius: CLLocationDistance) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        let metersPerDegree = 111000.0 // Approximate
        let deltaLat = radius / metersPerDegree
        let deltaLon = radius / (metersPerDegree * cos(center.latitude * .pi / 180.0))

        return (
            minLat: center.latitude - deltaLat,
            maxLat: center.latitude + deltaLat,
            minLon: center.longitude - deltaLon,
            maxLon: center.longitude + deltaLon
        )
    }

    /// Check if device is within polygon bounds (approximation for performance)
    private func isDeviceInPolygonBounds(device: DeviceData, bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)) -> Bool {
        return device.latitude >= bounds.minLat &&
               device.latitude <= bounds.maxLat &&
               device.longitude >= bounds.minLon &&
               device.longitude <= bounds.maxLon
    }
}

// MARK: - CLLocation Extensions

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
