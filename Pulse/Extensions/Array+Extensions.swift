//
//  Array.swift
//  Pulse
//
//  Created by Alessio Prescenzo on 18/11/25.
//

import Foundation

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - PowerSense

extension Array where Element: SpatialDevice {
    /// Filter devices that are offline
    public var offlineDevices: [Element] {
        return filter { $0.isOffline == true }
    }

    /// Filter devices with valid coordinates
    public var validCoordinateDevices: [Element] {
        return filter { device in
            device.latitude >= -90 && device.latitude <= 90 &&
            device.longitude >= -180 && device.longitude <= 180 &&
            device.latitude != 0.0 && device.longitude != 0.0
        }
    }

    /// Get geographic bounds of all devices
    public var geographicBounds: GeographicBounds? {
        guard !isEmpty else { return nil }

        let lats = map { $0.latitude }
        let lons = map { $0.longitude }

        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else {
            return nil
        }

        return GeographicBounds(
            minLatitude: minLat,
            maxLatitude: maxLat,
            minLongitude: minLon,
            maxLongitude: maxLon
        )
    }
}

// MARK: - Array Extensions
extension Array where Element == TimeInterval {
    var average: TimeInterval? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}

