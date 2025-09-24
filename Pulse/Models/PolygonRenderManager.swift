//
//  PolygonRenderManager.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  High-performance polygon rendering system for MapKit integration
//  Manages outage polygon visualization with confidence-based styling and performance optimization
//

import Foundation
import MapKit
import SwiftUI
import OSLog
import GameplayKit

/// High-performance polygon rendering manager for MapKit integration
/// Manages outage polygon visualization with adaptive LOD and performance monitoring
@MainActor
public final class PolygonRenderManager: ObservableObject {

    // MARK: - Logging Infrastructure

    private let renderLogger = Logger(subsystem: "powersense.render", category: "polygons")
    private let performanceLogger = Logger(subsystem: "powersense.render", category: "performance")
    private let memoryLogger = Logger(subsystem: "powersense.render", category: "memory")
    private let debugLogger = Logger(subsystem: "powersense.render", category: "debug")

    // MARK: - Published State

    /// Currently rendered polygon overlays
    @Published private(set) var polygonOverlays: [OutagePolygonOverlay] = []

    /// Performance metrics for monitoring
    @Published private(set) var renderMetrics = RenderPerformanceMetrics()

    /// Current rendering configuration
    @Published var renderConfig = RenderConfig.default

    // MARK: - Internal State

    /// Polygon cache for efficient updates
    private var polygonCache: [UUID: OutagePolygonOverlay] = [:]

    /// Viewport tracking for LOD optimization
    private var currentViewport: MKMapRect = MKMapRect.world
    private var currentZoomLevel: Int = 0

    /// Performance monitoring
    private var frameTimer: Timer?
    private var lastFrameTime = Date()

    // MARK: - Configuration

    struct RenderConfig {
        /// Maximum number of polygons to render simultaneously
        let maxPolygons: Int

        /// Minimum zoom level for detail rendering
        let detailZoomThreshold: Int

        /// Performance target for frame time
        let targetFrameTime: TimeInterval

        /// Enable adaptive level of detail
        let enableAdaptiveLOD: Bool

        /// Memory usage threshold for optimization
        let memoryThresholdMB: Int

        static let `default` = RenderConfig(
            maxPolygons: 100,
            detailZoomThreshold: 14,
            targetFrameTime: 0.016,  // 60 FPS target
            enableAdaptiveLOD: true,
            memoryThresholdMB: 50
        )
    }

    // MARK: - Performance Metrics

    struct RenderPerformanceMetrics {
        var totalPolygonsRendered: Int = 0
        var visiblePolygonsCount: Int = 0
        var averageFrameTime: TimeInterval = 0
        var memoryUsageMB: Double = 0
        var culllingEfficiency: Double = 0
        var lastRenderTime: TimeInterval = 0
        var polygonComplexityScore: Double = 0
    }

    // MARK: - Initialization

    init() {
        setupPerformanceMonitoring()
        renderLogger.info("🎨 PolygonRenderManager initialized")
    }

    deinit {
        frameTimer?.invalidate()
    }

    // MARK: - Main Rendering Interface

    /// Update polygon overlays from outage data with performance optimization
    public func updatePolygons(
        from outagePolygons: [OutagePolygon],
        viewport: MKMapRect,
        zoomLevel: Int
    ) async {

        let startTime = Date()
        renderLogger.info("🔄 Updating \(outagePolygons.count) polygons for viewport")

        currentViewport = viewport
        currentZoomLevel = zoomLevel

        // Performance culling - only render visible polygons
        let visiblePolygons = await cullInvisiblePolygons(
            outagePolygons,
            viewport: viewport,
            zoomLevel: zoomLevel
        )

        // Apply adaptive level of detail
        let optimizedPolygons = await applyAdaptiveLOD(
            visiblePolygons,
            zoomLevel: zoomLevel
        )

        // Create or update polygon overlays
        await createPolygonOverlays(from: optimizedPolygons)

        // Update performance metrics
        let renderTime = Date().timeIntervalSince(startTime)
        await updatePerformanceMetrics(
            totalPolygons: outagePolygons.count,
            visiblePolygons: visiblePolygons.count,
            renderTime: renderTime
        )

        renderLogger.info("✅ Polygon update completed: \(polygonOverlays.count) overlays rendered in \(String(format: "%.3f", renderTime))s")
    }

    /// Force refresh all polygon overlays with new styling
    func refreshPolygons() async {
        let startTime = Date()

        for overlay in polygonOverlays {
            await refreshOverlayAppearance(overlay)
        }

        let refreshTime = Date().timeIntervalSince(startTime)
        performanceLogger.debug("🔄 Refreshed \(polygonOverlays.count) overlays in \(String(format: "%.6f", refreshTime))s")
    }

