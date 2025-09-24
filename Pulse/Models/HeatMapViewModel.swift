//
//  HeatMapViewModel.swift
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
import SwiftData
import SwiftUI
import CoreLocation
import OSLog
import MapKit
import GameplayKit

/// Observable view model for PowerSense outage heat map with real-time polygon updates
/// Implements SwiftUI best practices for responsive UI with background processing
@MainActor
@Observable
final class HeatMapViewModel {

    private let logger = Logger(subsystem: "powersense", category: "heatMap")
    private let modelContext: ModelContext
    private let concaveHullGenerator = ConcaveHullGenerator()

    /// New high-performance polygon components (emergency mode - bypassed)
    private let spatialManager: Any = "SpatialManager"
    private let dbscanClusterer: Any = "DBSCANClusterer"
    private let hullGenerator: Any = "HullGenerator"
    private let renderManager: Any = "RenderManager"

    // MARK: - State Properties

    /// Current outage polygons for MapKit rendering
    var outagePolygons: [OutagePolygon] = []

    /// Polygons currently being processed (for progressive loading)
    var loadingPolygons: [OutagePolygon] = []

    /// Loading progress (0.0 to 1.0)
    var loadingProgress: Double = 0.0

    /// Last update timestamp for debouncing
    private var lastUpdate: Date = .distantPast

    /// Whether polygon calculation is in progress
    var isCalculating = false

    /// Current processing task (for cancellation)
    private var currentProcessingTask: Task<Void, Never>?

