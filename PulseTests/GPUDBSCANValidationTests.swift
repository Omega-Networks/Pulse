//
//  GPUDBSCANValidationTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
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

import XCTest
import Foundation
import MapKit
import CoreLocation
@testable import Pulse

final class GPUDBSCANValidationTests: XCTestCase {

    private var transformer: CoordinateTransformer!

    override func setUp() async throws {
        try await super.setUp()
        transformer = try CoordinateTransformer(projectionSystem: .nztm2000)
        print("🚀 Initialized CoordinateTransformer for GPU DBSCAN validation")
    }

    override func tearDown() async throws {
        transformer = nil
        try await super.tearDown()
    }

    // MARK: - Phase 2 Step-by-Step Validations

    /// Test 1: Validate DBSCAN buffer creation and initialization
    func testDBSCANBufferCreation() async throws {
        print("🧪 Testing DBSCAN buffer creation...")

        let deviceCount = 100
        let dbscanBuffers = try transformer.createDBSCANBuffers(deviceCount: deviceCount)

        // Validate buffer initialization
        let labelsPointer = dbscanBuffers.clusterLabels.contents().bindMemory(to: Int32.self, capacity: deviceCount)
        let labels = Array(UnsafeBufferPointer(start: labelsPointer, count: deviceCount))

        let corePointsPointer = dbscanBuffers.corePoints.contents().bindMemory(to: Bool.self, capacity: deviceCount)
        let corePoints = Array(UnsafeBufferPointer(start: corePointsPointer, count: deviceCount))

        let neighborCountsPointer = dbscanBuffers.neighborCounts.contents().bindMemory(to: Int32.self, capacity: deviceCount)
        let neighborCounts = Array(UnsafeBufferPointer(start: neighborCountsPointer, count: deviceCount))

        // Assert proper initialization
        XCTAssertEqual(labels.count, deviceCount, "Labels buffer should have correct size")
        XCTAssertEqual(corePoints.count, deviceCount, "Core points buffer should have correct size")
        XCTAssertEqual(neighborCounts.count, deviceCount, "Neighbor counts buffer should have correct size")

        // Check initial values
        XCTAssertTrue(labels.allSatisfy { $0 == -1 }, "All labels should be initialized to -1 (noise)")
        XCTAssertTrue(corePoints.allSatisfy { !$0 }, "All core points should be initialized to false")
        XCTAssertTrue(neighborCounts.allSatisfy { $0 == 0 }, "All neighbor counts should be initialized to 0")

        print("   ✅ Buffer creation validation passed")
    }

    /// Test 2: Validate neighbor search kernel with known cluster data
    func testNeighborSearchKernel() async throws {
        print("🧪 Testing neighbor search kernel...")

        // Create test data with a clear cluster in Wellington
        let testDevices = createWellingtonTestCluster()
        print("   Created \(testDevices.count) test devices")

        // Build spatial index
        let spatialIndex = GPUSpatialIndexManager<MockSpatialDevice>(transformer: transformer)
        try await spatialIndex.buildIndex(devices: testDevices)

        // Get grid data from the spatial index for direct kernel testing
        guard let gridParams = await spatialIndex.getGridParameters(),
              let gpuGrid = await spatialIndex.getGPUGrid(),
              let coordsBuffer = await spatialIndex.getGPUCoordsBuffer(),
              let offlineFlagsBuffer = await spatialIndex.getGPUOfflineFlagsBuffer() else {
            XCTFail("Failed to get required GPU grid components")
            return
        }

        // Create DBSCAN buffers and parameters
        let dbscanBuffers = try transformer.createDBSCANBuffers(deviceCount: testDevices.count)
        let dbscanParams = DBSCANParameters(epsilon: 500.0, minPoints: 3, aggregationThreshold: 5)

        // Execute neighbor search kernel
        try transformer.executeDBSCANNeighborSearchKernel(
            coordsBuffer: coordsBuffer.buffer,
            offlineFlagsBuffer: offlineFlagsBuffer.buffer,
            grid: gpuGrid,
            gridParams: gridParams,
            dbscanParams: dbscanParams,
            dbscanBuffers: dbscanBuffers,
            deviceCount: testDevices.count
        )

        // Validate results
        let neighborCountsPointer = dbscanBuffers.neighborCounts.contents.bindMemory(to: Int32.self, capacity: testDevices.count)
        let neighborCounts = Array(UnsafeBufferPointer(start: neighborCountsPointer, count: testDevices.count))

        let corePointsPointer = dbscanBuffers.corePoints.contents.bindMemory(to: Bool.self, capacity: testDevices.count)
        let corePoints = Array(UnsafeBufferPointer(start: corePointsPointer, count: testDevices.count))

        // Count offline devices and core points
        let offlineDevices = testDevices.filter { $0.isOffline == true }
        let detectedCorePoints = corePoints.enumerated().filter { _, isCore in isCore }.count

        print("   Offline devices: \(offlineDevices.count)")
        print("   Detected core points: \(detectedCorePoints)")
        print("   Max neighbor count: \(neighborCounts.max() ?? 0)")

        // Assertions
        XCTAssertGreaterThan(detectedCorePoints, 0, "Should detect some core points in cluster")
        XCTAssertLessThanOrEqual(detectedCorePoints, offlineDevices.count, "Core points should not exceed offline devices")

        // Verify that core points have sufficient neighbors
        for (i, isCore) in corePoints.enumerated() {
            if isCore {
                XCTAssertGreaterThanOrEqual(neighborCounts[i], 3, "Core point should have at least minPoints neighbors")
            }
        }

        print("   ✅ Neighbor search kernel validation passed")
    }

