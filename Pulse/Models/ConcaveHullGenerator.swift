//
//  ConcaveHullGenerator.swift
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

/// DeviceData struct for transferring PowerSenseDevice data to polygon generation
struct DeviceData: Sendable {
    let deviceId: String
    let latitude: Double
    let longitude: Double
    let isOffline: Bool
    let timestamp: Date

    init(from device: PowerSenseDevice) {
        self.deviceId = device.deviceId
        self.latitude = device.latitude
        self.longitude = device.longitude
        self.isOffline = device.isOffline ?? false
        self.timestamp = device.lastStatusChange ?? Date()
    }
}

/// Enhanced concave hull generator with geometric polygon intersection detection
/// Integrates with PolygonGroupingService for optimal performance
final class ConcaveHullGenerator {

    /// Generate outage polygons with optimized geometric merging
    func generateOutagePolygons(
        _ devices: [DeviceData],
        bufferRadius: CLLocationDistance,
        alpha: Double
    ) async -> [OutagePolygon] {

        // Create enhanced PolygonGroupingService instance for better performance and accuracy
        let polygonGroupingService = PolygonGroupingService()
        return await polygonGroupingService.generateOptimizedPolygons(
            devices,
            bufferRadius: bufferRadius,
            alpha: alpha
        )
    }

    // MARK: - Legacy Support Methods (maintained for backward compatibility)

    /// Legacy polygon generation (kept for fallback scenarios)
    private func generateLegacyPolygons(
        _ devices: [DeviceData],
        bufferRadius: CLLocationDistance
    ) -> [OutagePolygon] {
        // Filter to offline devices only
        let offlineDevices = devices.filter { $0.isOffline }

        guard offlineDevices.count >= 3 else {
            return [] // Privacy compliance: minimum 3 devices
        }

        // Simple clustering based on proximity (legacy approach)
        let clusters = clusterDevices(offlineDevices, maxDistance: bufferRadius * 2)

        var polygons: [OutagePolygon] = []

        for cluster in clusters {
            guard cluster.count >= 3 else { continue } // Privacy compliance

            if let polygon = generatePolygonFromCluster(cluster, bufferRadius: bufferRadius) {
                polygons.append(polygon)
            }
        }

        return polygons
    }

    // MARK: - Private Methods

    /// Simple proximity-based clustering
    private func clusterDevices(_ devices: [DeviceData], maxDistance: CLLocationDistance) -> [[DeviceData]] {
        var clusters: [[DeviceData]] = []
        var processed: Set<String> = []

        for device in devices {
            guard !processed.contains(device.deviceId) else { continue }

            var cluster = [device]
            processed.insert(device.deviceId)

            // Find nearby devices
            for other in devices {
                guard !processed.contains(other.deviceId) else { continue }

                let distance = CLLocation(latitude: device.latitude, longitude: device.longitude)
                    .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))

                if distance <= maxDistance {
                    cluster.append(other)
                    processed.insert(other.deviceId)
                }
            }

            if cluster.count >= 3 { // Privacy compliance
                clusters.append(cluster)
            }
        }

        return clusters
    }

    /// Generate polygon from device cluster with Phase 1 hexagonal buffering (6 points, 60° intervals)
    private func generatePolygonFromCluster(_ devices: [DeviceData], bufferRadius: CLLocationDistance) -> OutagePolygon? {
        guard devices.count >= 3 else { return nil }

        // Calculate cluster center
        let centerLat = devices.reduce(0.0) { $0 + $1.latitude } / Double(devices.count)
        let centerLon = devices.reduce(0.0) { $0 + $1.longitude } / Double(devices.count)
        let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)

        // Generate hexagonal buffer around center (Phase 1 fix: 6 points at 60° intervals)
        var coordinates: [CLLocationCoordinate2D] = []

        for angle in stride(from: 0.0, to: 360.0, by: 60.0) { // 6 points for hexagonal shape
            let radians = angle * .pi / 180.0
            let deltaLat = (bufferRadius / 111000.0) * cos(radians) // ~111km per degree lat
            let deltaLon = (bufferRadius / (111000.0 * cos(center.latitude * .pi / 180.0))) * sin(radians)

            coordinates.append(CLLocationCoordinate2D(
                latitude: center.latitude + deltaLat,
                longitude: center.longitude + deltaLon
            ))
        }

        // Close the polygon
        coordinates.append(coordinates[0])

        // Calculate confidence based on device density
        let confidence = min(1.0, Double(devices.count) / 10.0) // Max confidence at 10+ devices

        // Create polygon
        return OutagePolygon(
            coordinates: coordinates,
            confidence: confidence,
            affectedDeviceData: devices,
            allDevicesInArea: devices
        )
    }
}