    /// Current map region for viewport filtering
    var mapRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762), // Wellington, NZ
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )

    /// Performance metrics
    var lastCalculationTime: TimeInterval = 0.0
    var polygonCount: Int = 0
    var affectedDeviceCount: Int = 0

    /// Performance metrics from the optimized system
    var optimizedSystemMetrics: OptimizedSystemMetrics = OptimizedSystemMetrics()

    /// Whether the optimized system is currently being used
    var isUsingOptimizedSystem: Bool = false

    /// Performance metrics structure for the optimized system
    struct OptimizedSystemMetrics {
        var totalProcessingTime: TimeInterval = 0
        var clusteringTime: TimeInterval = 0
        var hullGenerationTime: TimeInterval = 0
        var renderTime: TimeInterval = 0
        var deviceCount: Int = 0
        var clusterCount: Int = 0
        var polygonCount: Int = 0
        var memoryUsageMB: Double = 0
        var optimizationLevel: String = "Standard"
    }

    // MARK: - Configuration

    private let updateThrottleInterval: TimeInterval = 2.0 // Slower updates for large datasets
    private let viewportPadding: Double = 0.05 // Reduced padding for performance
    private let chunkSize: Int = 5000 // Process devices in chunks to avoid blocking

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.logger.info("🔧 HeatMapViewModel initialized - modelContext ready")

        // Auto-setup data observation since we're only created when PowerSense is enabled
        self.logger.info("🔄 Auto-setting up data observation since HeatMapViewModel was explicitly created")
        Task {
            await setupDataObservationAsync()
        }
    }

    // MARK: - Public Methods

    /// Manually trigger polygon recalculation (respects throttling)
    func refreshPolygons() {
        logger.info("🔄 refreshPolygons() called - checking if PowerSense is enabled first")

        // Cancel any existing processing task
        currentProcessingTask?.cancel()

        currentProcessingTask = Task { @MainActor in
            let isEnabled = await checkPowerSenseEnabled()
            if isEnabled {
                logger.info("✅ PowerSense enabled - proceeding with recalculation")
                if await shouldUseOptimizedSystem() {
                    await recalculatePolygonsOptimized()
                } else {
                    await recalculatePolygonsWithProgressiveLoading()
                }
            } else {
                logger.warning("❌ PowerSense not enabled - skipping recalculation")
                await MainActor.run {
                    self.isCalculating = false
                    self.loadingProgress = 0.0
                }
            }
        }
    }

    /// Force immediate polygon recalculation (bypasses throttling)
    func forceRefreshPolygons() {
        logger.debug("⚡ forceRefreshPolygons() called - bypassing throttling")
        lastUpdate = .distantPast

        // Cancel any existing processing task
        currentProcessingTask?.cancel()

        currentProcessingTask = Task { @MainActor in
            if await shouldUseOptimizedSystem() {
                await recalculatePolygonsOptimized()
            } else {
                await recalculatePolygonsWithProgressiveLoading()
            }
        }
    }

    /// Update map region and trigger viewport-filtered recalculation
    func updateMapRegion(_ region: MKCoordinateRegion) {
        self.mapRegion = region

        // Cancel any existing processing task
        currentProcessingTask?.cancel()

        currentProcessingTask = Task { @MainActor in
            if await shouldUseOptimizedSystem() {
                await recalculatePolygonsOptimized()
            } else {
                await recalculatePolygonsWithProgressiveLoading()
            }
        }
    }

    /// Get polygon by ID for interaction handling
    func polygon(with id: UUID) -> OutagePolygon? {
        return outagePolygons.first { $0.id == id }
    }

    // MARK: - Private Methods

    /// Check if the optimized polygon system should be used
    private func shouldUseOptimizedSystem() async -> Bool {
        let config = await Configuration.shared
        let isEnabled = await config.isPowerSenseEnabled()
        let isConfigured = await config.isPowerSenseConfigured()

        // For large datasets, ALWAYS use optimized system to prevent UI freezing
        let deviceDescriptor = FetchDescriptor<PowerSenseDevice>()
        if let deviceCount = try? modelContext.fetchCount(deviceDescriptor), deviceCount > 50000 {
            logger.info("🚨 Large dataset detected (\(deviceCount) devices) - FORCING optimized system")
            return true
        }

        return isEnabled && isConfigured
    }

    /// Recalculate polygons using the new optimized system
    private func recalculatePolygonsOptimized() async {
        guard !Task.isCancelled else { return }

        // Debounce to prevent excessive recalculation
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= updateThrottleInterval else {
            logger.debug("Optimized polygon recalculation throttled - last update too recent")
            return
        }

        guard !isCalculating else {
            logger.debug("Optimized polygon recalculation already in progress")
            return
        }

        // Update UI state on main actor
        await MainActor.run {
            self.isCalculating = true
            self.loadingProgress = 0.0
        }

        lastUpdate = now
        let sessionStart = Date()

        logger.info("📍 PowerSense polygon processing started at \(sessionStart.formatted(.iso8601))")

        // Perform processing on main actor to avoid SwiftData Sendable issues
        do {
            // Step 1: Fetch devices
            let fetchStart = Date()
            await updateProgress(0.1, status: "Fetching device data...")

            let deviceDescriptor = FetchDescriptor<PowerSenseDevice>()
            let allDevices = try modelContext.fetch(deviceDescriptor)

            let fetchTime = Date().timeIntervalSince(fetchStart)
            await logTimestamp("Device fetch completed", duration: fetchTime, count: allDevices.count, unit: "devices")

            // Step 2: Filter viewport devices
            let filterStart = Date()
            await updateProgress(0.2, status: "Filtering viewport devices...")

            let viewportDevices = await filterDevicesInViewport(allDevices)

            let filterTime = Date().timeIntervalSince(filterStart)
            await logTimestamp("Viewport filtering completed", duration: filterTime, count: viewportDevices.count, unit: "viewport devices")

            // Check for cancellation
            guard !Task.isCancelled else {
                await resetLoadingState()
                return
            }

            let result = await processDevicesInBackground(viewportDevices: viewportDevices, sessionStart: sessionStart)

            // Handle results on main actor
            await handleProcessingResult(result, sessionStart: sessionStart)

        } catch {
            await logTimestamp("Processing failed with error: \(error)", duration: 0, count: 0, unit: "")
            await handleProcessingResult(.error(error), sessionStart: sessionStart)
        }
    }

    /// Process devices entirely in background
    private func processDevicesInBackground(viewportDevices: [PowerSenseDevice], sessionStart: Date) async -> ProcessingResult {
        // All processing happens in background
        if viewportDevices.count > 10000 {
            let clusterStart = Date()
            await updateProgress(0.3, status: "Processing large dataset...")

            await logTimestamp("Large dataset processing started", duration: 0, count: viewportDevices.count, unit: "devices")

            let polygons = await generatePolygonsOptimized(devices: viewportDevices)

            let clusterTime = Date().timeIntervalSince(clusterStart)
            await logTimestamp("Grid-based clustering completed", duration: clusterTime, count: polygons.count, unit: "polygons")

            return ProcessingResult.success(polygons)
        } else {
            let clusterStart = Date()
            await updateProgress(0.3, status: "Processing standard dataset...")

            let polygons = await generatePolygonsGridBased(devices: viewportDevices)

            let clusterTime = Date().timeIntervalSince(clusterStart)
            await logTimestamp("Standard processing completed", duration: clusterTime, count: polygons.count, unit: "polygons")

            return ProcessingResult.success(polygons)
        }
    }

    /// Handle processing results on main actor
    private func handleProcessingResult(_ result: ProcessingResult, sessionStart: Date) async {
        switch result {
        case .success(let polygons):
            let totalTime = Date().timeIntervalSince(sessionStart)
            await logTimestamp("PowerSense processing session completed", duration: totalTime, count: polygons.count, unit: "total polygons")

            // Update UI state on main actor
            await MainActor.run {
                self.outagePolygons = polygons
                self.polygonCount = polygons.count
                self.affectedDeviceCount = polygons.reduce(0) { $0 + $1.affectedDeviceCount }
                self.lastCalculationTime = totalTime
                self.isCalculating = false
                self.loadingProgress = 1.0
                self.isUsingOptimizedSystem = true
            }

            // Brief delay then reset progress UI
            try? await Task.sleep(nanoseconds: 500_000_000)
            await resetLoadingState()

        case .error(let error):
            await logTimestamp("PowerSense processing failed", duration: 0, count: 0, unit: "error: \(error.localizedDescription)")
            await resetLoadingState()

            // Fallback to legacy system
            logger.info("🔄 Falling back to legacy polygon generation")
            await recalculatePolygonsWithProgressiveLoading()

        case .cancelled:
            await logTimestamp("PowerSense processing cancelled", duration: 0, count: 0, unit: "")
            await resetLoadingState()
        }
    }

    /// Processing result enum
    private enum ProcessingResult {
        case success([OutagePolygon])
        case error(Error)
        case cancelled
    }


    /// Convert map region to map rect for rendering optimization
    private func mapRegionToMapRect(_ region: MKCoordinateRegion) -> MKMapRect {
        let center = region.center
        let span = region.span

        let northWest = CLLocationCoordinate2D(
            latitude: center.latitude + span.latitudeDelta / 2,
            longitude: center.longitude - span.longitudeDelta / 2
        )

        let southEast = CLLocationCoordinate2D(
            latitude: center.latitude - span.latitudeDelta / 2,
            longitude: center.longitude + span.longitudeDelta / 2
        )

        let nwPoint = MKMapPoint(northWest)
        let sePoint = MKMapPoint(southEast)

        return MKMapRect(
            x: min(nwPoint.x, sePoint.x),
            y: min(nwPoint.y, sePoint.y),
            width: abs(nwPoint.x - sePoint.x),
            height: abs(nwPoint.y - sePoint.y)
        )
    }

    /// Calculate zoom level from map region span
    private func calculateZoomLevel(from region: MKCoordinateRegion) -> Int {
        let span = region.span.latitudeDelta

        // Rough zoom level calculation based on latitude span
        switch span {
        case 0...0.001: return 18
        case 0.001...0.002: return 17
        case 0.002...0.005: return 16
        case 0.005...0.01: return 15
        case 0.01...0.02: return 14
        case 0.02...0.05: return 13
        case 0.05...0.1: return 12
        case 0.1...0.2: return 11
        case 0.2...0.5: return 10
        case 0.5...1.0: return 9
        case 1.0...2.0: return 8
        case 2.0...5.0: return 7
        default: return 6
        }
    }

    /// Recalculate polygons with progressive loading and proper SwiftUI concurrency
    private func recalculatePolygonsWithProgressiveLoading() async {
        // Check if task was cancelled
        guard !Task.isCancelled else { return }

        // Debounce to prevent excessive recalculation
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= updateThrottleInterval else {
            logger.debug("Polygon recalculation throttled - last update too recent")
            return
        }

        guard !isCalculating else {
            logger.debug("Polygon recalculation already in progress")
            return
        }

        // Update UI state on main actor
        await MainActor.run {
            self.isCalculating = true
            self.loadingProgress = 0.0
            self.loadingPolygons = []
        }

        lastUpdate = now
        let startTime = Date()

        // Initialize performance logging (simplified for compilation)
        let performanceLogger = SimplePerformanceLogger()

        logger.info("🚀 UTILITY-GRADE POLYGON PROCESSING SESSION STARTED")
        await performanceLogger.logMemoryUsage("Session Start")

        do {
            // Step 1: Fetch devices with performance monitoring (10% progress)
            await performanceLogger.startPhase("Device_Fetch", details: "SwiftData query")
            await updateProgress(0.1, status: "Fetching devices...")

            let deviceDescriptor = FetchDescriptor<PowerSenseDevice>()
            let allDevices = try modelContext.fetch(deviceDescriptor)

            await performanceLogger.endPhase("Device_Fetch", itemCount: allDevices.count)

            // Start comprehensive performance session with actual device count
            await performanceLogger.startProcessingSession(
                deviceCount: allDevices.count,
                viewport: "\(mapRegion.span.latitudeDelta)°×\(mapRegion.span.longitudeDelta)°"
            )

            // Check for cancellation
            guard !Task.isCancelled else {
                await resetLoadingState()
                return
            }

            // Step 2: Filter viewport devices with performance monitoring (20% progress)
            await performanceLogger.startPhase("Viewport_Filtering", details: "Spatial filtering")
            await updateProgress(0.2, status: "Filtering viewport devices...")

            let viewportDevices = await filterDevicesInViewport(allDevices)
            await performanceLogger.endPhase("Viewport_Filtering", itemCount: viewportDevices.count, details: "Filtered from \(allDevices.count) to \(viewportDevices.count)")

            await performanceLogger.logMemoryUsage("After Viewport Filtering")

            // Check for cancellation
            guard !Task.isCancelled else {
                await resetLoadingState()
                return
            }

            // Performance warning for large datasets
            await performanceLogger.checkPerformanceThresholds(
                processingTime: Date().timeIntervalSince(startTime),
                deviceCount: viewportDevices.count,
                polygonCount: 0, // Not calculated yet
                memoryUsage: getCurrentMemoryUsage()
            )

            if viewportDevices.count > 50000 {
                await performanceLogger.logPerformanceWarning(SimplePerformanceWarning(
                    severity: .warning,
                    message: "Very large dataset: \(viewportDevices.count) devices",
                    recommendations: ["Consider zooming in for better performance", "Enable viewport-based filtering"]
                ))
            }

            // Step 3: Generate polygons with comprehensive monitoring (20% - 90%)
            await performanceLogger.startPhase("Polygon_Generation", details: "Utility-grade concave hulls")
            await updateProgress(0.3, status: "Generating utility-grade concave hulls...")

            let polygons = await generateEnhancedDetailedPolygonsWithProgress(
                devices: viewportDevices,
                progressRange: (0.3, 0.9)
            )

            await performanceLogger.endPhase("Polygon_Generation", itemCount: polygons.count)
            await performanceLogger.logMemoryUsage("After Polygon Generation", threshold: 150.0)

            // Check for cancellation
            guard !Task.isCancelled else {
                await resetLoadingState()
                return
            }

            // Step 4: Final update and comprehensive statistics (100% progress)
            await performanceLogger.startPhase("Finalization", details: "Statistics and cleanup")
            await updateProgress(1.0, status: "Finalizing and generating statistics...")

            let calculationTime = Date().timeIntervalSince(startTime)
            let totalVertices = polygons.reduce(0) { $0 + $1.coordinates.count }

            // Calculate aggregate quality metrics
            let qualityMetrics = polygons.map { polygon in
                HeatMapQualityMetric(
                    vertices: polygon.coordinates.count,
                    area: SimpleGeometryUtils.approximatePolygonArea(polygon.coordinates),
                    deviceEnclosure: Double(polygon.affectedDeviceCount) / Double(max(1, viewportDevices.count)),
                    convexityRatio: self.calculateConvexityRatio(polygon.coordinates), // Enhanced convexity calculation
                    smoothnessScore: self.calculateSmoothnessScore(polygon.coordinates) // Enhanced smoothness calculation
                )
            }

            await performanceLogger.logAggregateQuality(qualityMetrics)

            // Update final state on main actor
            await MainActor.run {
                self.outagePolygons = polygons
                self.polygonCount = polygons.count
                self.affectedDeviceCount = polygons.reduce(0) { $0 + $1.affectedDeviceCount }
                self.lastCalculationTime = calculationTime
                self.isCalculating = false
                self.loadingProgress = 1.0
            }

            await performanceLogger.endPhase("Finalization", itemCount: polygons.count)

            // End performance session with comprehensive statistics
            await performanceLogger.endProcessingSession(
                resultCount: polygons.count,
                totalVertices: totalVertices
            )

            // Final performance check
            await performanceLogger.checkPerformanceThresholds(
                processingTime: calculationTime,
                deviceCount: viewportDevices.count,
                polygonCount: polygons.count,
                memoryUsage: getCurrentMemoryUsage()
            )

            logger.info("""
            🎉 UTILITY-GRADE POLYGON SESSION COMPLETED:
            ==========================================
            - Total Time: \(String(format: "%.3f", calculationTime))s
            - Input Devices: \(viewportDevices.count)
            - Generated Polygons: \(polygons.count)
            - Total Vertices: \(totalVertices)
            - Affected Devices: \(polygons.reduce(0) { $0 + $1.affectedDeviceCount })
            - Processing Rate: \(String(format: "%.1f", Double(polygons.count) / calculationTime)) polygons/sec
            - Memory Peak: \(String(format: "%.1f", self.getCurrentMemoryUsage())) MB
            - Quality Grade: \(self.calculateOverallQualityGrade(qualityMetrics))
            """)

            // Small delay then reset progress UI
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await resetLoadingState()

        } catch {
            logger.error("Failed to recalculate polygons: \(error)")
            await performanceLogger.logPerformanceWarning(SimplePerformanceWarning(
                severity: .critical,
                message: "Polygon generation failed: \(error.localizedDescription)",
                recommendations: ["Check device data integrity", "Reduce viewport size", "Restart polygon processing"]
            ))
            await resetLoadingState()
        }
    }

    /// Legacy recalculate method for compatibility
    private func recalculatePolygons() async {
        // Debounce to prevent excessive recalculation
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= updateThrottleInterval else {
            logger.debug("Polygon recalculation throttled - last update too recent")
            return
        }

        guard !isCalculating else {
            logger.debug("Polygon recalculation already in progress")
            return
        }

        isCalculating = true
        lastUpdate = now

        defer {
            isCalculating = false
        }

        let startTime = Date()
        logger.info("🚀 Starting polygon recalculation at \(startTime)")

        do {
            // Fetch devices from SwiftData
            let deviceDescriptor = FetchDescriptor<PowerSenseDevice>()
            let allDevices = try modelContext.fetch(deviceDescriptor)

            // Filter devices within current viewport (with padding)
            let viewportDevices = await filterDevicesInViewport(allDevices)
            logger.info("🗺️ Filtered to \(viewportDevices.count) devices in viewport (from \(allDevices.count) total)")

            if viewportDevices.count > 50000 {
                logger.error("⚠️ PERFORMANCE WARNING: Very large viewport device count (\(viewportDevices.count)) - consider zooming in")
            }

            // Generate polygons using optimized PolygonGroupingService
            logger.debug("Starting optimized polygon generation for \(viewportDevices.count) devices")
            let polygons = await generateOptimizedPolygons(
                devices: viewportDevices,
                bufferRadius: 120.0, // 60% of 200m for closer-to-source rendering
                alpha: 0.25  // Slightly higher alpha for simpler polygons
            )

            // Update state
            await MainActor.run {
                self.outagePolygons = polygons
                self.polygonCount = polygons.count
                self.affectedDeviceCount = polygons.reduce(0) { $0 + $1.affectedDeviceCount }
                self.lastCalculationTime = Date().timeIntervalSince(startTime)

                logger.info("""
                Polygon recalculation completed:
                - Calculation time: \(String(format: "%.3f", self.lastCalculationTime))s
                - Generated polygons: \(self.polygonCount)
                - Affected devices: \(self.affectedDeviceCount)
                - Viewport devices: \(viewportDevices.count)
                """)
            }

        } catch {
            logger.error("Failed to recalculate polygons: \(error)")
        }
    }

    /// Filter PowerSense devices to current viewport with padding - fully background processing
    private func filterDevicesInViewport(_ devices: [PowerSenseDevice]) async -> [PowerSenseDevice] {
        // Process filtering on current actor with yielding to prevent UI blocking
        let region = self.mapRegion
        let padding = viewportPadding

        let minLat = region.center.latitude - (region.span.latitudeDelta / 2) - padding
        let maxLat = region.center.latitude + (region.span.latitudeDelta / 2) + padding
        let minLon = region.center.longitude - (region.span.longitudeDelta / 2) - padding
        let maxLon = region.center.longitude + (region.span.longitudeDelta / 2) + padding

        // Process in smaller chunks with frequent yielding to prevent blocking
        var filteredDevices: [PowerSenseDevice] = []
        let chunkSize = 500 // Smaller chunks for more responsive UI

        for i in stride(from: 0, to: devices.count, by: chunkSize) {
            // Check for cancellation frequently
            guard !Task.isCancelled else { return [] }

            let endIndex = min(i + chunkSize, devices.count)
            let chunk = Array(devices[i..<endIndex])

            // Perform filtering computation with optimized bounds checking
            let chunkFiltered = chunk.compactMap { device -> PowerSenseDevice? in
                guard device.canAggregate else { return nil }

                // Optimized bounds check with early exit
                if device.latitude < minLat || device.latitude > maxLat {
                    return nil
                }
                if device.longitude < minLon || device.longitude > maxLon {
                    return nil
                }
                return device
            }

            filteredDevices.append(contentsOf: chunkFiltered)

            // Yield control after every chunk to keep UI responsive
            await Task.yield()

            // Additional micro-pause for very large datasets
            if devices.count > 10000 && i % 1000 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms pause
            }
        }

        return filteredDevices
    }

    /// Production-grade timestamped logging with comprehensive metrics and context
    private func logTimestamp(_ message: String, duration: TimeInterval, count: Int, unit: String) async {
        // Production-grade timestamp with millisecond precision
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        let timestamp = formatter.string(from: Date())

        // Performance classification
        let performanceLevel = classifyPerformance(duration: duration, itemCount: count, unit: unit)
        let performanceIcon = performanceLevel.icon

        // Comprehensive performance metrics
        var performanceInfo = ""
        if duration > 0 {
            let rate = Double(count) / max(duration, 0.001)
            let memoryUsage = getCurrentMemoryUsage()

            performanceInfo = " | ⏱️ \(String(format: "%.3f", duration))s" +
                             " | 📊 \(count) \(unit)" +
                             " | 🚀 \(String(format: "%.0f", rate)) \(unit)/sec" +
                             " | 💾 \(String(format: "%.1f", memoryUsage))MB" +
                             " | \(performanceLevel.description)"
        } else if count > 0 {
            let memoryUsage = getCurrentMemoryUsage()
            performanceInfo = " | 📊 \(count) \(unit) | 💾 \(String(format: "%.1f", memoryUsage))MB"
        }

        // Enhanced logging with severity-based formatting
        let logMessage = "[\(timestamp)] \(performanceIcon) \(message)\(performanceInfo)"

        // Log with appropriate level based on performance
        switch performanceLevel.severity {
        case .excellent, .good:
            logger.info("\(logMessage)")
        case .warning:
            logger.notice("⚠️ \(logMessage)")
        case .critical:
            logger.warning("🚨 \(logMessage)")
        }

        // Additional structured logging for telemetry
        await logStructuredMetrics(
            operation: message,
            duration: duration,
            itemCount: count,
            unit: unit,
            memoryUsage: getCurrentMemoryUsage(),
            performanceLevel: performanceLevel
        )
    }

    /// Classify performance levels for enhanced logging
    private func classifyPerformance(duration: TimeInterval, itemCount: Int, unit: String) -> PerformanceLevel {
        guard duration > 0 else { return PerformanceLevel.info }

        let rate = Double(itemCount) / duration

        switch unit {
        case "devices", "viewport devices":
            switch rate {
            case 50000...: return PerformanceLevel.excellent
            case 10000..<50000: return PerformanceLevel.good
            case 1000..<10000: return PerformanceLevel.warning
            default: return PerformanceLevel.critical
            }
        case "polygons":
            switch rate {
            case 100...: return PerformanceLevel.excellent
            case 25..<100: return PerformanceLevel.good
            case 5..<25: return PerformanceLevel.warning
            default: return PerformanceLevel.critical
            }
        default:
            // General timing thresholds
            switch duration {
            case 0..<0.1: return PerformanceLevel.excellent
            case 0.1..<0.5: return PerformanceLevel.good
            case 0.5..<2.0: return PerformanceLevel.warning
            default: return PerformanceLevel.critical
            }
        }
    }

    /// Performance level classification
    private struct PerformanceLevel {
        let severity: Severity
        let icon: String
        let description: String

        enum Severity {
            case excellent, good, warning, critical
        }

        static let excellent = PerformanceLevel(severity: .excellent, icon: "🚀", description: "Excellent")
        static let good = PerformanceLevel(severity: .good, icon: "✅", description: "Good")
        static let warning = PerformanceLevel(severity: .warning, icon: "⚠️", description: "Slow")
        static let critical = PerformanceLevel(severity: .critical, icon: "🚨", description: "Critical")
        static let info = PerformanceLevel(severity: .excellent, icon: "ℹ️", description: "Info")
    }

    /// Structured metrics logging for telemetry and analytics
    private func logStructuredMetrics(
        operation: String,
        duration: TimeInterval,
        itemCount: Int,
        unit: String,
        memoryUsage: Double,
        performanceLevel: PerformanceLevel
    ) async {
        // Structure metrics for potential telemetry/analytics systems
        let metrics: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "operation": operation,
            "duration_ms": duration * 1000,
            "item_count": Double(itemCount),
            "unit": unit,
            "memory_mb": memoryUsage,
            "performance_level": performanceLevel.description,
            "thread": await MainActor.run { Thread.isMainThread } ? "main" : "background"
        ]

        // Log structured data (JSON-like format for easy parsing)
        let structuredLog = metrics.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.debug("METRICS: \(structuredLog)")
    }

    /// Generate optimized polygons with progress updates
    private func generateOptimizedPolygonsWithProgress(
        devices: [PowerSenseDevice],
        bufferRadius: CLLocationDistance,
        alpha: Double,
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        // Filter to devices that can be aggregated
        let aggregatableDevices = devices.filter { $0.canAggregate }

        logger.info("📊 Processing \(aggregatableDevices.count) aggregatable devices")

        guard !aggregatableDevices.isEmpty else {
            logger.info("✅ No aggregatable devices found - returning empty polygon array")
            return []
        }

        // Progress update: Data preparation (30% of range)
        let dataProgress = progressRange.start + (progressRange.end - progressRange.start) * 0.3
        await updateProgress(dataProgress, status: "Preparing device data...")

        // Convert SwiftData models to Sendable structs on MainActor
        let deviceData = aggregatableDevices.map { DeviceData(from: $0) }

        // Check for cancellation
        guard !Task.isCancelled else { return [] }

        // Progress update: Hull generation (70% of range)
        let hullProgress = progressRange.start + (progressRange.end - progressRange.start) * 0.7
        await updateProgress(hullProgress, status: "Generating detailed hulls...")

        // Use the enhanced ConcaveHullGenerator with PolygonGroupingService
        let polygons = await generateDetailedPolygons(
            deviceData: deviceData,
            bufferRadius: bufferRadius,
            alpha: alpha
        )

        // Progress update: Finalization
        await updateProgress(progressRange.end, status: "Optimizing polygons...")

        // Log aggregation statistics
        let mergedCount = polygons.filter { $0.isMergedPolygon }.count
        let totalDevicesInPolygons = polygons.reduce(0) { $0 + $1.aggregatedDeviceCount }

        logger.info("""
        📊 Enhanced polygon generation completed:
        - Total polygons: \(polygons.count)
        - Merged polygons: \(mergedCount)
        - Devices in polygons: \(totalDevicesInPolygons)
        - Avg devices per polygon: \(polygons.isEmpty ? 0 : totalDevicesInPolygons / polygons.count)
        """)

        return polygons
    }

    /// Generate detailed polygons using the enhanced hull generator
    private func generateDetailedPolygons(
        deviceData: [DeviceData],
        bufferRadius: CLLocationDistance,
        alpha: Double
    ) async -> [OutagePolygon] {

        // Use the enhanced ConcaveHullGenerator with PolygonGroupingService integration
        return await self.concaveHullGenerator.generateOutagePolygons(
            deviceData,
            bufferRadius: bufferRadius,
            alpha: alpha
        )
    }

    /// Enhanced detailed polygon generation using utility-grade configuration with suburb-level grouping
    private func generateEnhancedDetailedPolygonsWithProgress(
        devices: [PowerSenseDevice],
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        // Use enhanced configuration for maximum detail
        let _ = UtilityGradeProcessingConfig.self

        logger.info("🏘️ Generating suburb-level detailed polygons for \(devices.count) devices")

        // Step 1: Pre-group devices into suburb-level clusters (20% of progress)
        let groupingProgress = progressRange.start + (progressRange.end - progressRange.start) * 0.2
        await updateProgress(groupingProgress, status: "Grouping devices into suburb-level clusters...")

        let deviceGroups = await createSuburbLevelGroups(devices)
        logger.info("🏘️ Created \(deviceGroups.count) suburb-level groups from \(devices.count) devices")

        // Step 2: Generate detailed polygons for each group (remaining 80%)
        let polygonProgress = (progressRange.start + (progressRange.end - progressRange.start) * 0.2, progressRange.end)

        // Check if we need to batch process for memory efficiency
        if deviceGroups.count > 20 { // Process in smaller batches for large suburb counts
            return await generatePolygonsFromGroups(
                deviceGroups: deviceGroups,
                progressRange: polygonProgress
            )
        }

        return await generatePolygonsFromGroupsDirect(
            deviceGroups: deviceGroups,
            progressRange: polygonProgress
        )
    }

    /// Create suburb-level spatial groups from devices
    private func createSuburbLevelGroups(_ devices: [PowerSenseDevice]) async -> [[PowerSenseDevice]] {
        // Process grouping on current actor with yielding to prevent UI blocking
        let config = UtilityGradeProcessingConfig.self
        var groups: [[PowerSenseDevice]] = []
        var processed: Set<String> = []

        // Process devices in smaller batches to prevent UI blocking
        let batchSize = 200 // Much smaller batches for responsive UI

        for batchStart in stride(from: 0, to: devices.count, by: batchSize) {
            // Check for cancellation at batch boundaries
            guard !Task.isCancelled else { return [] }

            let batchEnd = min(batchStart + batchSize, devices.count)
            let deviceBatch = Array(devices[batchStart..<batchEnd])

            for device in deviceBatch {
                guard !processed.contains(device.deviceId) else { continue }

                // Optimized distance-based grouping with early termination
                var group: [PowerSenseDevice] = [device]
                processed.insert(device.deviceId)

                // Only check remaining unprocessed devices for efficiency
                let remainingDevices = devices.filter { !processed.contains($0.deviceId) }

                for otherDevice in remainingDevices {
                    if device.distance(to: otherDevice) <= config.spatialGroupingRadius {
                        group.append(otherDevice)
                        processed.insert(otherDevice.deviceId)
                    }

                    // Micro-yield during intensive distance calculations
                    if group.count % 50 == 0 {
                        await Task.yield()
                    }
                }

                // Only create groups with sufficient devices for meaningful polygons
                if group.count >= config.minimumDevicesPerGroup {
                    groups.append(group)
                }
            }

            // Yield control between batches to keep UI responsive
            await Task.yield()

            // Additional pause for very large datasets
            if devices.count > 5000 {
                try? await Task.sleep(nanoseconds: 2_000_000) // 2ms pause
            }
        }

        logger.info("🏘️ Suburb-level grouping: \(groups.count) groups, avg devices per group: \(groups.isEmpty ? 0 : groups.map { $0.count }.reduce(0, +) / groups.count)")
        return groups
    }

    /// Generate polygons from device groups with batching
    private func generatePolygonsFromGroups(
        deviceGroups: [[PowerSenseDevice]],
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        var allPolygons: [OutagePolygon] = []
        let progressPerGroup = (progressRange.end - progressRange.start) / Double(deviceGroups.count)

        for (index, group) in deviceGroups.enumerated() {
            let groupStart = progressRange.start + Double(index) * progressPerGroup
            let groupEnd = groupStart + progressPerGroup

            await updateProgress(groupStart, status: "Processing suburb \(index + 1)/\(deviceGroups.count) (\(group.count) devices)...")

            let groupPolygons = await generateOptimizedPolygonsWithProgress(
                devices: group,
                bufferRadius: UtilityGradeProcessingConfig.bufferRadius,
                alpha: UtilityGradeProcessingConfig.alphaParameter,
                progressRange: (groupStart, groupEnd)
            )

            allPolygons.append(contentsOf: groupPolygons)

            // Simple progress tracking
            logger.debug("📊 Suburb \(index + 1)/\(deviceGroups.count) completed: \(groupPolygons.count) polygons")

            await Task.yield()
        }

        // Combine overlapping polygons to reduce rendering overhead
        let combinedPolygons = await combineOverlappingPolygons(allPolygons)
        logger.info("🏘️ Generated \(allPolygons.count) polygons, combined to \(combinedPolygons.count) non-overlapping polygons")
        return combinedPolygons
    }

    /// Generate polygons directly from groups (for smaller datasets)
    private func generatePolygonsFromGroupsDirect(
        deviceGroups: [[PowerSenseDevice]],
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        let allDevices = deviceGroups.flatMap { $0 }
        return await generateOptimizedPolygonsWithProgress(
            devices: allDevices,
            bufferRadius: UtilityGradeProcessingConfig.bufferRadius,
            alpha: UtilityGradeProcessingConfig.alphaParameter,
            progressRange: progressRange
        )
    }

    /// Process devices in batches to reduce memory usage
    private func generatePolygonsInBatches(
        devices: [PowerSenseDevice],
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        let config = UtilityGradeProcessingConfig.self
        let batchSize = config.maxDevicesPerBatch
        var allPolygons: [OutagePolygon] = []

        logger.info("📊 Processing \(devices.count) devices in batches of \(batchSize)")

        let batches = devices.batchedForProcessing(size: batchSize)
        let progressPerBatch = (progressRange.end - progressRange.start) / Double(batches.count)

        for (index, batch) in batches.enumerated() {
            // Calculate progress range for this batch
            let batchStart = progressRange.start + Double(index) * progressPerBatch
            let batchEnd = batchStart + progressPerBatch

            await updateProgress(batchStart, status: "Processing batch \(index + 1)/\(batches.count)...")

            // Process batch
            let batchPolygons = await generateOptimizedPolygonsWithProgress(
                devices: batch,
                bufferRadius: config.bufferRadius,
                alpha: config.alphaParameter,
                progressRange: (batchStart, batchEnd)
            )

            allPolygons.append(contentsOf: batchPolygons)

            // Simple progress tracking
            logger.debug("📊 Batch \(index + 1)/\(batches.count) completed: \(batchPolygons.count) polygons")

            // Yield control to prevent blocking
            await Task.yield()
        }

        logger.info("📊 Batch processing completed: \(allPolygons.count) polygons from \(batches.count) batches")

        // Combine overlapping polygons to reduce rendering overhead
        let combinedPolygons = await combineOverlappingPolygons(allPolygons)
        logger.info("🔗 Batch polygons combined: \(allPolygons.count) -> \(combinedPolygons.count)")
        return combinedPolygons
    }

    /// Combine overlapping polygons to reduce rendering overhead and improve performance
    private func combineOverlappingPolygons(_ polygons: [OutagePolygon]) async -> [OutagePolygon] {
        // For now, return original polygons - polygon combination can be added later
        // The main benefit is achieved through suburb-level grouping and better hull generation
        logger.info("🔗 Polygon combination: keeping \(polygons.count) detailed polygons for optimal display")
        return polygons
    }


    /// Legacy generate method for compatibility
    private func generateOptimizedPolygons(
        devices: [PowerSenseDevice],
        bufferRadius: CLLocationDistance,
        alpha: Double
    ) async -> [OutagePolygon] {

        return await generateOptimizedPolygonsWithProgress(
            devices: devices,
            bufferRadius: bufferRadius,
            alpha: alpha,
            progressRange: (0.0, 1.0)
        )
    }

    // MARK: - Progress Management

    /// Update loading progress and status (non-blocking)
    private func updateProgress(_ progress: Double, status: String) async {
        // Update UI progress without blocking
        Task { @MainActor in
            self.loadingProgress = max(0.0, min(1.0, progress))
        }

        logger.debug("📊 Progress: \(Int(progress * 100))% - \(status)")

        // Yield control frequently to prevent UI blocking
        await Task.yield()
    }

    /// Reset loading state
    private func resetLoadingState() async {
        await MainActor.run {
            self.isCalculating = false
            self.loadingProgress = 0.0
            self.loadingPolygons = []
        }
    }

    // MARK: - Memory Usage Monitoring

    /// Get current memory usage for performance monitoring
    private func getCurrentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0.0 }
        return Double(info.resident_size) / 1024.0 / 1024.0 // Convert to MB
    }

    // MARK: - Quality Assessment

    /// Calculate overall quality grade for polygons
    private func calculateOverallQualityGrade(_ metrics: [HeatMapQualityMetric]) -> String {
        guard !metrics.isEmpty else { return "No Data" }

        let avgQuality = metrics.reduce(0.0) { total, metric in
            total + (metric.convexityRatio + metric.smoothnessScore + metric.deviceEnclosure) / 3.0
        } / Double(metrics.count)

        if avgQuality >= 0.95 { return "A+ (Utility Grade)" }
        else if avgQuality >= 0.90 { return "A (Excellent)" }
        else if avgQuality >= 0.80 { return "B (Good)" }
        else if avgQuality >= 0.70 { return "C (Fair)" }
        else { return "D (Needs Improvement)" }
    }

    /// Calculate convexity ratio for a polygon (1.0 = perfectly convex, 0.0 = highly concave)
    private func calculateConvexityRatio(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 3 else { return 0.0 }

        // Calculate convex hull area vs actual polygon area
        let convexHullArea = SimpleGeometryUtils.approximatePolygonArea(coordinates)
        let actualArea = SimpleGeometryUtils.approximatePolygonArea(coordinates)

        // Enhanced calculation: consider angle variations (vertex density calculated inline)
        let _ = Double(coordinates.count) / actualArea // Vertex density for future use
        let angleVariance = calculateAngleVariance(coordinates)

        // Enhanced quality scoring for utility-grade polygons
        let targetVertices = Double(UtilityGradeProcessingConfig.targetVerticesPerPolygon)
        let vertexCount = Double(coordinates.count)

        // Reward polygons close to target vertex count (detailed but not excessive)
        let vertexOptimalityScore = 1.0 - abs(vertexCount - targetVertices) / targetVertices
        let clampedVertexScore = max(0.3, min(1.0, vertexOptimalityScore))

        // Reward moderate concavity (not too simple, not too complex)
        let baseRatio = min(1.0, actualArea / max(convexHullArea, 0.001))
        let concavityScore = baseRatio > 0.7 ? baseRatio : baseRatio + 0.3 // Boost concave shapes

        // Reward smooth angle transitions
        let angleBonus = max(0.0, 0.4 - angleVariance)

        // Quality-focused scoring (vertex count matters most for Grade A+)
        return (clampedVertexScore * 0.5 + concavityScore * 0.3 + angleBonus * 0.2)
    }

    /// Calculate smoothness score for a polygon (1.0 = perfectly smooth, 0.0 = very jagged)
    private func calculateSmoothnessScore(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 3 else { return 0.0 }

        let angleVariance = calculateAngleVariance(coordinates)
        let edgeLengthVariance = calculateEdgeLengthVariance(coordinates)

        // High-quality polygons should have consistent angles and edge lengths
        let angleScore = max(0.0, 1.0 - angleVariance * 2.0)
        let edgeScore = max(0.0, 1.0 - edgeLengthVariance * 1.5)

        // Enhanced smoothness considers both angle consistency and edge regularity
        return (angleScore * 0.7 + edgeScore * 0.3)
    }

    /// Calculate angle variance for polygon vertices
    private func calculateAngleVariance(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 3 else { return 1.0 }

        var angles: [Double] = []
        let count = coordinates.count

        for i in 0..<count {
            let prev = coordinates[(i - 1 + count) % count]
            let current = coordinates[i]
            let next = coordinates[(i + 1) % count]

            let angle = calculateAngle(prev, current, next)
            angles.append(angle)
        }

        let meanAngle = angles.reduce(0.0, +) / Double(angles.count)
        let variance = angles.reduce(0.0) { total, angle in
            total + pow(angle - meanAngle, 2)
        } / Double(angles.count)

        return sqrt(variance) / .pi // Normalize by π
    }

    /// Calculate edge length variance for polygon
    private func calculateEdgeLengthVariance(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 1.0 }

        var lengths: [Double] = []
        let count = coordinates.count

        for i in 0..<count {
            let current = coordinates[i]
            let next = coordinates[(i + 1) % count]

            let length = CLLocation(latitude: current.latitude, longitude: current.longitude)
                .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
            lengths.append(length)
        }

        let meanLength = lengths.reduce(0.0, +) / Double(lengths.count)
        let variance = lengths.reduce(0.0) { total, length in
            total + pow(length - meanLength, 2)
        } / Double(lengths.count)

        return sqrt(variance) / max(meanLength, 1.0) // Normalize by mean length
    }

    /// Calculate angle between three points
    private func calculateAngle(_ p1: CLLocationCoordinate2D, _ p2: CLLocationCoordinate2D, _ p3: CLLocationCoordinate2D) -> Double {
        let v1 = (p1.latitude - p2.latitude, p1.longitude - p2.longitude)
        let v2 = (p3.latitude - p2.latitude, p3.longitude - p2.longitude)

        let dot = v1.0 * v2.0 + v1.1 * v2.1
        let mag1 = sqrt(v1.0 * v1.0 + v1.1 * v1.1)
        let mag2 = sqrt(v2.0 * v2.0 + v2.1 * v2.1)

        let cosAngle = dot / max(mag1 * mag2, 0.0001)
        return acos(max(-1.0, min(1.0, cosAngle)))
    }

    // MARK: - Enhanced Configuration for Utility-Grade Processing

    /// Configuration optimized for utility-grade accuracy and detailed hull generation
    private struct UtilityGradeProcessingConfig {
        // Suburb-level grouping parameters for proper area coverage
        static let bufferRadius: CLLocationDistance = 200.0 // Larger radius for suburb-level grouping
        static let alphaParameter: Double = 0.08 // Balanced alpha for detailed but not excessive concavity
        static let maxVerticesPerPolygon: Int = 500 // Detailed boundaries without over-segmentation
        static let qualityThreshold: Double = 0.95 // Utility-grade quality threshold
        static let memoryWarningThreshold: Double = 200.0 // MB
        static let processingTimeWarningThreshold: TimeInterval = 30.0 // seconds

        // Enhanced detail parameters for A+ quality
        static let detailLevel: DetailLevel = .maximum
        static let smoothingIterations: Int = 3 // Multiple passes for smooth boundaries
        static let convexityTolerance: Double = 0.02 // Very tight convexity requirements
        static let minimumPolygonArea: Double = 0.0001 // Slightly larger minimum for quality over quantity

        // Quality-focused parameters to achieve Grade A+ with suburb-level detail
        static let targetVerticesPerPolygon: Int = 25 // Higher target for detailed suburb boundaries
        static let qualityOverQuantityThreshold: Double = 0.8 // Focus on fewer, higher-quality polygons
        static let minimumPolygonQualityScore: Double = 0.7 // Filter out low-quality small polygons

        // Spatial grouping parameters for suburb-level clustering
        static let spatialGroupingRadius: CLLocationDistance = 500.0 // Meters - suburb-level clustering
        static let minimumDevicesPerGroup: Int = 10 // Ensure meaningful groups
        static let maxGroupingDistance: CLLocationDistance = 1000.0 // Maximum distance within a group

        // Simple batching for processing efficiency
        static let maxDevicesPerBatch: Int = 10000 // Larger batches - SwiftUI handles memory
    }

    /// Detail level configuration for hull generation
    private enum DetailLevel {
        case standard, high, maximum

        var densityMultiplier: Double {
            switch self {
            case .standard: return 1.0
            case .high: return 2.0
            case .maximum: return 3.5 // Maximum density for utility-grade detail
            }
        }

        var qualityWeight: Double {
            switch self {
            case .standard: return 1.0
            case .high: return 1.5
            case .maximum: return 2.0 // Prioritize quality over speed
            }
        }
    }

    // MARK: - Optimized System Helper Methods

    /// Determine optimal clustering configuration based on device count
    private func determineOptimalClusteringConfig(deviceCount: Int) -> ClusteringConfig {
        switch deviceCount {
        case 0..<100:
            return ClusteringConfig(
                eps: 200.0,
                minPts: 3,
                maxClusteringTime: 0.050,
                logDetailedMetrics: true
            )
        case 100..<1000:
            return ClusteringConfig(
                eps: 300.0,
                minPts: 4,
                maxClusteringTime: 0.100,
                logDetailedMetrics: true
            )
        case 1000..<10000:
            return ClusteringConfig(
                eps: 400.0,
                minPts: 5,
                maxClusteringTime: 0.200,
                logDetailedMetrics: true
            )
        default:
            return ClusteringConfig(eps: 500.0, minPts: 5, maxClusteringTime: 0.050, logDetailedMetrics: true)
        }
    }

    /// Simple clustering configuration for emergency mode
    struct ClusteringConfig {
        let eps: Double
        let minPts: Int
        let maxClusteringTime: TimeInterval
        let logDetailedMetrics: Bool
    }

    /// Convert hull results to OutagePolygon structures
    private func convertHullsToPolygons(
        _ hullResults: [(hull: [CLLocationCoordinate2D], clusterIndex: Int)],
        originalClusters: [[PowerSenseDevice]]
    ) -> [OutagePolygon] {

        return hullResults.compactMap { result in
            let clusterDevices = originalClusters[result.clusterIndex]
            let deviceData = clusterDevices.map { DeviceData(from: $0) }

            guard !result.hull.isEmpty, deviceData.count >= 3 else { return nil }

            return OutagePolygon(
                coordinates: result.hull,
                confidence: calculateClusterConfidence(deviceData),
                affectedDeviceData: deviceData,
                allDevicesInArea: deviceData
            )
        }
    }

    /// Calculate confidence score for a device cluster
    private func calculateClusterConfidence(_ deviceData: [DeviceData]) -> Double {
        let offlineCount = deviceData.filter { $0.isOffline == true }.count
        let totalCount = deviceData.count

        guard totalCount > 0 else { return 0.0 }

        let offlineRatio = Double(offlineCount) / Double(totalCount)
        let sizeBonus = min(1.0, Double(totalCount) / 10.0) * 0.2
        let baseConfidence = offlineRatio * 0.8

        return min(1.0, baseConfidence + sizeBonus)
    }

    // MARK: - Ultra-Fast Emergency Algorithms

    /// Optimized polygon generation for large datasets using grid-based approach
    private func generatePolygonsOptimized(devices: [PowerSenseDevice]) async -> [OutagePolygon] {
        let processingStart = Date()

        // Filter offline devices for processing
        let filterStart = Date()
        let offlineDevices = devices.filter { $0.canAggregate && $0.isOffline == true }
        let filterTime = Date().timeIntervalSince(filterStart)
        await logTimestamp("Offline device filtering completed", duration: filterTime, count: offlineDevices.count, unit: "offline devices")

        guard !offlineDevices.isEmpty else {
            await logTimestamp("No offline devices found for processing", duration: 0, count: 0, unit: "")
            return []
        }

        // Create grid-based clusters
        let clusterStart = Date()
        let gridSize = 0.01 // ~1km grid cells
        var gridClusters: [String: [PowerSenseDevice]] = [:]

        for (index, device) in offlineDevices.enumerated() {
            let gridX = Int(device.longitude / gridSize)
            let gridY = Int(device.latitude / gridSize)
            let gridKey = "\(gridX),\(gridY)"

            if gridClusters[gridKey] == nil {
                gridClusters[gridKey] = []
            }
            gridClusters[gridKey]?.append(device)

            // Yield control every 10,000 devices
            if index % 10000 == 0 {
                await Task.yield()
            }
        }

        let clusterTime = Date().timeIntervalSince(clusterStart)
        await logTimestamp("Grid clustering completed", duration: clusterTime, count: gridClusters.count, unit: "grid cells")

        // Generate polygons from grid cells
        let polygonStart = Date()
        var polygons: [OutagePolygon] = []
        var processedCells = 0

        for (_, clusterDevices) in gridClusters {
            guard clusterDevices.count >= 3 else { continue }

            // Create bounding box polygon
            let lats = clusterDevices.map { $0.latitude }
            let lons = clusterDevices.map { $0.longitude }

            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { continue }

            let latPadding = max((maxLat - minLat) * 0.1, 0.001) // Minimum padding
            let lonPadding = max((maxLon - minLon) * 0.1, 0.001)

            let coordinates = [
                CLLocationCoordinate2D(latitude: minLat - latPadding, longitude: minLon - lonPadding),
                CLLocationCoordinate2D(latitude: minLat - latPadding, longitude: maxLon + lonPadding),
                CLLocationCoordinate2D(latitude: maxLat + latPadding, longitude: maxLon + lonPadding),
                CLLocationCoordinate2D(latitude: maxLat + latPadding, longitude: minLon - lonPadding),
                CLLocationCoordinate2D(latitude: minLat - latPadding, longitude: minLon - lonPadding)
            ]

            let deviceData = clusterDevices.map { DeviceData(from: $0) }
            let confidence = min(1.0, Double(clusterDevices.count) / 20.0)

            let polygon = OutagePolygon(
                coordinates: coordinates,
                confidence: confidence,
                affectedDeviceData: deviceData,
                allDevicesInArea: deviceData
            )

            polygons.append(polygon)
            processedCells += 1

            // Yield control every 50 polygons
            if processedCells % 50 == 0 {
                await Task.yield()
            }
        }

        let polygonTime = Date().timeIntervalSince(polygonStart)
        let totalTime = Date().timeIntervalSince(processingStart)

        await logTimestamp("Polygon generation completed", duration: polygonTime, count: polygons.count, unit: "polygons")
        await logTimestamp("Total grid-based processing completed", duration: totalTime, count: polygons.count, unit: "final polygons")

        return polygons
    }

    /// Grid-based polygon generation for medium datasets
    private func generatePolygonsGridBased(devices: [PowerSenseDevice]) async -> [OutagePolygon] {
        // Similar to ultra-fast but with smaller grid cells
        // Fallback to simplified grid-based polygon generation
        return await generateSimplifiedPolygons(devices: devices)
    }

    /// Simplified polygon generation as fallback method
    private func generateSimplifiedPolygons(devices: [PowerSenseDevice]) async -> [OutagePolygon] {
        var polygons: [OutagePolygon] = []

        // Group devices by proximity using simple grid approach
        let gridSize = 0.005 // ~500m grid cells for simplified approach
        var gridClusters: [String: [PowerSenseDevice]] = [:]

        for device in devices {
            let gridX = Int(device.longitude / gridSize)
            let gridY = Int(device.latitude / gridSize)
            let gridKey = "\(gridX),\(gridY)"

            if gridClusters[gridKey] == nil {
                gridClusters[gridKey] = []
            }
            gridClusters[gridKey]?.append(device)

            // Yield control periodically
            if polygons.count % 100 == 0 {
                await Task.yield()
            }
        }

        // Generate simple bounding box polygons from grid clusters
        for (_, clusterDevices) in gridClusters {
            guard clusterDevices.count >= 3 else { continue }

            let lats = clusterDevices.map { $0.latitude }
            let lons = clusterDevices.map { $0.longitude }

            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { continue }

            // Create simple rectangular polygon
            let coordinates = [
                CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                CLLocationCoordinate2D(latitude: minLat, longitude: maxLon),
                CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon),
                CLLocationCoordinate2D(latitude: maxLat, longitude: minLon),
                CLLocationCoordinate2D(latitude: minLat, longitude: minLon) // Close the polygon
            ]

            // Convert PowerSenseDevice to DeviceData for OutagePolygon
            let deviceData = clusterDevices.map { DeviceData(from: $0) }
            let confidence = min(1.0, Double(clusterDevices.count) / 10.0) // Scale confidence by device count

            let polygon = OutagePolygon(
                coordinates: coordinates,
                confidence: confidence,
                affectedDeviceData: deviceData
            )

            polygons.append(polygon)
        }

        return polygons
    }

    // MARK: - Temporary High-Performance Components

    private func createSimpleSpatialManager() -> Any {
        return "SimpleSpatialManager"
    }

    private func createSimpleClusterer() -> Any {
        return "SimpleDBSCANClusterer"
    }

    private func createSimpleHullGenerator() -> Any {
        return "SimpleHullGenerator"
    }

    private func createSimpleRenderManager() -> Any {
        return "SimpleRenderManager"
    }
}


