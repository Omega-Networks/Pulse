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

    // MARK: - Phase 3: Hull and Confidence Validation Tests

    /// Test Phase 3: Convex hull computation and validation
    func testConvexHullGeneration() async throws {
        print("🧪 Phase 3: Testing convex hull generation...")

        // Create irregular cluster (pentagon shape + internal points)
        let testDevices = createIrregularTestCluster()
        print("   Created \(testDevices.count) test devices in irregular pattern")

        let spatialIndex = GPUSpatialIndexManager<MockSpatialDevice>(transformer: transformer)
        try await spatialIndex.buildIndex(devices: testDevices)

        guard let gridParams = await spatialIndex.getGridParameters(),
              let gpuGrid = await spatialIndex.getGPUGrid(),
              let coordsBuffer = await spatialIndex.getGPUCoordsBuffer(),
              let offlineFlagsBuffer = await spatialIndex.getGPUOfflineFlagsBuffer() else {
            XCTFail("Failed to get required GPU components")
            return
        }

        // Mock cluster offsets (all devices in one cluster)
        let clusterOffsets: [Int32] = [0, Int32(testDevices.count)]

        // Perform GPU hull computation
        let hullResult = try transformer.performGPUHullAndConfidence(
            coordsBuffer: coordsBuffer.buffer,
            offlineFlagsBuffer: offlineFlagsBuffer.buffer,
            clusterOffsets: clusterOffsets,
            gridParams: gridParams,
            grid: gpuGrid,
            clusterCount: 1,
            maxPointsPerCluster: testDevices.count
        )

        print("   ✅ Hull computation completed in \(String(format: "%.1f", hullResult.totalTime * 1000))ms")

        // Validate hull results
        let hullCountsPointer = hullResult.hullBuffers.hullCounts.contents.bindMemory(to: Int32.self, capacity: 1)
        let hullCount = Int(hullCountsPointer[0])

        XCTAssertGreaterThan(hullCount, 2, "Hull should have at least 3 vertices")
        XCTAssertLessThanOrEqual(hullCount, testDevices.count, "Hull should not have more vertices than input points")

        // Validate convexity (all cross products should be positive for clockwise)
        let maxHullVertices = 100
        let hullVerticesPointer = hullResult.hullBuffers.hullVertices.contents.bindMemory(to: SIMD2<Float>.self, capacity: maxHullVertices)
        let hullVertices = Array(UnsafeBufferPointer(start: hullVerticesPointer, count: hullCount))

        var isConvex = true
        for i in 0..<hullCount {
            let p1 = hullVertices[i]
            let p2 = hullVertices[(i + 1) % hullCount]
            let p3 = hullVertices[(i + 2) % hullCount]

            let cross = (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x)
            if cross <= 0 {
                isConvex = false
                print("   ⚠️ Non-convex turn at vertex \(i): cross = \(cross)")
            }
        }

        XCTAssertTrue(isConvex, "Hull should be convex (all turns should be in same direction)")
        print("   ✅ Hull convexity validation passed")

        // Validate hull area is reasonable (should be smaller than bounding box)
        let hullArea = calculatePolygonArea(hullVertices.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
        XCTAssertGreaterThan(hullArea, 0, "Hull should have positive area")

        print("   📊 Hull metrics: \(hullCount) vertices, area: \(String(format: "%.3f", hullArea))")
    }

    /// Test Phase 3: Confidence score calculation
    func testConfidenceCalculation() async throws {
        print("🧪 Phase 3: Testing confidence calculation...")

        let testDevices = createDenseOfflineCluster()
        print("   Created \(testDevices.count) devices for confidence testing")

        let spatialIndex = GPUSpatialIndexManager<MockSpatialDevice>(transformer: transformer)
        try await spatialIndex.buildIndex(devices: testDevices)

        guard let gridParams = await spatialIndex.getGridParameters(),
              let gpuGrid = await spatialIndex.getGPUGrid(),
              let coordsBuffer = await spatialIndex.getGPUCoordsBuffer(),
              let offlineFlagsBuffer = await spatialIndex.getGPUOfflineFlagsBuffer() else {
            XCTFail("Failed to get required GPU components")
            return
        }

        let clusterOffsets: [Int32] = [0, Int32(testDevices.count)]

        let hullResult = try transformer.performGPUHullAndConfidence(
            coordsBuffer: coordsBuffer.buffer,
            offlineFlagsBuffer: offlineFlagsBuffer.buffer,
            clusterOffsets: clusterOffsets,
            gridParams: gridParams,
            grid: gpuGrid,
            clusterCount: 1,
            maxPointsPerCluster: testDevices.count
        )

        // Validate confidence scores
        let confidencePairsPointer = hullResult.hullBuffers.confidencePairs.contents.bindMemory(to: SIMD2<Float>.self, capacity: 1)
        let confidencePair = confidencePairsPointer[0]

        let offlineCount = Int(confidencePair.x)
        let totalCount = Int(confidencePair.y)
        let confidence = totalCount > 0 ? Double(offlineCount) / Double(totalCount) : 0.0

        XCTAssertGreaterThan(offlineCount, 0, "Should find offline devices")
        XCTAssertGreaterThanOrEqual(totalCount, offlineCount, "Total should be >= offline count")
        XCTAssertGreaterThanOrEqual(confidence, 0.0, "Confidence should be non-negative")
        XCTAssertLessThanOrEqual(confidence, 1.0, "Confidence should not exceed 1.0")

        // For dense offline cluster, confidence should be high
        XCTAssertGreaterThan(confidence, 0.8, "Dense offline cluster should have high confidence")

        print("   📊 Confidence metrics: \(offlineCount)/\(totalCount) = \(String(format: "%.3f", confidence))")
        print("   ✅ Confidence calculation validation passed")
    }

    /// Test Phase 3: End-to-end performance validation
    func testPhase3Performance() async throws {
        print("🧪 Phase 3: Testing end-to-end performance...")

        // Create large test dataset
        let testDevices = createLargeTestDataset(deviceCount: 1000)
        print("   Created \(testDevices.count) devices for performance testing")

        let startTime = CFAbsoluteTimeGetCurrent()

        let spatialIndex = GPUSpatialIndexManager<MockSpatialDevice>(transformer: transformer)
        try await spatialIndex.buildIndex(devices: testDevices)

        guard let gridParams = await spatialIndex.getGridParameters(),
              let gpuGrid = await spatialIndex.getGPUGrid(),
              let coordsBuffer = await spatialIndex.getGPUCoordsBuffer(),
              let offlineFlagsBuffer = await spatialIndex.getGPUOfflineFlagsBuffer() else {
            XCTFail("Failed to get required GPU components")
            return
        }

        // Simulate multiple clusters
        let clusterCount = 5
        var clusterOffsets: [Int32] = []
        let devicesPerCluster = testDevices.count / clusterCount

        for i in 0..<clusterCount {
            clusterOffsets.append(Int32(i * devicesPerCluster))
            clusterOffsets.append(Int32(devicesPerCluster))
        }

        let hullResult = try transformer.performGPUHullAndConfidence(
            coordsBuffer: coordsBuffer.buffer,
            offlineFlagsBuffer: offlineFlagsBuffer.buffer,
            clusterOffsets: clusterOffsets,
            gridParams: gridParams,
            grid: gpuGrid,
            clusterCount: clusterCount,
            maxPointsPerCluster: devicesPerCluster
        )

        let totalTime = CFAbsoluteTimeGetCurrent() - startTime

        // Performance assertions
        XCTAssertLessThan(hullResult.totalTime, 0.1, "Phase 3 should complete in <100ms")
        XCTAssertLessThan(totalTime, 0.5, "End-to-end should complete in <500ms")

        print("   ⏱️ Performance metrics:")
        print("      Sort: \(String(format: "%.1f", hullResult.sortTime * 1000))ms")
        print("      Hull: \(String(format: "%.1f", hullResult.hullTime * 1000))ms")
        print("      Confidence: \(String(format: "%.1f", hullResult.confidenceTime * 1000))ms")
        print("      Total Phase 3: \(String(format: "%.1f", hullResult.totalTime * 1000))ms")
        print("      End-to-end: \(String(format: "%.1f", totalTime * 1000))ms")
        print("   ✅ Performance validation passed")
    }

    // MARK: - Phase 3 Helper Methods

    /// Create irregular test cluster (pentagon + internal points)
    private func createIrregularTestCluster() -> [MockSpatialDevice] {
        var devices: [MockSpatialDevice] = []

        // Pentagon vertices around Wellington (NZTM coordinates approximation)
        let center = (-41.2865, 174.7762) // Wellington
        let pentagonPoints = [
            (center.0 - 0.01, center.1 - 0.01),   // SW
            (center.0 + 0.01, center.1 - 0.01),   // SE
            (center.0 + 0.015, center.1 + 0.005), // NE
            (center.0 - 0.005, center.1 + 0.015), // NW
            (center.0 - 0.015, center.1 + 0.005)  // W
        ]

        // Add pentagon vertices
        for (i, point) in pentagonPoints.enumerated() {
            devices.append(MockSpatialDevice(
                deviceId: "pentagon_\(i)",
                latitude: point.0,
                longitude: point.1,
                isOffline: true
            ))
        }

        // Add internal points
        devices.append(MockSpatialDevice(
            deviceId: "internal_1",
            latitude: center.0,
            longitude: center.1,
            isOffline: true
        ))

        devices.append(MockSpatialDevice(
            deviceId: "internal_2",
            latitude: center.0 - 0.005,
            longitude: center.1 + 0.005,
            isOffline: true
        ))

        return devices
    }

    /// Create dense offline cluster for confidence testing
    private func createDenseOfflineCluster() -> [MockSpatialDevice] {
        var devices: [MockSpatialDevice] = []
        let center = (-41.2865, 174.7762)

        // Dense grid of offline devices
        for i in 0..<5 {
            for j in 0..<5 {
                let lat = center.0 + Double(i) * 0.002
                let lon = center.1 + Double(j) * 0.002
                devices.append(MockSpatialDevice(
                    deviceId: "dense_\(i)_\(j)",
                    latitude: lat,
                    longitude: lon,
                    isOffline: true
                ))
            }
        }

        // Add some online devices around the cluster
        for k in 0..<10 {
            let angle = Double(k) * 0.628 // ~36 degrees apart
            let radius = 0.01
            let lat = center.0 + radius * cos(angle)
            let lon = center.1 + radius * sin(angle)
            devices.append(MockSpatialDevice(
                deviceId: "online_\(k)",
                latitude: lat,
                longitude: lon,
                isOffline: false
            ))
        }

        return devices
    }

    /// Create large test dataset for performance validation
    private func createLargeTestDataset(deviceCount: Int) -> [MockSpatialDevice] {
        var devices: [MockSpatialDevice] = []
        let center = (-41.2865, 174.7762)

        for i in 0..<deviceCount {
            let angle = Double(i) * 0.01
            let radius = Double(i % 100) * 0.0001
            let lat = center.0 + radius * cos(angle)
            let lon = center.1 + radius * sin(angle)
            let isOffline = i % 3 == 0 // ~33% offline

            devices.append(MockSpatialDevice(
                deviceId: "large_\(i)",
                latitude: lat,
                longitude: lon,
                isOffline: isOffline
            ))
        }

        return devices
    }

    /// Calculate polygon area using shoelace formula
    private func calculatePolygonArea(_ points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0.0 }

        var area: Double = 0.0
        let n = points.count

        for i in 0..<n {
            let j = (i + 1) % n
            area += Double(points[i].x * points[j].y)
            area -= Double(points[j].x * points[i].y)
        }

        return abs(area) / 2.0
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