    /// Clear all polygon overlays
    public func clearPolygons() {
        polygonOverlays.removeAll()
        polygonCache.removeAll()
        renderLogger.info("🗑️ All polygon overlays cleared")
    }

    // MARK: - Performance Culling

    /// Remove polygons outside viewport for better performance
    private func cullInvisiblePolygons(
        _ polygons: [OutagePolygon],
        viewport: MKMapRect,
        zoomLevel: Int
    ) async -> [OutagePolygon] {

        let expandedViewport = viewport.insetBy(
            dx: -viewport.size.width * 0.2,
            dy: -viewport.size.height * 0.2
        )

        let culledPolygons = polygons.filter { polygon in
            let polygonPoint = MKMapPoint(polygon.center)
            let polygonRect = MKMapRect(
                x: polygonPoint.x - polygon.boundingRadius,
                y: polygonPoint.y - polygon.boundingRadius,
                width: polygon.boundingRadius * 2,
                height: polygon.boundingRadius * 2
            )

            return expandedViewport.intersects(polygonRect)
        }

        let cullingEfficiency = Double(culledPolygons.count) / Double(max(1, polygons.count))
        renderMetrics.culllingEfficiency = cullingEfficiency

        debugLogger.debug("✂️ Culled \(polygons.count - culledPolygons.count) polygons (efficiency: \(String(format: "%.1f", cullingEfficiency * 100))%)")

        return culledPolygons
    }

    /// Apply adaptive level of detail based on zoom level and performance
    private func applyAdaptiveLOD(
        _ polygons: [OutagePolygon],
        zoomLevel: Int
    ) async -> [OutagePolygon] {

        guard renderConfig.enableAdaptiveLOD else { return polygons }

        let lodFactor = calculateLODFactor(zoomLevel: zoomLevel)

        return polygons.compactMap { polygon in
            await simplifyPolygonForLOD(polygon, lodFactor: lodFactor)
        }
    }

    private func calculateLODFactor(zoomLevel: Int) -> Double {
        // Higher zoom = more detail (lower LOD factor = less simplification)
        let normalized = Double(zoomLevel - 8) / 10.0  // Normalize zoom 8-18 to 0.0-1.0
        return max(0.1, min(1.0, 1.0 - normalized))
    }

    private func simplifyPolygonForLOD(
        _ polygon: OutagePolygon,
        lodFactor: Double
    ) async -> OutagePolygon? {

        // Skip simplification for high detail levels or small polygons
        guard lodFactor < 0.8, polygon.coordinates.count > 6 else {
            return polygon
        }

        // Simplify coordinates based on LOD factor
        let tolerance = 0.0001 * (1.0 - lodFactor) // Higher tolerance = more simplification
        let simplifiedCoords = await simplifyCoordinates(
            polygon.coordinates,
            tolerance: tolerance
        )

        // Ensure minimum polygon complexity
        guard simplifiedCoords.count >= 3 else { return nil }

        // Create simplified polygon with same properties
        return OutagePolygon(
            coordinates: simplifiedCoords,
            confidence: polygon.confidence,
            affectedDeviceData: [],  // LOD polygons don't need device data
            allDevicesInArea: []
        )
    }

    private func simplifyCoordinates(
        _ coordinates: [CLLocationCoordinate2D],
        tolerance: Double
    ) async -> [CLLocationCoordinate2D] {

        // Use Douglas-Peucker algorithm for coordinate simplification
        guard coordinates.count > 2 else { return coordinates }

        return douglasPeuckerSimplification(coordinates, tolerance: tolerance)
    }

    private func douglasPeuckerSimplification(
        _ points: [CLLocationCoordinate2D],
        tolerance: Double
    ) -> [CLLocationCoordinate2D] {

        guard points.count > 2 else { return points }

        var maxDistance = 0.0
        var maxIndex = 0
        let start = points.first!
        let end = points.last!

        for i in 1..<points.count - 1 {
            let distance = perpendicularDistance(
                point: points[i],
                lineStart: start,
                lineEnd: end
            )

            if distance > maxDistance {
                maxDistance = distance
                maxIndex = i
            }
        }

        if maxDistance > tolerance {
            let leftPart = Array(points[0...maxIndex])
            let rightPart = Array(points[maxIndex..<points.count])

            let leftSimplified = douglasPeuckerSimplification(leftPart, tolerance: tolerance)
            let rightSimplified = douglasPeuckerSimplification(rightPart, tolerance: tolerance)

            return leftSimplified + Array(rightSimplified.dropFirst())
        } else {
            return [start, end]
        }
    }

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
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Overlay Creation and Management