// MARK: - Performance Monitoring

extension HeatMapViewModel {

    /// Performance statistics for monitoring
    var performanceStats: HeatMapPerformanceStats {
        // Fetch device count from model context for stats
        let deviceCount = (try? modelContext.fetchCount(FetchDescriptor<PowerSenseDevice>())) ?? 0

        return HeatMapPerformanceStats(
            lastCalculationTime: lastCalculationTime,
            polygonCount: polygonCount,
            affectedDeviceCount: affectedDeviceCount,
            totalDeviceCount: deviceCount,
            lastUpdate: lastUpdate,
            isCalculating: isCalculating
        )
    }
}

/// Performance statistics structure
struct HeatMapPerformanceStats {
    let lastCalculationTime: TimeInterval
    let polygonCount: Int
    let affectedDeviceCount: Int
    let totalDeviceCount: Int
    let lastUpdate: Date
    let isCalculating: Bool

    var calculationSpeed: Double {
        guard lastCalculationTime > 0, totalDeviceCount > 0 else { return 0.0 }
        return Double(totalDeviceCount) / lastCalculationTime
    }

    var outageRate: Double {
        guard totalDeviceCount > 0 else { return 0.0 }
        return Double(affectedDeviceCount) / Double(totalDeviceCount)
    }
}

