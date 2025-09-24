//
//  PowerSensePolygonIntegrator.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  High-performance PowerSense polygon system integration
//  Connects optimized clustering and rendering with existing UI components
//

import Foundation
import SwiftData
import SwiftUI
import MapKit
import OSLog

/// Integration manager that connects the new high-performance polygon system with existing PowerSense UI
@MainActor
public final class PowerSensePolygonIntegrator: ObservableObject {

    // MARK: - Logging Infrastructure

    private let integrationLogger = Logger(subsystem: "powersense.integration", category: "polygons")
    private let performanceLogger = Logger(subsystem: "powersense.integration", category: "performance")
    private let debugLogger = Logger(subsystem: "powersense.integration", category: "debug")

    // MARK: - Core Components

    /// Spatial device manager for O(log n) operations
    private let spatialManager = SpatialDeviceManager()

    /// DBSCAN clusterer for device grouping
    private let dbscanClusterer = DBSCANClusterer()

    /// Graham scan hull generator
    private let hullGenerator = GrahamScanHullGenerator()

    /// Polygon render manager for MapKit
    private let renderManager = PolygonRenderManager()

    /// Legacy hull generator for compatibility
    private let legacyHullGenerator = ConcaveHullGenerator()

    // MARK: - Published State

    /// Current outage polygons for UI display
    @Published private(set) var outagePolygons: [OutagePolygon] = []

    /// Performance metrics
    @Published private(set) var performanceMetrics = IntegrationPerformanceMetrics()

    /// Processing state
    @Published private(set) var isProcessing = false
    @Published private(set) var processingProgress: Double = 0.0
    @Published private(set) var processingStatus = "Ready"

    // MARK: - Configuration

    private let integrationConfig = IntegrationConfig.default

    public struct IntegrationConfig {
        let useOptimizedClustering: Bool
        let enableParallelProcessing: Bool
        let maxDevicesForOptimizedPath: Int
        let fallbackToLegacyThreshold: Int
        let performanceMonitoringEnabled: Bool

        static let `default` = IntegrationConfig(
            useOptimizedClustering: true,
            enableParallelProcessing: true,
            maxDevicesForOptimizedPath: 100_000,
            fallbackToLegacyThreshold: 500_000,
            performanceMonitoringEnabled: true
        )
    }

    public struct IntegrationPerformanceMetrics {
        var totalProcessingTime: TimeInterval = 0
        var clusteringTime: TimeInterval = 0
        var hullGenerationTime: TimeInterval = 0
        var renderTime: TimeInterval = 0
        var deviceCount: Int = 0
        var clusterCount: Int = 0
        var polygonCount: Int = 0
        var memoryUsageMB: Double = 0
        var optimizationLevel: OptimizationLevel = .standard
    }

    public enum OptimizationLevel: String, CaseIterable {
        case standard = "Standard"
        case optimized = "Optimized"
        case highPerformance = "High Performance"
        case legacy = "Legacy Fallback"
    }

    // MARK: - Initialization

    init() {
        integrationLogger.info("🔗 PowerSensePolygonIntegrator initialized")
        setupPerformanceMonitoring()
    }

    // MARK: - Main Integration Interface

    /// Generate polygons using the optimal system based on device count and configuration
    public func generatePolygonsOptimized(
        from devices: [PowerSenseDevice],
        viewport: MKMapRect,
        zoomLevel: Int
    ) async -> [OutagePolygon] {

        let startTime = Date()
        isProcessing = true
        processingProgress = 0.0
        processingStatus = "Starting optimization analysis..."

        defer {
            isProcessing = false
            processingProgress = 1.0
            performanceMetrics.totalProcessingTime = Date().timeIntervalSince(startTime)
        }

        integrationLogger.info("🚀 Starting optimized polygon generation for \(devices.count) devices")

        do {
            // Step 1: Determine optimal processing path (10% progress)
            await updateProgress(0.1, status: "Analyzing processing requirements...")
            let processingPath = determineOptimalProcessingPath(deviceCount: devices.count)
            performanceMetrics.optimizationLevel = processingPath

            // Step 2: Filter and prepare devices (20% progress)
            await updateProgress(0.2, status: "Preparing spatial data...")
            let processibleDevices = await prepareDevicesForProcessing(devices)

            // Step 3: Initialize spatial index (30% progress)
            await updateProgress(0.3, status: "Building spatial index...")
            await initializeSpatialIndex(with: processibleDevices)

            // Step 4: Generate polygons using optimal path (30% - 80% progress)
            let polygons = await generatePolygonsWithOptimalPath(
                devices: processibleDevices,
                processingPath: processingPath,
                progressRange: (0.3, 0.8)
            )

            // Step 5: Optimize for rendering (80% - 90% progress)
            await updateProgress(0.8, status: "Optimizing for rendering...")
            await renderManager.updatePolygons(
                from: polygons,
                viewport: viewport,
                zoomLevel: zoomLevel
            )

            // Step 6: Final update (90% - 100% progress)
            await updateProgress(0.9, status: "Finalizing polygons...")
            await MainActor.run {
                self.outagePolygons = polygons
                self.performanceMetrics.polygonCount = polygons.count
                self.performanceMetrics.deviceCount = processibleDevices.count
            }

            await updateProgress(1.0, status: "Completed")

            let totalTime = Date().timeIntervalSince(startTime)
            integrationLogger.info("""
            ✅ Optimized polygon generation completed:
            • Processing Path: \(processingPath.rawValue)
            • Total Time: \(String(format: "%.3f", totalTime))s
            • Device Count: \(processibleDevices.count)
            • Polygon Count: \(polygons.count)
            • Performance: \(String(format: "%.0f", Double(processibleDevices.count) / totalTime)) devices/sec
            """)

            return polygons

        } catch {
            integrationLogger.error("❌ Optimized polygon generation failed: \(error)")
            await updateProgress(1.0, status: "Error: \(error.localizedDescription)")

            // Fallback to legacy system
            return await fallbackToLegacySystem(devices: devices)
        }
    }

