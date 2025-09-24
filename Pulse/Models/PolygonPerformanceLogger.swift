//
//  PolygonPerformanceLogger.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Comprehensive performance logging for utility-grade polygon processing
//

import Foundation
import OSLog
import CoreLocation

/// Comprehensive performance logging system for polygon processing pipeline
actor PolygonPerformanceLogger {

    private let logger = Logger(subsystem: "powersense.performance", category: "polygonProcessing")
    private let memoryLogger = Logger(subsystem: "powersense.performance", category: "memoryUsage")
    private let qualityLogger = Logger(subsystem: "powersense.performance", category: "polygonQuality")

    // MARK: - Performance Tracking

    private var sessionStartTime: Date = Date()
    private var phaseTimings: [String: TimeInterval] = [:]
    private var cumulativeStats = CumulativePerformanceStats()

    // MARK: - Session Management

    /// Start a new polygon processing session
    func startProcessingSession(deviceCount: Int, viewport: String) {
        sessionStartTime = Date()
        phaseTimings.removeAll()

        logger.info("""
        🚀 POLYGON PROCESSING SESSION STARTED
        =====================================
        • Device Count: \(deviceCount)
        • Viewport: \(viewport)
        • Session ID: \(sessionStartTime.timeIntervalSince1970, format: .fixed(precision: 3))
        • Memory Footprint: \(getCurrentMemoryUsage()) MB
        • Timestamp: \(sessionStartTime.formatted(.dateTime.hour().minute().second()))
        """)
    }

    /// End polygon processing session with summary
    func endProcessingSession(resultCount: Int, totalVertices: Int) {
        let totalTime = Date().timeIntervalSince(sessionStartTime)

        // Update cumulative stats
        cumulativeStats.totalSessions += 1
        cumulativeStats.totalProcessingTime += totalTime
        cumulativeStats.totalPolygonsGenerated += resultCount
        cumulativeStats.totalVerticesProcessed += totalVertices

        let avgTime = cumulativeStats.totalProcessingTime / Double(cumulativeStats.totalSessions)

        logger.info("""
        🎯 POLYGON PROCESSING SESSION COMPLETED
        =======================================
        • Total Time: \(String(format: "%.3f", totalTime))s
        • Generated Polygons: \(resultCount)
        • Total Vertices: \(totalVertices)
        • Vertices/Polygon: \(resultCount > 0 ? totalVertices / resultCount : 0)
        • Processing Rate: \(String(format: "%.1f", Double(resultCount) / totalTime)) polygons/sec
        • Memory Peak: \(getCurrentMemoryUsage()) MB

        📊 CUMULATIVE SESSION STATS:
        • Total Sessions: \(cumulativeStats.totalSessions)
        • Average Time: \(String(format: "%.3f", avgTime))s
        • Total Polygons: \(cumulativeStats.totalPolygonsGenerated)
        • Efficiency Trend: \(getEfficiencyTrend())
        """)
    }

    // MARK: - Phase Timing

    /// Start timing a specific processing phase
    func startPhase(_ phaseName: String, details: String = "") {
        let startTime = Date()
        phaseTimings["\(phaseName)_start"] = startTime.timeIntervalSince1970

        logger.debug("⏱️ Phase START: \(phaseName) \(details.isEmpty ? "" : "- \(details)")")
    }

    /// End timing a specific processing phase
    func endPhase(_ phaseName: String, itemCount: Int = 0, details: String = "") {
        let endTime = Date()
        let startKey = "\(phaseName)_start"

        guard let startTime = phaseTimings[startKey] else {
            logger.warning("⚠️ Phase END called without START: \(phaseName)")
            return
        }

        let duration = endTime.timeIntervalSince1970 - startTime
        phaseTimings[phaseName] = duration
        phaseTimings.removeValue(forKey: startKey)

        let itemRate = itemCount > 0 ? Double(itemCount) / duration : 0

        logger.info("""
        ✅ Phase COMPLETE: \(phaseName)
        • Duration: \(String(format: "%.3f", duration))s
        • Items Processed: \(itemCount)
        • Processing Rate: \(itemCount > 0 ? String(format: "%.1f", itemRate) + " items/sec" : "N/A")
        • Memory Usage: \(getCurrentMemoryUsage()) MB
        \(details.isEmpty ? "" : "• Details: \(details)")
        """)
    }

    // MARK: - Detailed Performance Metrics

    /// Log spatial clustering performance
    func logSpatialClustering(
        inputDevices: Int,
        outputClusters: Int,
        gridCells: Int,
        processing: TimeInterval
    ) {
        let clusteringEfficiency = Double(inputDevices) / Double(outputClusters)

        logger.info("""
        🗂️ SPATIAL CLUSTERING METRICS:
        • Input Devices: \(inputDevices)
        • Output Clusters: \(outputClusters)
        • Grid Cells Used: \(gridCells)
        • Processing Time: \(String(format: "%.3f", processing))s
        • Clustering Efficiency: \(String(format: "%.1f", clusteringEfficiency))x reduction
        • Devices/Second: \(String(format: "%.0f", Double(inputDevices) / processing))
        """)
    }

    /// Log hull generation performance with quality metrics
    func logHullGeneration(
        clusterSize: Int,
        inputPoints: Int,
        outputVertices: Int,
        alpha: Double,
        processing: TimeInterval,
        qualityScore: Double
    ) {
        let vertexReduction = Double(inputPoints - outputVertices) / Double(inputPoints) * 100

        logger.info("""
        🔷 HULL GENERATION METRICS:
        • Cluster Size: \(clusterSize) devices
        • Input Points: \(inputPoints) (buffered)
        • Output Vertices: \(outputVertices)
        • Alpha Parameter: \(String(format: "%.3f", alpha))
        • Processing Time: \(String(format: "%.3f", processing))s
        • Vertex Reduction: \(String(format: "%.1f", vertexReduction))%
        • Quality Score: \(String(format: "%.2f", qualityScore))/1.0
        • Points/Second: \(String(format: "%.0f", Double(inputPoints) / processing))
        """)
    }

    /// Log polygon merging performance
    func logPolygonMerging(
        inputPolygons: Int,
        outputPolygons: Int,
        totalOverlaps: Int,
        mergingTime: TimeInterval,
        unionComplexity: Int
    ) {
        let reductionRate = Double(inputPolygons - outputPolygons) / Double(inputPolygons) * 100

        logger.info("""
        🔗 POLYGON MERGING METRICS:
        • Input Polygons: \(inputPolygons)
        • Output Polygons: \(outputPolygons)
        • Overlaps Detected: \(totalOverlaps)
        • Union Operations: \(unionComplexity)
        • Processing Time: \(String(format: "%.3f", mergingTime))s
        • Reduction Rate: \(String(format: "%.1f", reductionRate))%
        • Merges/Second: \(String(format: "%.1f", Double(totalOverlaps) / mergingTime))
        """)
    }

    // MARK: - Memory Usage Monitoring

    /// Log current memory usage with context
    func logMemoryUsage(_ context: String, threshold: Double = 100.0) {
        let currentUsage = getCurrentMemoryUsage()

        if currentUsage > threshold {
            memoryLogger.warning("""
            ⚠️ HIGH MEMORY USAGE - \(context)
            • Current Usage: \(String(format: "%.1f", currentUsage)) MB
            • Threshold: \(String(format: "%.1f", threshold)) MB
            • Recommendation: Consider viewport filtering or chunked processing
            """)
        } else {
            memoryLogger.info("💾 Memory Usage - \(context): \(String(format: "%.1f", currentUsage)) MB")
        }
    }

    /// Get current memory usage in MB
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

    // MARK: - Quality Metrics

    /// Log polygon quality metrics for utility-grade validation
    func logPolygonQuality(
        polygonId: UUID,
        vertices: Int,
        area: Double,
        perimeterLength: Double,
        deviceEnclosure: Double,
        convexityRatio: Double,
        smoothnessScore: Double
    ) {
        qualityLogger.info("""
        🎯 POLYGON QUALITY ASSESSMENT:
        • Polygon ID: \(polygonId.uuidString.prefix(8))
        • Vertices: \(vertices)
        • Area: \(String(format: "%.6f", area)) deg²
        • Perimeter: \(String(format: "%.6f", perimeterLength)) deg
        • Device Enclosure: \(String(format: "%.1f", deviceEnclosure * 100))%
        • Convexity Ratio: \(String(format: "%.3f", convexityRatio))
        • Smoothness: \(String(format: "%.3f", smoothnessScore))/1.0
        • Quality Grade: \(getQualityGrade(convexityRatio, smoothnessScore, deviceEnclosure))
        """)
    }

    /// Log aggregate quality statistics for the session
    func logAggregateQuality(_ polygons: [QualityMetric]) {
        let avgVertices = polygons.map { $0.vertices }.reduce(0, +) / polygons.count
        let avgArea = polygons.map { $0.area }.reduce(0, +) / Double(polygons.count)
        let avgEnclosure = polygons.map { $0.deviceEnclosure }.reduce(0, +) / Double(polygons.count)
        let avgConvexity = polygons.map { $0.convexityRatio }.reduce(0, +) / Double(polygons.count)
        let avgSmoothness = polygons.map { $0.smoothnessScore }.reduce(0, +) / Double(polygons.count)

        let qualityDistribution = calculateQualityDistribution(polygons)

        qualityLogger.info("""
        📊 AGGREGATE QUALITY METRICS:
        • Total Polygons: \(polygons.count)
        • Average Vertices: \(avgVertices)
        • Average Area: \(String(format: "%.6f", avgArea)) deg²
        • Average Device Enclosure: \(String(format: "%.1f", avgEnclosure * 100))%
        • Average Convexity: \(String(format: "%.3f", avgConvexity))
        • Average Smoothness: \(String(format: "%.3f", avgSmoothness))

        🏆 QUALITY DISTRIBUTION:
        • Excellent: \(qualityDistribution.excellent) (\(String(format: "%.1f", Double(qualityDistribution.excellent) / Double(polygons.count) * 100))%)
        • Good: \(qualityDistribution.good) (\(String(format: "%.1f", Double(qualityDistribution.good) / Double(polygons.count) * 100))%)
        • Fair: \(qualityDistribution.fair) (\(String(format: "%.1f", Double(qualityDistribution.fair) / Double(polygons.count) * 100))%)
        • Poor: \(qualityDistribution.poor) (\(String(format: "%.1f", Double(qualityDistribution.poor) / Double(polygons.count) * 100))%)
        """)
    }

    // MARK: - Performance Warnings and Alerts

    /// Log performance warning when thresholds are exceeded
    func logPerformanceWarning(_ warning: PerformanceWarning) {
        switch warning.severity {
        case .info:
            logger.info("ℹ️ PERFORMANCE INFO: \(warning.message)")
        case .warning:
            logger.warning("⚠️ PERFORMANCE WARNING: \(warning.message)")
        case .critical:
            logger.error("🔥 CRITICAL PERFORMANCE ISSUE: \(warning.message)")
        }

        if !warning.recommendations.isEmpty {
            logger.info("💡 RECOMMENDATIONS:")
            warning.recommendations.forEach { recommendation in
                logger.info("  • \(recommendation)")
            }
        }
    }

    /// Check and log performance thresholds
    func checkPerformanceThresholds(
        processingTime: TimeInterval,
        deviceCount: Int,
        polygonCount: Int,
        memoryUsage: Double
    ) {
        var warnings: [PerformanceWarning] = []

        // Processing time thresholds
        let timePerDevice = processingTime / Double(deviceCount)
        if timePerDevice > 0.01 { // > 10ms per device
            warnings.append(PerformanceWarning(
                severity: .warning,
                message: "High processing time: \(String(format: "%.3f", timePerDevice * 1000))ms per device",
                recommendations: [
                    "Consider implementing spatial indexing",
                    "Reduce hull detail level for large datasets",
                    "Implement viewport-based filtering"
                ]
            ))
        }

        // Memory usage thresholds
        if memoryUsage > 200 {
            warnings.append(PerformanceWarning(
                severity: .critical,
                message: "High memory usage: \(String(format: "%.1f", memoryUsage)) MB",
                recommendations: [
                    "Implement chunked processing",
                    "Reduce buffer point density",
                    "Clear unused polygon data"
                ]
            ))
        }

        // Polygon complexity thresholds
        let avgVerticesPerPolygon = polygonCount > 0 ? Double(deviceCount) / Double(polygonCount) : 0
        if avgVerticesPerPolygon > 100 {
            warnings.append(PerformanceWarning(
                severity: .info,
                message: "High polygon complexity: \(String(format: "%.1f", avgVerticesPerPolygon)) avg vertices",
                recommendations: [
                    "Polygon simplification is working well",
                    "Monitor MapKit rendering performance"
                ]
            ))
        }

        warnings.forEach { logPerformanceWarning($0) }
    }

    // MARK: - Utility Methods

    private func getEfficiencyTrend() -> String {
        guard cumulativeStats.totalSessions > 1 else { return "Insufficient data" }

        let avgTime = cumulativeStats.totalProcessingTime / Double(cumulativeStats.totalSessions)
        let avgPolygons = Double(cumulativeStats.totalPolygonsGenerated) / Double(cumulativeStats.totalSessions)
        let efficiency = avgPolygons / avgTime

        if efficiency > 10 { return "Excellent (>10 polygons/sec)" }
        else if efficiency > 5 { return "Good (5-10 polygons/sec)" }
        else if efficiency > 2 { return "Fair (2-5 polygons/sec)" }
        else { return "Needs optimization (<2 polygons/sec)" }
    }

    private func getQualityGrade(_ convexity: Double, _ smoothness: Double, _ enclosure: Double) -> String {
        let score = (convexity + smoothness + enclosure) / 3.0
        if score > 0.9 { return "A+ (Utility Grade)" }
        else if score > 0.8 { return "A (Excellent)" }
        else if score > 0.7 { return "B (Good)" }
        else if score > 0.6 { return "C (Fair)" }
        else { return "D (Needs Improvement)" }
    }

    private func calculateQualityDistribution(_ polygons: [QualityMetric]) -> QualityDistribution {
        var distribution = QualityDistribution()

        for polygon in polygons {
            let score = (polygon.convexityRatio + polygon.smoothnessScore + polygon.deviceEnclosure) / 3.0

            if score > 0.8 { distribution.excellent += 1 }
            else if score > 0.7 { distribution.good += 1 }
            else if score > 0.6 { distribution.fair += 1 }
            else { distribution.poor += 1 }
        }

        return distribution
    }
}

// MARK: - Supporting Data Structures

struct CumulativePerformanceStats {
    var totalSessions: Int = 0
    var totalProcessingTime: TimeInterval = 0
    var totalPolygonsGenerated: Int = 0
    var totalVerticesProcessed: Int = 0
}

struct PerformanceWarning {
    let severity: Severity
    let message: String
    let recommendations: [String]

    enum Severity {
        case info, warning, critical
    }
}

struct QualityMetric {
    let vertices: Int
    let area: Double
    let deviceEnclosure: Double
    let convexityRatio: Double
    let smoothnessScore: Double
}

struct QualityDistribution {
    var excellent: Int = 0
    var good: Int = 0
    var fair: Int = 0
    var poor: Int = 0
}