    /// Create MapKit polygon overlays from outage polygons
    private func createPolygonOverlays(from polygons: [OutagePolygon]) async {
        let startTime = Date()

        // Clear existing overlays
        polygonOverlays.removeAll()

        // Create new overlays
        var newOverlays: [OutagePolygonOverlay] = []

        for polygon in polygons {
            if let cachedOverlay = polygonCache[polygon.id] {
                // Reuse cached overlay if unchanged
                if await shouldUpdateOverlay(cachedOverlay, for: polygon) {
                    let updatedOverlay = await createOverlay(from: polygon)
                    newOverlays.append(updatedOverlay)
                    polygonCache[polygon.id] = updatedOverlay
                } else {
                    newOverlays.append(cachedOverlay)
                }
            } else {
                // Create new overlay
                let newOverlay = await createOverlay(from: polygon)
                newOverlays.append(newOverlay)
                polygonCache[polygon.id] = newOverlay
            }
        }

        polygonOverlays = newOverlays

        let creationTime = Date().timeIntervalSince(startTime)
        performanceLogger.debug("🎨 Created \(newOverlays.count) overlays in \(String(format: "%.6f", creationTime))s")
    }

    private func shouldUpdateOverlay(
        _ overlay: OutagePolygonOverlay,
        for polygon: OutagePolygon
    ) async -> Bool {

        // Check if polygon properties have changed significantly
        return abs(overlay.confidence - polygon.confidence) > 0.05 ||
               overlay.coordinates.count != polygon.coordinates.count ||
               overlay.timestamp.timeIntervalSince(polygon.timestamp) > 30.0
    }

    private func createOverlay(from polygon: OutagePolygon) async -> OutagePolygonOverlay {
        return OutagePolygonOverlay(
            polygon: polygon,
            coordinates: polygon.coordinates,
            confidence: polygon.confidence,
            timestamp: polygon.timestamp
        )
    }

    private func refreshOverlayAppearance(_ overlay: OutagePolygonOverlay) async {
        // Update overlay visual properties based on current configuration
        overlay.updateAppearance(
            strokeWidth: max(1.0, overlay.confidence * 3.0),
            fillOpacity: min(0.6, overlay.confidence * 0.8)
        )
    }

    // MARK: - Performance Monitoring

    private func setupPerformanceMonitoring() {
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateMemoryMetrics()
            }
        }
    }

    private func updatePerformanceMetrics(
        totalPolygons: Int,
        visiblePolygons: Int,
        renderTime: TimeInterval
    ) async {

        renderMetrics.totalPolygonsRendered = totalPolygons
        renderMetrics.visiblePolygonsCount = visiblePolygons
        renderMetrics.lastRenderTime = renderTime

        // Update rolling average for frame time
        renderMetrics.averageFrameTime = (renderMetrics.averageFrameTime * 0.9) + (renderTime * 0.1)

        // Calculate polygon complexity score
        let avgComplexity = polygonOverlays.isEmpty ? 0.0 :
            Double(polygonOverlays.map { $0.coordinates.count }.reduce(0, +)) / Double(polygonOverlays.count)
        renderMetrics.polygonComplexityScore = avgComplexity

        // Performance warnings
        if renderTime > renderConfig.targetFrameTime * 2 {
            performanceLogger.warning("⚠️ Render time exceeded target: \(String(format: "%.3f", renderTime))s > \(String(format: "%.3f", renderConfig.targetFrameTime * 2))s")
        }

        if visiblePolygons > renderConfig.maxPolygons {
            performanceLogger.warning("⚠️ Visible polygons exceed maximum: \(visiblePolygons) > \(renderConfig.maxPolygons)")
        }
    }

    private func updateMemoryMetrics() async {
        let memoryUsage = await estimateMemoryUsage()
        renderMetrics.memoryUsageMB = memoryUsage

        if memoryUsage > Double(renderConfig.memoryThresholdMB) {
            memoryLogger.warning("⚠️ Memory usage exceeded threshold: \(String(format: "%.1f", memoryUsage))MB > \(renderConfig.memoryThresholdMB)MB")
            await optimizeMemoryUsage()
        }
    }

    private func estimateMemoryUsage() async -> Double {
        // Rough estimate based on polygon count and complexity
        let polygonCount = Double(polygonOverlays.count)
        let avgComplexity = renderMetrics.polygonComplexityScore
        let cacheSize = Double(polygonCache.count)

        // Each polygon overlay ~1KB + coordinates ~0.1KB per vertex
        return (polygonCount * 1.0) + (polygonCount * avgComplexity * 0.1) + (cacheSize * 0.5)
    }

    private func optimizeMemoryUsage() async {
        // Clear cached overlays for better memory efficiency
        let cacheCountBefore = polygonCache.count

        // Keep only recently used overlays
        let recentThreshold = Date().addingTimeInterval(-300) // 5 minutes
        polygonCache = polygonCache.filter { _, overlay in
            overlay.timestamp > recentThreshold
        }

        let cacheCountAfter = polygonCache.count
        let clearedCount = cacheCountBefore - cacheCountAfter

        if clearedCount > 0 {
            memoryLogger.info("🧹 Memory optimization: cleared \(clearedCount) cached overlays")
        }
    }

    // MARK: - Utility Methods

    /// Get current rendering statistics for debugging
    func getRenderingStatistics() -> String {
        return """
        📊 POLYGON RENDERING STATISTICS:
        ==============================
        • Total Polygons: \(renderMetrics.totalPolygonsRendered)
        • Visible Polygons: \(renderMetrics.visiblePolygonsCount)
        • Cached Overlays: \(polygonCache.count)
        • Average Frame Time: \(String(format: "%.3f", renderMetrics.averageFrameTime))s
        • Memory Usage: \(String(format: "%.1f", renderMetrics.memoryUsageMB))MB
        • Culling Efficiency: \(String(format: "%.1f", renderMetrics.culllingEfficiency * 100))%
        • Polygon Complexity: \(String(format: "%.1f", renderMetrics.polygonComplexityScore)) vertices/polygon
        • Current Zoom Level: \(currentZoomLevel)
        """
    }
}