    /// Test 3: Validate complete GPU DBSCAN pipeline with simple cluster
    func testCompleteGPUDBSCANPipeline() async throws {
        print("🧪 Testing complete GPU DBSCAN pipeline...")

        // Create simple test cluster
        let testDevices = createSimpleTestCluster()
        print("   Created test cluster with \(testDevices.count) devices")

        // Build spatial index
        let spatialIndex = GPUSpatialIndexManager<MockSpatialDevice>(transformer: transformer)
        try await spatialIndex.buildIndex(devices: testDevices)

        // Get required components
        guard let gridParams = await spatialIndex.getGridParameters(),
              let gpuGrid = await spatialIndex.getGPUGrid(),
              let coordsBuffer = await spatialIndex.getGPUCoordsBuffer(),
              let offlineFlagsBuffer = await spatialIndex.getGPUOfflineFlagsBuffer() else {
            XCTFail("Failed to get required GPU grid components")
            return
        }

        // Run complete DBSCAN pipeline
        let dbscanParams = DBSCANParameters(epsilon: 500.0, minPoints: 3, aggregationThreshold: 3)
        let startTime = CFAbsoluteTimeGetCurrent()

        let result = try transformer.performGPUDBSCAN(
            coordsBuffer: coordsBuffer.buffer,
            offlineFlagsBuffer: offlineFlagsBuffer.buffer,
            grid: gpuGrid,
            gridParams: gridParams,
            dbscanParams: dbscanParams,
            deviceCount: testDevices.count
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        // Validate results
        print("   Results: \(result.clusterCount) clusters, \(result.corePoints) core points, \(result.noisePoints) noise")
        print("   Processing time: \(String(format: "%.3f", processingTime * 1000))ms")
        print("   Iterations to convergence: \(result.iterations)")

        // Performance assertion
        XCTAssertLessThan(processingTime, 0.1, "GPU DBSCAN should complete in under 100ms for small dataset")

        // Correctness assertions
        XCTAssertGreaterThan(result.clusterCount, 0, "Should detect at least one cluster")
        XCTAssertGreaterThan(result.corePoints, 0, "Should detect core points")
        XCTAssertLessThan(result.iterations, 20, "Should converge in reasonable number of iterations")

        // Validate that cluster labels are consistent
        let offlineDevices = testDevices.filter { $0.isOffline == true }
        let validLabels = result.labels.enumerated().compactMap { i, label in
            testDevices[i].isOffline == true ? label : nil
        }.filter { $0 != -1 }

        if !validLabels.isEmpty {
            let uniqueClusters = Set(validLabels)
            XCTAssertEqual(uniqueClusters.count, result.clusterCount, "Cluster count should match unique labels")
        }

        print("   ✅ Complete pipeline validation passed")
    }

    /// Test 4: Validate edge cases
    func testEdgeCases() async throws {
        print("🧪 Testing edge cases...")

        // Test 4a: No offline devices
        print("   Testing no offline devices...")
        let onlineOnlyDevices = createOnlineOnlyDevices()
        let spatialIndex1 = GPUSpatialIndexManager<MockSpatialDevice>(transformer: transformer)
        try await spatialIndex1.buildIndex(devices: onlineOnlyDevices)

        guard let gridParams1 = await spatialIndex1.getGridParameters(),
              let gpuGrid1 = await spatialIndex1.getGPUGrid(),
              let coordsBuffer1 = await spatialIndex1.getGPUCoordsBuffer(),
              let offlineFlagsBuffer1 = await spatialIndex1.getGPUOfflineFlagsBuffer() else {
            XCTFail("Failed to get required GPU grid components for online-only test")
            return
        }

        let result1 = try transformer.performGPUDBSCAN(
            coordsBuffer: coordsBuffer1.buffer,
            offlineFlagsBuffer: offlineFlagsBuffer1.buffer,
            grid: gpuGrid1,
            gridParams: gridParams1,
            dbscanParams: DBSCANParameters(),
            deviceCount: onlineOnlyDevices.count
        )

        XCTAssertEqual(result1.clusterCount, 0, "No offline devices should result in zero clusters")
        XCTAssertEqual(result1.corePoints, 0, "No offline devices should result in zero core points")

        // Test 4b: Single offline device (should be noise)
        print("   Testing single offline device...")
        let singleOfflineDevices = createSingleOfflineDevice()
        let spatialIndex2 = GPUSpatialIndexManager<MockSpatialDevice>(transformer: transformer)
        try await spatialIndex2.buildIndex(devices: singleOfflineDevices)

        guard let gridParams2 = await spatialIndex2.getGridParameters(),
              let gpuGrid2 = await spatialIndex2.getGPUGrid(),
              let coordsBuffer2 = await spatialIndex2.getGPUCoordsBuffer(),
              let offlineFlagsBuffer2 = await spatialIndex2.getGPUOfflineFlagsBuffer() else {
            XCTFail("Failed to get required GPU grid components for single device test")
            return
        }

        let result2 = try transformer.performGPUDBSCAN(
            coordsBuffer: coordsBuffer2.buffer,
            offlineFlagsBuffer: offlineFlagsBuffer2.buffer,
            grid: gpuGrid2,
            gridParams: gridParams2,
            dbscanParams: DBSCANParameters(),
            deviceCount: singleOfflineDevices.count
        )

        XCTAssertEqual(result2.clusterCount, 0, "Single offline device should not form cluster")
        XCTAssertEqual(result2.noisePoints, 1, "Single offline device should be classified as noise")

        print("   ✅ Edge cases validation passed")
    }

    // MARK: - Test Data Generation

    private func createWellingtonTestCluster() -> [MockSpatialDevice] {
        var devices: [MockSpatialDevice] = []
        let wellingtonCenter = (-41.2924, 174.7787)

        // Create a tight cluster of offline devices in Wellington CBD
        for i in 0..<20 {
            let angle = Double(i) * 2.0 * Double.pi / 20.0
            let distance = Double.random(in: 100...300) // 100-300m radius

            let latOffset = (distance * cos(angle)) / 111000.0
            let lonOffset = (distance * sin(angle)) / (111000.0 * cos(wellingtonCenter.0 * Double.pi / 180.0))

            let device = MockSpatialDevice(
                deviceId: "wellington_cluster_\(i)",
                latitude: wellingtonCenter.0 + latOffset,
                longitude: wellingtonCenter.1 + lonOffset,
                isOffline: true
            )
            devices.append(device)
        }

        // Add some online devices (noise)
        for i in 0..<10 {
            let device = MockSpatialDevice(
                deviceId: "wellington_online_\(i)",
                latitude: wellingtonCenter.0 + Double.random(in: -0.01...0.01),
                longitude: wellingtonCenter.1 + Double.random(in: -0.01...0.01),
                isOffline: false
            )
            devices.append(device)
        }

        return devices
    }

    private func createSimpleTestCluster() -> [MockSpatialDevice] {
        var devices: [MockSpatialDevice] = []

        // Create a simple 3x3 grid of offline devices (should form one cluster)
        let baseLocation = (-41.2924, 174.7787) // Wellington

        for x in 0..<3 {
            for y in 0..<3 {
                let latOffset = Double(x) * 200.0 / 111000.0 // 200m spacing
                let lonOffset = Double(y) * 200.0 / (111000.0 * cos(baseLocation.0 * Double.pi / 180.0))

                let device = MockSpatialDevice(
                    deviceId: "grid_\(x)_\(y)",
                    latitude: baseLocation.0 + latOffset,
                    longitude: baseLocation.1 + lonOffset,
                    isOffline: true
                )
                devices.append(device)
            }
        }

        return devices
    }

    private func createOnlineOnlyDevices() -> [MockSpatialDevice] {
        var devices: [MockSpatialDevice] = []

        for i in 0..<10 {
            let device = MockSpatialDevice(
                deviceId: "online_only_\(i)",
                latitude: -41.2924 + Double.random(in: -0.01...0.01),
                longitude: 174.7787 + Double.random(in: -0.01...0.01),
                isOffline: false
            )
            devices.append(device)
        }

        return devices
    }

    private func createSingleOfflineDevice() -> [MockSpatialDevice] {
        let offlineDevice = MockSpatialDevice(
            deviceId: "single_offline",
            latitude: -41.2924,
            longitude: 174.7787,
            isOffline: true
        )

        let onlineDevice = MockSpatialDevice(
            deviceId: "single_online",
            latitude: -41.2925,
            longitude: 174.7788,
            isOffline: false
        )

        return [offlineDevice, onlineDevice]
    }
}

// MARK: - MockSpatialDevice for Testing

struct MockSpatialDevice: SpatialDevice, Sendable {
    let deviceId: String
    let latitude: Double
    let longitude: Double
    let isOffline: Bool?

    init(deviceId: String, latitude: Double, longitude: Double, isOffline: Bool?) {
        self.deviceId = deviceId
        self.latitude = latitude
        self.longitude = longitude
        self.isOffline = isOffline
    }
}