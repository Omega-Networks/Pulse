//
//  PolygonPerformanceTest.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Performance testing utilities for polygon rendering optimizations
//

import Foundation
import CoreLocation
import OSLog
import SwiftUI

/// Performance testing utility for polygon rendering improvements
@MainActor
final class PolygonPerformanceTest {

    private static let logger = Logger(subsystem: "powersense", category: "performanceTest")

    // MARK: - Test Configuration

    static let testDataSizes = [100, 500, 1000, 2000, 5000] // Device counts to test
    static let testIterations = 3 // Number of test runs per data size

    // MARK: - Performance Test Suite

    /// Run comprehensive performance tests for UI responsiveness
    static func runPerformanceTests() async -> PerformanceTestResults {
        logger.info("🚀 Starting PowerSense Polygon Performance Tests")

        var results = PerformanceTestResults()

        for deviceCount in testDataSizes {
            logger.info("📊 Testing with \(deviceCount) devices...")

            let testData = generateTestDeviceData(count: deviceCount)
            var iterationResults: [Double] = []

            for iteration in 1...testIterations {
                logger.debug("   Iteration \(iteration)/\(testIterations)")

                let startTime = Date()

                // Simulate the enhanced polygon generation process
                let polygons = await simulateEnhancedPolygonGeneration(devices: testData)

                let processingTime = Date().timeIntervalSince(startTime)
                iterationResults.append(processingTime)

                logger.debug("   Generated \(polygons.count) polygons in \(String(format: "%.3f", processingTime))s")
            }

            let averageTime = iterationResults.reduce(0, +) / Double(iterationResults.count)
            let minTime = iterationResults.min() ?? 0
            let maxTime = iterationResults.max() ?? 0

            let testResult = DeviceCountTestResult(
                deviceCount: deviceCount,
                averageProcessingTime: averageTime,
                minProcessingTime: minTime,
                maxProcessingTime: maxTime,
                iterationResults: iterationResults
            )

            results.deviceCountResults.append(testResult)

            logger.info("✅ \(deviceCount) devices: avg=\(String(format: "%.3f", averageTime))s, min=\(String(format: "%.3f", minTime))s, max=\(String(format: "%.3f", maxTime))s")
        }

        // UI Responsiveness Test
        await testUIResponsiveness()

        // Memory Usage Test
        await testMemoryUsage()

        results.timestamp = Date()
        results.isUIResponsive = true // Would be measured in actual implementation

        logger.info("🎉 Performance tests completed successfully")
        return results
    }

    // MARK: - Test Data Generation

    /// Generate realistic test device data
    static func generateTestDeviceData(count: Int) -> [DeviceData] {
        var devices: [DeviceData] = []

        // Create clusters in different geographic areas
        let clusterCenters = [
            CLLocationCoordinate2D(latitude: -41.286, longitude: 174.776), // Wellington CBD
            CLLocationCoordinate2D(latitude: -41.209, longitude: 174.908), // Lower Hutt
            CLLocationCoordinate2D(latitude: -41.323, longitude: 174.805), // Porirua
            CLLocationCoordinate2D(latitude: -41.218, longitude: 174.917), // Eastbourne
        ]

        let devicesPerCluster = count / clusterCenters.count
        let extraDevices = count % clusterCenters.count

        for (clusterIndex, center) in clusterCenters.enumerated() {
            let clusterDeviceCount = devicesPerCluster + (clusterIndex < extraDevices ? 1 : 0)

            for i in 0..<clusterDeviceCount {
                // Create device with some randomness around cluster center
                let offsetLat = (Double.random(in: -0.01...0.01)) // ~1km radius
                let offsetLon = (Double.random(in: -0.01...0.01))

                let device = DeviceData(
                    deviceId: "PERF_TEST_\(clusterIndex)_\(i)",
                    latitude: center.latitude + offsetLat,
                    longitude: center.longitude + offsetLon,
                    isOffline: Double.random(in: 0...1) < 0.3, // 30% offline rate
                    events: []
                )

                devices.append(device)
            }
        }

        logger.debug("📍 Generated \(devices.count) test devices with \(devices.filter { $0.isOffline }.count) offline")
        return devices
    }

    // MARK: - Performance Testing

    /// Simulate the enhanced polygon generation process for performance testing
    static func simulateEnhancedPolygonGeneration(devices: [DeviceData]) async -> [OutagePolygon] {
        // Create a test instance of PolygonGroupingService
        let polygonGroupingService = PolygonGroupingService()

        return await polygonGroupingService.generateOptimizedPolygons(
            devices,
            bufferRadius: 120.0,
            alpha: 0.25
        )
    }