// MARK: - OutagePolygonOverlay

/// MapKit-compatible polygon overlay for rendering outage areas
@MainActor
final class OutagePolygonOverlay: NSObject, MKOverlay {

    let polygon: OutagePolygon
    let coordinates: [CLLocationCoordinate2D]
    let confidence: Double
    let timestamp: Date

    private var _boundingMapRect: MKMapRect?

    init(polygon: OutagePolygon, coordinates: [CLLocationCoordinate2D], confidence: Double, timestamp: Date) {
        self.polygon = polygon
        self.coordinates = coordinates
        self.confidence = confidence
        self.timestamp = timestamp
        super.init()
    }

    // MARK: - MKOverlay Protocol

    var coordinate: CLLocationCoordinate2D {
        return polygon.center
    }

    var boundingMapRect: MKMapRect {
        if let cached = _boundingMapRect {
            return cached
        }

        guard !coordinates.isEmpty else {
            return MKMapRect.null
        }

        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity

        for coordinate in coordinates {
            let mapPoint = MKMapPoint(coordinate)
            minX = min(minX, mapPoint.x)
            maxX = max(maxX, mapPoint.x)
            minY = min(minY, mapPoint.y)
            maxY = max(maxY, mapPoint.y)
        }

        let rect = MKMapRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )

        _boundingMapRect = rect
        return rect
    }

    // MARK: - Appearance Management

    func updateAppearance(strokeWidth: CGFloat, fillOpacity: Double) {
        // Update visual properties - implementation depends on renderer
    }
}

// MARK: - Performance Extensions

extension PolygonRenderManager {

    /// Benchmark polygon rendering performance
    static func benchmark(
        polygons: [OutagePolygon],
        viewport: MKMapRect,
        zoomLevel: Int,
        iterations: Int = 10
    ) async -> (avgRenderTime: TimeInterval, maxRenderTime: TimeInterval, minRenderTime: TimeInterval) {

        let benchmarkLogger = Logger(subsystem: "powersense.render", category: "benchmark")
        benchmarkLogger.info("🏁 Starting polygon render benchmark with \(iterations) iterations")

        let renderManager = PolygonRenderManager()
        var renderTimes: [TimeInterval] = []

        for i in 0..<iterations {
            let startTime = Date()

            await renderManager.updatePolygons(
                from: polygons,
                viewport: viewport,
                zoomLevel: zoomLevel
            )

            let renderTime = Date().timeIntervalSince(startTime)
            renderTimes.append(renderTime)

            benchmarkLogger.debug("📊 Iteration \(i + 1): \(String(format: "%.6f", renderTime))s")
        }

        let avgTime = renderTimes.reduce(0, +) / Double(renderTimes.count)
        let maxTime = renderTimes.max() ?? 0
        let minTime = renderTimes.min() ?? 0

        benchmarkLogger.info("🏆 Benchmark completed - Avg: \(String(format: "%.6f", avgTime))s, Max: \(String(format: "%.6f", maxTime))s, Min: \(String(format: "%.6f", minTime))s")

        return (avgRenderTime: avgTime, maxRenderTime: maxTime, minRenderTime: minTime)
    }
}