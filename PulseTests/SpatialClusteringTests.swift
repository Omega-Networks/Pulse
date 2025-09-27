//
//  SpatialClusteringTests.swift
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

final class SpatialClusteringTests: XCTestCase {

    private var transformer: CoordinateTransformer!

    override func setUp() async throws {
        try await super.setUp()
        transformer = try CoordinateTransformer(projectionSystem: .nztm2000)
        print("🚀 Initialized CoordinateTransformer for testing")
    }

    override func tearDown() async throws {
        transformer = nil
        try await super.tearDown()
    }

    func testGPUNeighborSearchWithClusteredData() async throws {
        print("🗺️ Testing GPU-Only Spatial Clustering System")

        // Step 1: Generate clustered mock dataset
        let devices = generateMockSpatialDevices()
        print("📊 Generated \(devices.count) mock devices")

        let offlineDevices = devices.filter { $0.isOffline == true }
        print("🔌 Offline devices: \(offlineDevices.count) (\(String(format: "%.1f", Double(offlineDevices.count) / Double(devices.count) * 100))%)")

        // Validate test data
        XCTAssertGreaterThan(devices.count, 90, "Expected ~95+ devices from 4 clusters + background")
        XCTAssertGreaterThan(offlineDevices.count, 15, "Expected significant offline devices from clusters")

        // Step 2: Build GPU spatial index
        print("🏗️ Building GPU spatial index...")
        let spatialIndex = GPUSpatialIndexManager<MockSpatialDevice>(transformer: transformer)
        try await spatialIndex.buildIndex(devices: devices)

        let isReady = await spatialIndex.isIndexReady
        let indexedCount = await spatialIndex.deviceCount
        XCTAssertTrue(isReady, "GPU index should be ready")
        XCTAssertEqual(indexedCount, devices.count, "All devices should be indexed")

        // Step 3: Test neighbor search on clustered devices
        print("🔍 Testing neighbor search on clustered offline devices...")

        // Find a device from cluster 0 (Wellington CBD - should have neighbors)
        guard let clusterDevice = offlineDevices.first(where: { $0.deviceId.hasPrefix("OUTAGE_0_") }) else {
            XCTFail("No offline device found in cluster 0")
            return
        }

        let searchRadius = 500.0
        let startTime = CFAbsoluteTimeGetCurrent()
        let neighbors = try await spatialIndex.findNeighbors(for: clusterDevice.deviceId, within: searchRadius)
        let searchTime = CFAbsoluteTimeGetCurrent() - startTime

        print("   Device: \(clusterDevice.deviceId) at (\(clusterDevice.latitude), \(clusterDevice.longitude))")
        print("   Search radius: \(searchRadius)m")
        print("   Neighbors found: \(neighbors.count)")
        print("   Query time: \(String(format: "%.6f", searchTime))s")

        // Assertions for GPU neighbor search
        XCTAssertGreaterThan(neighbors.count, 0, "Expected neighbors in Wellington CBD cluster (500m radius)")

        print("   ✅ SUCCESS: Found \(neighbors.count) neighbors - GPU spatial clustering working correctly!")

        // Performance check only if we found neighbors
        if neighbors.count > 0 {
            XCTAssertLessThan(searchTime, 0.001, "GPU query should be sub-millisecond")
        }

        // Validate neighbor results
        for neighbor in neighbors {
            XCTAssertNotEqual(neighbor.deviceId, clusterDevice.deviceId, "Device should not be neighbor of itself")
            XCTAssertEqual(neighbor.isOffline, true, "All neighbors should be offline devices")
        }

        print("✅ GPU neighbor search test completed successfully!")
    }

    // MARK: - Mock Spatial Data Generation

    private func generateMockSpatialDevices() -> [MockSpatialDevice] {
        return MockSpatialDataGenerator.generateClusteredDevices(
            areas: OutageArea.wellingtonAreas,
            totalDeviceCount: 115, // ~95 clustered + 20 background
            backgroundBounds: .wellington,
            backgroundOutageRate: 0.05
        )
    }

    private func testNeighborSearchPerformance(spatialIndex: GPUSpatialIndexManager<MockSpatialDevice>, devices: [MockSpatialDevice]) async {
        let testDevice = devices.first { $0.isOffline == true } ?? devices[0]

        let searchRadius = 500.0 // 500 meters

        let startTime = CFAbsoluteTimeGetCurrent()
        var searchTime = 0.0

        do {
            let neighbors = try await spatialIndex.findNeighbors(for: testDevice.deviceId, within: searchRadius)

            searchTime = CFAbsoluteTimeGetCurrent() - startTime

            print("   Test device: \(testDevice.deviceId) at (\(testDevice.latitude), \(testDevice.longitude))")
            print("   Search radius: \(searchRadius)m")
            print("   Neighbors found: \(neighbors.count)")
            print("   Search time: \(String(format: "%.3f", searchTime * 1000))ms")

            let offlineNeighbors = neighbors.filter { $0.isOffline == true }
            print("   Offline neighbors: \(offlineNeighbors.count)")
        } catch {
            searchTime = CFAbsoluteTimeGetCurrent() - startTime
            print("   ❌ Neighbor search failed: \(error)")
        }

        if searchTime < 0.001 {
            print("   ✅ Neighbor search performance: Excellent (<1ms)")
        } else if searchTime < 0.01 {
            print("   ✅ Neighbor search performance: Good (<10ms)")
        } else {
            print("   ⚠️  Neighbor search performance: Could be improved (>\(String(format: "%.1f", searchTime * 1000))ms)")
        }
    }
}

// MARK: - Mock Data Types

// Mock types are now imported from the main app target

// MARK: - Helper Extensions

extension String {
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}

extension MKMapRect {
    init(_ region: MKCoordinateRegion) {
        let topLeft = CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        )
        let bottomRight = CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        )

        let topLeftPoint = MKMapPoint(topLeft)
        let bottomRightPoint = MKMapPoint(bottomRight)

        self = MKMapRect(
            x: topLeftPoint.x,
            y: topLeftPoint.y,
            width: bottomRightPoint.x - topLeftPoint.x,
            height: bottomRightPoint.y - topLeftPoint.y
        )
    }
}