    /// Legacy compatibility method for existing HeatMapViewModel
    func generatePolygonsLegacyCompatible(from deviceData: [DeviceData]) async -> [OutagePolygon] {
        integrationLogger.info("🔄 Legacy compatibility mode - generating polygons for \(deviceData.count) devices")

        // Use the existing ConcaveHullGenerator for full compatibility
        return await legacyHullGenerator.generateOutagePolygons(deviceData)
    }

    // MARK: - Processing Path Determination

    private func determineOptimalProcessingPath(deviceCount: Int) -> OptimizationLevel {
        guard integrationConfig.useOptimizedClustering else {
            return .legacy
        }

        switch deviceCount {
        case 0..<100:
            return .standard
        case 100..<10_000:
            return .optimized
        case 10_000..<integrationConfig.maxDevicesForOptimizedPath:
            return .highPerformance
        default:
            return .legacy // Fallback for very large datasets
        }
    }

    private func generatePolygonsWithOptimalPath(
        devices: [PowerSenseDevice],
        processingPath: OptimizationLevel,
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        switch processingPath {
        case .standard:
            return await generatePolygonsStandard(devices: devices, progressRange: progressRange)
        case .optimized:
            return await generatePolygonsOptimized(devices: devices, progressRange: progressRange)
        case .highPerformance:
            return await generatePolygonsHighPerformance(devices: devices, progressRange: progressRange)
        case .legacy:
            return await generatePolygonsLegacy(devices: devices, progressRange: progressRange)
        }
    }

    // MARK: - Processing Implementations

    private func generatePolygonsStandard(
        devices: [PowerSenseDevice],
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        let midProgress = progressRange.start + (progressRange.end - progressRange.start) * 0.6
        await updateProgress(midProgress, status: "Clustering devices (standard)...")

        // Use basic DBSCAN clustering
        let clusters = await dbscanClusterer.cluster(
            devices: devices,
            config: DBSCANClusterer.ClusteringConfig.default,
            spatialManager: spatialManager
        )

        performanceMetrics.clusterCount = clusters.count

        // Generate hulls for each cluster
        await updateProgress(progressRange.end * 0.8, status: "Generating convex hulls...")
        let hullResults = await hullGenerator.generateHullsBatch(clusters: clusters)

        // Convert to OutagePolygons
        return convertHullsToPolygons(hullResults, originalClusters: clusters)
    }

    private func generatePolygonsOptimized(
        devices: [PowerSenseDevice],
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        let clusterProgress = progressRange.start + (progressRange.end - progressRange.start) * 0.4
        await updateProgress(clusterProgress, status: "Optimized clustering...")

        // Use optimized DBSCAN configuration
        let optimizedConfig = DBSCANClusterer.ClusteringConfig(
            eps: 300.0,
            minPts: 3,
            maxClusteringTime: 0.100,
            logDetailedMetrics: true
        )

        let clusters = await dbscanClusterer.cluster(
            devices: devices,
            config: optimizedConfig,
            spatialManager: spatialManager
        )

        performanceMetrics.clusterCount = clusters.count

        let hullProgress = progressRange.start + (progressRange.end - progressRange.start) * 0.8
        await updateProgress(hullProgress, status: "Generating optimized hulls...")

        // Use optimized hull generation
        let hullResults = await hullGenerator.generateHullsBatchWithConcurrencyLimit(
            clusters: clusters,
            maxConcurrency: 6
        )

        return convertHullsToPolygons(hullResults, originalClusters: clusters)
    }