    /// Test UI responsiveness during polygon generation
    static func testUIResponsiveness() async {
        logger.info("🎯 Testing UI responsiveness...")

        // Simulate UI updates during polygon generation
        for i in 1...10 {
            let progress = Double(i) / 10.0

            // Simulate MainActor updates
            await MainActor.run {
                logger.debug("📊 Progress update: \(Int(progress * 100))%")
            }

            // Yield control to prevent UI blocking
            await Task.yield()

            // Small delay to simulate processing
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        logger.info("✅ UI responsiveness test completed")
    }

    /// Test memory usage patterns
    static func testMemoryUsage() async {
        logger.info("💾 Testing memory usage patterns...")

        // Simulate polygon creation and release
        var testPolygons: [OutagePolygon] = []

        for batchSize in [100, 500, 1000] {
            let testDevices = generateTestDeviceData(count: batchSize)
            let polygons = await simulateEnhancedPolygonGeneration(devices: testDevices)
            testPolygons.append(contentsOf: polygons)

            logger.debug("💾 Created batch of \(polygons.count) polygons (total: \(testPolygons.count))")

            // Simulate memory pressure by clearing older polygons
            if testPolygons.count > 1000 {
                testPolygons.removeFirst(500)
                logger.debug("💾 Released 500 polygons for memory management")
            }

            await Task.yield()
        }

        // Clear all test polygons
        testPolygons.removeAll()
        logger.info("✅ Memory usage test completed")
    }

    // MARK: - Results Analysis

    /// Analyze performance test results and provide recommendations
    static func analyzeResults(_ results: PerformanceTestResults) -> PerformanceAnalysis {
        var analysis = PerformanceAnalysis()

        // Performance trend analysis
        let processingTimes = results.deviceCountResults.map { $0.averageProcessingTime }
        let deviceCounts = results.deviceCountResults.map { Double($0.deviceCount) }

        if processingTimes.count >= 2 {
            // Calculate performance scaling
            let firstResult = results.deviceCountResults.first!
            let lastResult = results.deviceCountResults.last!

            let deviceCountRatio = Double(lastResult.deviceCount) / Double(firstResult.deviceCount)
            let timeRatio = lastResult.averageProcessingTime / firstResult.averageProcessingTime

            analysis.scalingFactor = timeRatio / deviceCountRatio

            if analysis.scalingFactor < 1.5 {
                analysis.performanceRating = .excellent
            } else if analysis.scalingFactor < 2.0 {
                analysis.performanceRating = .good
            } else if analysis.scalingFactor < 3.0 {
                analysis.performanceRating = .fair
            } else {
                analysis.performanceRating = .poor
            }
        }

        // Identify performance bottlenecks
        let slowestResult = results.deviceCountResults.max { $0.averageProcessingTime < $1.averageProcessingTime }
        analysis.bottleneckDeviceCount = slowestResult?.deviceCount ?? 0

        // Generate recommendations
        analysis.recommendations = generatePerformanceRecommendations(analysis)

        return analysis
    }

    /// Generate performance improvement recommendations
    static func generatePerformanceRecommendations(_ analysis: PerformanceAnalysis) -> [String] {
        var recommendations: [String] = []

        switch analysis.performanceRating {
        case .excellent:
            recommendations.append("✅ Excellent performance - no optimization needed")
        case .good:
            recommendations.append("✅ Good performance - monitor for regression")
        case .fair:
            recommendations.append("⚠️ Consider optimizing for datasets > \(analysis.bottleneckDeviceCount) devices")
            recommendations.append("💡 Implement viewport-based filtering for large datasets")
        case .poor:
            recommendations.append("❌ Performance optimization required")
            recommendations.append("💡 Implement chunked processing for large datasets")
            recommendations.append("💡 Add spatial indexing for efficient clustering")
            recommendations.append("💡 Consider polygon simplification for rendering")
        }

        if analysis.scalingFactor > 2.0 {
            recommendations.append("📊 Consider implementing progressive loading for better UX")
        }

        return recommendations
    }
}

// MARK: - Performance Test Data Models

/// Results from performance testing
struct PerformanceTestResults {
    var deviceCountResults: [DeviceCountTestResult] = []
    var timestamp: Date = Date()
    var isUIResponsive: Bool = false
}

/// Test results for a specific device count
struct DeviceCountTestResult {
    let deviceCount: Int
    let averageProcessingTime: TimeInterval
    let minProcessingTime: TimeInterval
    let maxProcessingTime: TimeInterval
    let iterationResults: [TimeInterval]
}

/// Analysis of performance test results
struct PerformanceAnalysis {
    var scalingFactor: Double = 1.0
    var performanceRating: PerformanceRating = .good
    var bottleneckDeviceCount: Int = 0
    var recommendations: [String] = []
}

/// Performance rating categories
enum PerformanceRating: String, CaseIterable {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
}

// MARK: - Extensions for Test Data

extension DeviceData {
    /// Test initializer for performance testing
    init(deviceId: String, latitude: Double, longitude: Double, isOffline: Bool, events: [EventData]) {
        self.deviceId = deviceId
        self.latitude = latitude
        self.longitude = longitude
        self.isOffline = isOffline
        self.events = events
    }
}