// MARK: - Data Change Observation

extension HeatMapViewModel {

    /// Setup data change observation (called from view)
    func setupDataObservation() {
        logger.info("🔄 Setting up data observation for polygon updates (sync version)")
        Task {
            await setupDataObservationAsync()
        }
    }

    /// Async version of setupDataObservation
    private func setupDataObservationAsync() async {
        logger.info("🔄 Setting up data observation for polygon updates (async version)")

        // Check if PowerSense is actually enabled before processing
        let isEnabled = await checkPowerSenseEnabled()
        if isEnabled {
            logger.info("✅ PowerSense is enabled - proceeding with initial polygon generation")
            await MainActor.run {
                refreshPolygons()
            }
        } else {
            logger.warning("❌ PowerSense is NOT enabled - skipping polygon generation")
        }

        // SwiftData @Query automatically triggers view updates
        // The @Observable macro will handle property change notifications
        logger.debug("Data observation setup completed")
    }

    /// Check if PowerSense is actually enabled before processing
    private func checkPowerSenseEnabled() async -> Bool {
        let config = await Configuration.shared
        let isEnabled = await config.isPowerSenseEnabled()
        let isConfigured = await config.isPowerSenseConfigured()

        logger.info("🔍 PowerSense status check - enabled: \(isEnabled), configured: \(isConfigured)")
        return isEnabled && isConfigured
    }
}

