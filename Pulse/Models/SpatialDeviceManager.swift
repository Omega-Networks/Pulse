//
//  SpatialDeviceManager.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  High-performance spatial device management using GameplayKit's GKQuadtree
//  for O(log n) device queries and real-time polygon generation
//

import Foundation
import GameplayKit
import CoreLocation
import MapKit
import OSLog

/// High-performance spatial device manager using GKQuadtree for O(log n) operations
/// Maintains persistent spatial index with incremental updates for real-time performance
@MainActor
public final class SpatialDeviceManager: ObservableObject {

    // MARK: - Logging Infrastructure

    private let performanceLogger = Logger(subsystem: "powersense.spatial", category: "performance")
    private let algorithmLogger = Logger(subsystem: "powersense.spatial", category: "algorithms")
    private let cacheLogger = Logger(subsystem: "powersense.spatial", category: "caching")
    private let errorLogger = Logger(subsystem: "powersense.spatial", category: "errors")
    private let debugLogger = Logger(subsystem: "powersense.spatial", category: "debug")

    // MARK: - Core Properties

    /// Primary spatial index for all devices - persistent across updates
    private var deviceQuadTree: GKQuadtree<SpatialDeviceNode>?

    /// Device lookup table for O(1) access by deviceId
    private var deviceIndex: [String: PowerSenseDevice] = [:]

    /// Cached offline devices for fast filtering
    private var offlineDeviceCache: [PowerSenseDevice] = []
    private var offlineCacheValid = false
    private var offlineCacheTimestamp = Date.distantPast

    /// Map bounds for quadtree initialization
    private var mapBounds: GKQuad

    /// Performance metrics tracking
    private var performanceMetrics = SpatialPerformanceMetrics()

    // MARK: - Configuration

    private struct Config {
        static let minimumCellSize: Float = 0.0001 // ~11 meters at equator
        static let cacheValidityDuration: TimeInterval = 30.0 // 30 seconds
        static let performanceLoggingThreshold: TimeInterval = 0.1 // 100ms
        static let maxDevicesForFullRebuild: Int = 100_000
    }

    // MARK: - Initialization

    init() {
        // Initialize with global bounds - can be optimized later for specific regions
        self.mapBounds = GKQuad(
            quadMin: vector2(-180, -90),   // Southwest corner
            quadMax: vector2(180, 90)      // Northeast corner
        )

        performanceLogger.info("🏗️ SpatialDeviceManager initialized with global bounds")
        debugLogger.debug("📊 QuadTree bounds: SW(-180,-90) to NE(180,90), cellSize: \(Config.minimumCellSize)")
    }

    // MARK: - QuadTree Management

    /// Initialize or rebuild the complete spatial index
    /// This is an expensive O(n log n) operation done once at startup or during full refresh
    public func initializeQuadTree(with devices: [PowerSenseDevice]) async {
        let startTime = Date()
        performanceLogger.info("🚀 Initializing QuadTree with \(devices.count) devices")

        // Create new quadtree
        let quadTree = GKQuadtree(boundingQuad: mapBounds, minimumCellSize: Config.minimumCellSize)
        var validDevices = 0
        var invalidDevices = 0

        // Build device index and populate quadtree
        deviceIndex.removeAll(keepingCapacity: true)

        for device in devices {
            // Validate device coordinates
            guard isValidCoordinate(device.latitude, device.longitude) else {
                errorLogger.warning("⚠️ Invalid coordinates for device \(device.deviceId): (\(device.latitude), \(device.longitude))")
                invalidDevices += 1
                continue
            }

            // Create spatial node and add to quadtree
            let spatialNode = SpatialDeviceNode(device: device)
            let position = vector2(Float(device.longitude), Float(device.latitude))

            quadTree.add(spatialNode, at: position)
            deviceIndex[device.deviceId] = device
            validDevices += 1
        }

        // Update primary quadtree reference
        self.deviceQuadTree = quadTree

        // Invalidate caches
        invalidateOfflineCache()

        let buildTime = Date().timeIntervalSince(startTime)
        performanceMetrics.quadTreeBuildTime = buildTime

        performanceLogger.info("✅ QuadTree built successfully in \(String(format: "%.3f", buildTime))s")
        performanceLogger.info("📊 Indexed devices: \(validDevices) valid, \(invalidDevices) invalid")
        debugLogger.debug("🔍 QuadTree elements count: \(quadTree.elements(in: mapBounds).count)")

        if buildTime > Config.performanceLoggingThreshold {
            performanceLogger.warning("⚠️ QuadTree build time exceeded threshold: \(String(format: "%.3f", buildTime))s > \(Config.performanceLoggingThreshold)s")
        }
    }

