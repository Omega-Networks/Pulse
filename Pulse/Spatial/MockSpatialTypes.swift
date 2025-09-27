//
//  MockSpatialTypes.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Mock types for spatial clustering testing and development.
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

// MARK: - Mock Spatial Device

/// Mock spatial device for testing GPU spatial clustering
struct MockSpatialDevice: SpatialDevice, Sendable {
    let deviceId: String
    let latitude: Double
    let longitude: Double
    let isOffline: Bool?

    init(deviceId: String, latitude: Double, longitude: Double, isOffline: Bool? = nil) {
        self.deviceId = deviceId
        self.latitude = latitude
        self.longitude = longitude
        self.isOffline = isOffline
    }
}

// MARK: - Geographic Helper Types (using existing GeographicBounds)

/// Represents an outage area for mock data generation
struct OutageArea: Sendable {
    let center: CLLocationCoordinate2D
    let radius: Double // meters
    let deviceCount: Int
    let outageRate: Double

    init(center: CLLocationCoordinate2D, radius: Double, deviceCount: Int, outageRate: Double) {
        self.center = center
        self.radius = radius
        self.deviceCount = deviceCount
        self.outageRate = outageRate
    }

    /// Wellington CBD outage area
    static let wellingtonCBD = OutageArea(
        center: CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762),
        radius: 800.0, deviceCount: 25, outageRate: 0.8
    )

    /// Lower Hutt outage area
    static let lowerHutt = OutageArea(
        center: CLLocationCoordinate2D(latitude: -41.2093, longitude: 174.9076),
        radius: 1200.0, deviceCount: 35, outageRate: 0.7
    )

    /// Upper Hutt outage area
    static let upperHutt = OutageArea(
        center: CLLocationCoordinate2D(latitude: -41.1244, longitude: 175.0714),
        radius: 600.0, deviceCount: 15, outageRate: 0.9
    )

    /// Kapiti Coast outage area
    static let kapitiCoast = OutageArea(
        center: CLLocationCoordinate2D(latitude: -40.9006, longitude: 175.0114),
        radius: 1500.0, deviceCount: 20, outageRate: 0.6
    )

    /// Standard Wellington region outage areas
    static let wellingtonAreas = [wellingtonCBD, lowerHutt, upperHutt, kapitiCoast]
}

// MARK: - Mock Data Generation Utilities

/// Utility functions for generating mock spatial data
enum MockSpatialDataGenerator {

    /// Generate a random coordinate within a circle
    static func generateRandomCoordinateInCircle(center: CLLocationCoordinate2D, radiusMeters: Double) -> CLLocationCoordinate2D {
        let radiusDegrees = radiusMeters / 111000.0
        let angle = Double.random(in: 0...(2 * Double.pi))
        let distance = Double.random(in: 0...radiusDegrees) * sqrt(Double.random(in: 0...1))

        let lat = center.latitude + distance * cos(angle)
        let lon = center.longitude + distance * sin(angle)

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Generate clustered mock devices within specified areas
    static func generateClusteredDevices(
        areas: [OutageArea],
        totalDeviceCount: Int,
        backgroundBounds: GeographicBounds,
        backgroundOutageRate: Double = 0.05
    ) -> [MockSpatialDevice] {
        var devices: [MockSpatialDevice] = []
        var deviceIndex = 0

        // Generate devices in clusters
        for (areaIndex, area) in areas.enumerated() {
            let areaDeviceCount = min(area.deviceCount, totalDeviceCount - deviceIndex)

            for _ in 0..<areaDeviceCount {
                guard deviceIndex < totalDeviceCount else { break }

                let deviceCoord = generateRandomCoordinateInCircle(
                    center: area.center,
                    radiusMeters: area.radius
                )

                let isOffline = Double.random(in: 0...1) < area.outageRate
                let device = MockSpatialDevice(
                    deviceId: "CLUSTER_\(areaIndex)_\(deviceIndex)",
                    latitude: deviceCoord.latitude,
                    longitude: deviceCoord.longitude,
                    isOffline: isOffline
                )
                devices.append(device)
                deviceIndex += 1
            }
        }

        // Fill remaining with background devices
        while deviceIndex < totalDeviceCount {
            let randomLat = Double.random(in: backgroundBounds.minLatitude...backgroundBounds.maxLatitude)
            let randomLon = Double.random(in: backgroundBounds.minLongitude...backgroundBounds.maxLongitude)
            let isOffline = Double.random(in: 0...1) < backgroundOutageRate

            let device = MockSpatialDevice(
                deviceId: "BG_\(deviceIndex)",
                latitude: randomLat,
                longitude: randomLon,
                isOffline: isOffline
            )
            devices.append(device)
            deviceIndex += 1
        }

        return devices
    }
}

// MARK: - Geographic Bounds Extensions

extension GeographicBounds {
    /// Wellington, New Zealand bounds
    static let wellington = GeographicBounds(
        minLatitude: -41.5, maxLatitude: -41.0,
        minLongitude: 174.5, maxLongitude: 175.2
    )
}