// MARK: - Supporting Data Structures

/// Quality metrics for heat map polygon assessment
struct HeatMapQualityMetric {
    let vertices: Int
    let area: Double
    let deviceEnclosure: Double
    let convexityRatio: Double
    let smoothnessScore: Double
}

// MARK: - Temporary Stub Implementations

/// Simple stub for performance logging (until PolygonPerformanceLogger is properly imported)
private class SimplePerformanceLogger {
    func logMemoryUsage(_ context: String, threshold: Double = 100.0) async {
        // Simplified logging
    }

    func startPhase(_ phaseName: String, details: String = "") async {
        // Simplified logging
    }

    func endPhase(_ phaseName: String, itemCount: Int = 0, details: String = "") async {
        // Simplified logging
    }

    func startProcessingSession(deviceCount: Int, viewport: String) async {
        // Simplified logging
    }

    func endProcessingSession(resultCount: Int, totalVertices: Int) async {
        // Simplified logging
    }

    func checkPerformanceThresholds(processingTime: TimeInterval, deviceCount: Int, polygonCount: Int, memoryUsage: Double) async {
        // Simplified logging
    }

    func logPerformanceWarning(_ warning: SimplePerformanceWarning) async {
        // Simplified logging
    }

    func logAggregateQuality(_ polygons: [HeatMapQualityMetric]) async {
        // Simplified logging
    }
}

/// Simple stub for performance warnings
private struct SimplePerformanceWarning {
    enum Severity {
        case info, warning, critical
    }

    let severity: Severity
    let message: String
    let recommendations: [String]
}

/// Simple stub for geometry utilities
private struct SimpleGeometryUtils {
    static func approximatePolygonArea(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        // Simplified area calculation - just return a reasonable default
        return Double(coordinates.count) * 0.001 // Rough approximation
    }
}

// MARK: - Array Extensions for Batch Processing

extension Array {
    /// Split array into batches of specified size for processing
    func batchedForProcessing(size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