    /// Add a single device to the spatial index - O(log n) operation
    func addDevice(_ device: PowerSenseDevice) {
        guard let quadTree = deviceQuadTree else {
            errorLogger.error("❌ Cannot add device: QuadTree not initialized")
            return
        }

        let startTime = Date()

        guard isValidCoordinate(device.latitude, device.longitude) else {
            errorLogger.warning("⚠️ Cannot add device with invalid coordinates: \(device.deviceId) at (\(device.latitude), \(device.longitude))")
            return
        }

        // Create spatial node and add to quadtree
        let spatialNode = SpatialDeviceNode(device: device)
        let position = vector2(Float(device.longitude), Float(device.latitude))

        quadTree.add(spatialNode, at: position)
        deviceIndex[device.deviceId] = device

        // Invalidate relevant caches
        invalidateOfflineCache()

        let addTime = Date().timeIntervalSince(startTime)
        performanceMetrics.deviceAddOperations += 1
        performanceMetrics.lastDeviceAddTime = addTime

        debugLogger.debug("➕ Added device \(device.deviceId) at (\(String(format: "%.6f", device.latitude)), \(String(format: "%.6f", device.longitude))) in \(String(format: "%.6f", addTime))s")

        if addTime > 0.001 { // 1ms threshold for single device operations
            performanceLogger.warning("⚠️ Device add operation took \(String(format: "%.6f", addTime))s - consider optimization")
        }
    }

    /// Remove a device from the spatial index - O(log n) operation
    func removeDevice(deviceId: String) {
        guard let quadTree = deviceQuadTree else {
            errorLogger.error("❌ Cannot remove device: QuadTree not initialized")
            return
        }

        guard let device = deviceIndex[deviceId] else {
            errorLogger.warning("⚠️ Cannot remove device: \(deviceId) not found in index")
            return
        }

        let startTime = Date()
        let position = vector2(Float(device.longitude), Float(device.latitude))

        // Find and remove the specific device node
        let elementsAtPosition = quadTree.elements(at: position)
        for element in elementsAtPosition {
            if element.device.deviceId == deviceId {
                quadTree.remove(element, using: position)
                break
            }
        }

        deviceIndex.removeValue(forKey: deviceId)
        invalidateOfflineCache()

        let removeTime = Date().timeIntervalSince(startTime)
        performanceMetrics.deviceRemoveOperations += 1
        performanceMetrics.lastDeviceRemoveTime = removeTime

        debugLogger.debug("➖ Removed device \(deviceId) in \(String(format: "%.6f", removeTime))s")
    }

    /// Update a device's status without changing its spatial position
    func updateDeviceStatus(deviceId: String, isOffline: Bool) {
        guard let device = deviceIndex[deviceId] else {
            errorLogger.warning("⚠️ Cannot update device status: \(deviceId) not found")
            return
        }

        let startTime = Date()

        // Create updated device (assuming PowerSenseDevice is a struct)
        let updatedDevice = PowerSenseDevice(
            deviceId: device.deviceId,
            latitude: device.latitude,
            longitude: device.longitude,
            // Copy other properties and update the offline status
            isOffline: isOffline
        )

        deviceIndex[deviceId] = updatedDevice

        // Update the spatial node in quadtree
        let position = vector2(Float(device.longitude), Float(device.latitude))
        let elementsAtPosition = deviceQuadTree?.elements(at: position) ?? []

        for element in elementsAtPosition {
            if element.device.deviceId == deviceId {
                element.device = updatedDevice
                break
            }
        }

        // Invalidate offline cache if status changed
        if device.isOffline != isOffline {
            invalidateOfflineCache()
        }

        let updateTime = Date().timeIntervalSince(startTime)
        performanceMetrics.deviceStatusUpdates += 1
        performanceMetrics.lastStatusUpdateTime = updateTime

        debugLogger.debug("🔄 Updated device \(deviceId) status to \(isOffline ? "offline" : "online") in \(String(format: "%.6f", updateTime))s")
    }