    private func generatePolygonsHighPerformance(
        devices: [PowerSenseDevice],
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        await updateProgress(progressRange.start + 0.2, status: "High-performance parallel clustering...")

        // Use high-performance configuration with parallel processing
        let highPerfConfig = DBSCANClusterer.ClusteringConfig(
            eps: 400.0,
            minPts: 5,
            maxClusteringTime: 0.200,
            logDetailedMetrics: integrationConfig.performanceMonitoringEnabled
        )

        // Split devices into batches for parallel processing
        let deviceBatches = devices.chunked(into: 4)
        let batchResults = await DBSCANClusterer.clusterBatch(
            deviceSets: deviceBatches,
            config: highPerfConfig,
            spatialManager: spatialManager
        )

        // Combine clusters from all batches
        let allClusters = batchResults.flatMap { $0 }
        performanceMetrics.clusterCount = allClusters.count

        await updateProgress(progressRange.start + 0.7, status: "High-performance hull generation...")

        // Use maximum concurrency for hull generation
        let hullResults = await hullGenerator.generateHullsBatchWithConcurrencyLimit(
            clusters: allClusters,
            maxConcurrency: 8
        )

        return convertHullsToPolygons(hullResults, originalClusters: allClusters)
    }

    private func generatePolygonsLegacy(
        devices: [PowerSenseDevice],
        progressRange: (start: Double, end: Double)
    ) async -> [OutagePolygon] {

        await updateProgress(progressRange.start + 0.5, status: "Legacy polygon generation...")

        // Convert to legacy format and use existing system
        let deviceData = devices.map { DeviceData(from: $0) }
        return await legacyHullGenerator.generateOutagePolygons(deviceData)
    }

    // MARK: - Utility Methods

    private func prepareDevicesForProcessing(_ devices: [PowerSenseDevice]) async -> [PowerSenseDevice] {
        // Filter to devices that can be processed
        return devices.filter { device in
            device.canAggregate &&
            device.latitude >= -90 && device.latitude <= 90 &&
            device.longitude >= -180 && device.longitude <= 180
        }
    }

    private func initializeSpatialIndex(with devices: [PowerSenseDevice]) async {
        await spatialManager.initializeQuadTree(with: devices)
    }

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

    private func calculateClusterConfidence(_ deviceData: [DeviceData]) -> Double {
        // Simple confidence calculation based on device count and offline ratio
        let offlineCount = deviceData.filter { $0.isOffline == true }.count
        let totalCount = deviceData.count

        guard totalCount > 0 else { return 0.0 }

        let offlineRatio = Double(offlineCount) / Double(totalCount)
        let sizeBonus = min(1.0, Double(totalCount) / 10.0) * 0.2
        let baseConfidence = offlineRatio * 0.8

        return min(1.0, baseConfidence + sizeBonus)
    }

    private func fallbackToLegacySystem(devices: [PowerSenseDevice]) async -> [OutagePolygon] {
        integrationLogger.warning("🔄 Falling back to legacy polygon generation")
        let deviceData = devices.map { DeviceData(from: $0) }
        return await legacyHullGenerator.generateOutagePolygons(deviceData)
    }

    // MARK: - Progress Management

    private func updateProgress(_ progress: Double, status: String) async {
        await MainActor.run {
            self.processingProgress = max(0.0, min(1.0, progress))
            self.processingStatus = status
        }

        debugLogger.debug("📊 Integration Progress: \(Int(progress * 100))% - \(status)")
        await Task.yield()
    }

    // MARK: - Performance Monitoring

    private func setupPerformanceMonitoring() {
        guard integrationConfig.performanceMonitoringEnabled else { return }

        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePerformanceMetrics()
            }
        }
    }

    private func updatePerformanceMetrics() async {
        performanceMetrics.memoryUsageMB = await estimateMemoryUsage()

        if performanceMetrics.memoryUsageMB > 100.0 {
            performanceLogger.warning("⚠️ High memory usage: \(String(format: "%.1f", performanceMetrics.memoryUsageMB))MB")
        }
    }

    private func estimateMemoryUsage() async -> Double {
        // Estimate memory usage from polygon count and spatial index
        let polygonMemory = Double(outagePolygons.count) * 0.5 // ~0.5KB per polygon
        let spatialMemory = Double(performanceMetrics.deviceCount) * 0.1 // ~0.1KB per device in spatial index
        return polygonMemory + spatialMemory
    }

    // MARK: - Public Interface for UI

    /// Get current render manager for MapKit integration
    public var polygonRenderManager: PolygonRenderManager {
        return renderManager
    }

    /// Get performance statistics for UI display
    public var currentPerformanceMetrics: IntegrationPerformanceMetrics {
        return performanceMetrics
    }

    /// Clear all polygons and reset state
    public func clearPolygons() {
        outagePolygons.removeAll()
        renderManager.clearPolygons()
        integrationLogger.info("🗑️ All polygons cleared")
    }
}

// MARK: - Array Extensions

extension Array {
    /// Split array into chunks of specified size
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}