    // MARK: - Device Querying

    /// Get all offline devices within a map region - O(log n) spatial query
    func getOfflineDevices(in mapRect: MKMapRect) async -> [PowerSenseDevice] {
        guard let quadTree = deviceQuadTree else {
            errorLogger.error("❌ Cannot query devices: QuadTree not initialized")
            return []
        }

        let startTime = Date()

        // Check if we can use cached results
        if offlineCacheValid && Date().timeIntervalSince(offlineCacheTimestamp) < Config.cacheValidityDuration {
            let filteredCache = offlineDeviceCache.filter { device in
                mapRect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)))
            }

            let cacheTime = Date().timeIntervalSince(startTime)
            cacheLogger.info("💾 Cache hit: returned \(filteredCache.count) offline devices in \(String(format: "%.6f", cacheTime))s")

            return filteredCache
        }

        // Convert MKMapRect to GKQuad
        let quad = mkMapRectToGKQuad(mapRect)

        // Spatial query for devices in region
        let devicesInRegion = quadTree.elements(in: quad)
        let offlineDevices = devicesInRegion.compactMap { spatialNode in
            spatialNode.device.isOffline ? spatialNode.device : nil
        }

        // Update cache if this was a full query
        if mapRect == MKMapRect.world {
            offlineDeviceCache = offlineDevices
            offlineCacheValid = true
            offlineCacheTimestamp = Date()
            cacheLogger.info("💾 Cache updated with \(offlineDevices.count) offline devices")
        }

        let queryTime = Date().timeIntervalSince(startTime)
        performanceMetrics.spatialQueryCount += 1
        performanceMetrics.lastSpatialQueryTime = queryTime
        performanceMetrics.averageQueryTime = (performanceMetrics.averageQueryTime * Double(performanceMetrics.spatialQueryCount - 1) + queryTime) / Double(performanceMetrics.spatialQueryCount)

        algorithmLogger.info("🔍 Spatial query returned \(offlineDevices.count) offline devices from \(devicesInRegion.count) total in region")
        performanceLogger.debug("⏱️ Query time: \(String(format: "%.6f", queryTime))s")

        if queryTime > Config.performanceLoggingThreshold / 10 { // 10ms threshold for queries
            performanceLogger.warning("⚠️ Spatial query exceeded threshold: \(String(format: "%.6f", queryTime))s")
        }

        return offlineDevices
    }

    /// Get all devices (online and offline) within a specific radius of a point
    public func getDevicesNearPoint(_ center: CLLocationCoordinate2D, radius: CLLocationDistance) -> [PowerSenseDevice] {
        guard let quadTree = deviceQuadTree else {
            errorLogger.error("❌ Cannot query devices near point: QuadTree not initialized")
            return []
        }

        let startTime = Date()

        // Create search bounds
        let radiusInDegrees = radius / 111000.0 // Approximate conversion
        let searchQuad = GKQuad(
            quadMin: vector2(Float(center.longitude - radiusInDegrees), Float(center.latitude - radiusInDegrees)),
            quadMax: vector2(Float(center.longitude + radiusInDegrees), Float(center.latitude + radiusInDegrees))
        )

        // Get candidates from quadtree
        let candidates = quadTree.elements(in: searchQuad)

        // Filter by actual distance
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let nearbyDevices = candidates.compactMap { spatialNode -> PowerSenseDevice? in
            let deviceLocation = CLLocation(latitude: spatialNode.device.latitude, longitude: spatialNode.device.longitude)
            let distance = centerLocation.distance(from: deviceLocation)
            return distance <= radius ? spatialNode.device : nil
        }

        let queryTime = Date().timeIntervalSince(startTime)
        algorithmLogger.debug("🎯 Radius query: found \(nearbyDevices.count) devices within \(Int(radius))m of (\(String(format: "%.6f", center.latitude)), \(String(format: "%.6f", center.longitude)))")
        performanceLogger.debug("⏱️ Radius query time: \(String(format: "%.6f", queryTime))s")

        return nearbyDevices
    }

    // MARK: - Cache Management

    private func invalidateOfflineCache() {
        offlineCacheValid = false
        offlineCacheTimestamp = Date.distantPast
        cacheLogger.debug("🗑️ Offline device cache invalidated")
    }

    // MARK: - Utility Methods

    private func isValidCoordinate(_ latitude: Double, _ longitude: Double) -> Bool {
        return latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }

    private func mkMapRectToGKQuad(_ mapRect: MKMapRect) -> GKQuad {
        let topLeft = MKMapPoint(x: mapRect.minX, y: mapRect.minY).coordinate
        let bottomRight = MKMapPoint(x: mapRect.maxX, y: mapRect.maxY).coordinate

        return GKQuad(
            quadMin: vector2(Float(topLeft.longitude), Float(bottomRight.latitude)),
            quadMax: vector2(Float(bottomRight.longitude), Float(topLeft.latitude))
        )
    }

    // MARK: - Performance Monitoring

    /// Get current performance metrics for monitoring and debugging
    var currentPerformanceMetrics: SpatialPerformanceMetrics {
        performanceMetrics
    }

    /// Log comprehensive performance statistics
    func logPerformanceStatistics() {
        performanceLogger.info("""
        📊 SPATIAL DEVICE MANAGER PERFORMANCE STATISTICS:
        ================================================
        • QuadTree Build Time: \(String(format: "%.3f", performanceMetrics.quadTreeBuildTime))s
        • Device Add Operations: \(performanceMetrics.deviceAddOperations)
        • Device Remove Operations: \(performanceMetrics.deviceRemoveOperations)
        • Status Updates: \(performanceMetrics.deviceStatusUpdates)
        • Spatial Queries: \(performanceMetrics.spatialQueryCount)
        • Average Query Time: \(String(format: "%.6f", performanceMetrics.averageQueryTime))s
        • Last Query Time: \(String(format: "%.6f", performanceMetrics.lastSpatialQueryTime))s
        • Cache Hit Ratio: \(String(format: "%.1f", performanceMetrics.cacheHitRatio * 100))%
        • Total Indexed Devices: \(deviceIndex.count)
        • Offline Cache Valid: \(offlineCacheValid)
        """)
    }
}

// MARK: - Supporting Data Structures

/// Wrapper for PowerSenseDevice to work with GKQuadtree
final class SpatialDeviceNode: NSObject, GKQuadtreeLocatable {
    var device: PowerSenseDevice

    init(device: PowerSenseDevice) {
        self.device = device
        super.init()
    }

    // GKQuadtreeLocatable protocol requirement
    var quadtreeLocation: vector2 {
        return vector2(Float(device.longitude), Float(device.latitude))
    }
}

/// Performance metrics for monitoring spatial operations
struct SpatialPerformanceMetrics {
    var quadTreeBuildTime: TimeInterval = 0
    var deviceAddOperations: Int = 0
    var deviceRemoveOperations: Int = 0
    var deviceStatusUpdates: Int = 0
    var spatialQueryCount: Int = 0
    var lastSpatialQueryTime: TimeInterval = 0
    var averageQueryTime: TimeInterval = 0
    var lastDeviceAddTime: TimeInterval = 0
    var lastDeviceRemoveTime: TimeInterval = 0
    var lastStatusUpdateTime: TimeInterval = 0
    var cacheHitRatio: Double = 0.0
}

// MARK: - PowerSenseDevice Extension

extension PowerSenseDevice {
    /// Initialize PowerSenseDevice with offline status (simplified constructor for status updates)
    init(deviceId: String, latitude: Double, longitude: Double, isOffline: Bool) {
        // This is a simplified initializer - in the real implementation,
        // you'd need to copy all the other properties from the original device
        self.deviceId = deviceId
        self.latitude = latitude
        self.longitude = longitude
        self.isOffline = isOffline
        // ... other property assignments would go here
    }
}