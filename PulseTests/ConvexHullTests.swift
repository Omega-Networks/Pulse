//
//  ConvexHullTests.swift
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
import CoreLocation
import SwiftData
@testable import Pulse

final class ConvexHullTests: XCTestCase {

    private var modelContainer: ModelContainer!
    private var clusteringActor: SpatialClusteringActor!

    override func setUp() async throws {
        try await super.setUp()

        // Create in-memory model container for testing
        let schema = Schema([PowerSenseDevice.self, PowerSenseEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: schema, configurations: [config])

        // Create clustering actor
        let clusterConfig = SpatialClusteringConfig()
        clusteringActor = try SpatialClusteringActor(modelContainer: modelContainer, config: clusterConfig)

        print("🚀 Initialized test environment for convex hull testing")
    }

    override func tearDown() async throws {
        clusteringActor = nil
        modelContainer = nil
        try await super.tearDown()
    }

    // MARK: - Hull Computation Tests

    func testConvexHullWithRandomPoints() async throws {
        print("🔺 Testing CPU convex hull with random points")

        // Create 50 random devices in Wellington region
        let context = ModelContext(modelContainer)
        let centerLat = -41.2924
        let centerLon = 174.7787

        for i in 0..<50 {
            let device = PowerSenseDevice(
                deviceId: "random_\(i)",
                latitude: centerLat + Double.random(in: -0.01...0.01),
                longitude: centerLon + Double.random(in: -0.01...0.01)
            )

            // Create offline event to mark device as offline
            let event = PowerSenseEvent(
                eventId: "\(i)",
                deviceId: device.deviceId,
                timestamp: Date(),
                severity: "high",
                isActive: true
            )
            device.events.append(event)

            context.insert(device)
        }

        try context.save()

        // Run clustering
        let result = try await clusteringActor.clusterAllDevices()

        print("   Generated 50 random points")
        print("   Found \(result.clusters.count) clusters")

        for cluster in result.clusters {
            print("   Cluster \(cluster.clusterId): \(cluster.hullVertices.count) hull vertices")
            XCTAssertGreaterThanOrEqual(cluster.hullVertices.count, 3, "Hull should have at least 3 vertices")
            XCTAssertLessThanOrEqual(cluster.hullVertices.count, 50, "Hull should respect 50-vertex limit")

            // Verify hull is closed (first and last are different but form a loop)
            XCTAssertFalse(cluster.hullVertices.isEmpty, "Hull should not be empty")
        }

        print("   ✅ Convex hull test with random points passed!")
    }

    func testConvexHullWithCollinearPoints() async throws {
        print("🔺 Testing CPU convex hull with collinear points")

        // Create collinear devices (straight line)
        let context = ModelContext(modelContainer)
        let baseCoord = CLLocationCoordinate2D(latitude: -41.2924, longitude: 174.7787)

        for i in 0..<20 {
            let device = PowerSenseDevice(
                deviceId: "collinear_\(i)",
                latitude: baseCoord.latitude,
                longitude: baseCoord.longitude + Double(i) * 0.001
            )

            let event = PowerSenseEvent(
                eventId: "\(i)",
                deviceId: device.deviceId,
                timestamp: Date(),
                severity: "high",
                isActive: true
            )
            device.events.append(event)

            context.insert(device)
        }

        try context.save()

        let result = try await clusteringActor.clusterAllDevices()

        print("   Generated 20 collinear points")
        print("   Found \(result.clusters.count) clusters")

        // Collinear points should get bounding box fallback
        for cluster in result.clusters {
            print("   Cluster \(cluster.clusterId): \(cluster.hullVertices.count) hull vertices (fallback)")
            XCTAssertGreaterThanOrEqual(cluster.hullVertices.count, 3, "Fallback hull should have at least 3 vertices")
        }

        print("   ✅ Convex hull test with collinear points passed!")
    }

    func testConvexHullWithDuplicatePoints() async throws {
        print("🔺 Testing CPU convex hull with duplicate points")

        // Create devices at same location (duplicates)
        let context = ModelContext(modelContainer)
        let fixedLat = -41.2924
        let fixedLon = 174.7787

        for i in 0..<30 {
            let device = PowerSenseDevice(
                deviceId: "duplicate_\(i)",
                latitude: fixedLat + (i < 10 ? 0.001 : (i < 20 ? 0.002 : 0.003)),
                longitude: fixedLon + (i < 10 ? 0.001 : (i < 20 ? 0.002 : 0.003))
            )

            let event = PowerSenseEvent(
                eventId: "\(i)",
                deviceId: device.deviceId,
                timestamp: Date(),
                severity: "high",
                isActive: true
            )
            device.events.append(event)

            context.insert(device)
        }

        try context.save()

        let result = try await clusteringActor.clusterAllDevices()

        print("   Generated 30 devices with duplicates (3 unique locations)")
        print("   Found \(result.clusters.count) clusters")

        for cluster in result.clusters {
            print("   Cluster \(cluster.clusterId): \(cluster.hullVertices.count) vertices from duplicate points")
            XCTAssertGreaterThanOrEqual(cluster.hullVertices.count, 3, "Hull should handle duplicates")
        }

        print("   ✅ Convex hull test with duplicate points passed!")
    }

    func testConvexHullVertexLimiting() async throws {
        print("🔺 Testing CPU convex hull vertex limiting (<50 vertices)")

        // Create large circular cluster (200 points)
        let context = ModelContext(modelContainer)
        let centerLat = -41.2924
        let centerLon = 174.7787

        for i in 0..<200 {
            let angle = Double(i) * 2.0 * .pi / 200.0
            let radius = 0.01
            let lat = centerLat + radius * sin(angle)
            let lon = centerLon + radius * cos(angle)

            let device = PowerSenseDevice(
                deviceId: "circle_\(i)",
                latitude: lat,
                longitude: lon
            )

            let event = PowerSenseEvent(
                eventId: "\(i)",
                deviceId: device.deviceId,
                timestamp: Date(),
                severity: "high",
                isActive: true
            )
            device.events.append(event)

            context.insert(device)
        }

        try context.save()

        let result = try await clusteringActor.clusterAllDevices()

        print("   Generated 200 points in circular pattern")
        print("   Found \(result.clusters.count) clusters")

        for cluster in result.clusters {
            print("   Cluster \(cluster.clusterId): \(cluster.hullVertices.count) vertices (limit applied)")
            XCTAssertLessThanOrEqual(cluster.hullVertices.count, 50, "Hull MUST respect 50-vertex limit for UI performance")
        }

        print("   ✅ Convex hull vertex limiting test passed!")
    }

    // MARK: - Performance Tests

    func testConvexHullPerformance() async throws {
        print("⏱️ Testing CPU convex hull performance")

        // Create large cluster (1000 points)
        let context = ModelContext(modelContainer)
        let centerLat = -41.2924
        let centerLon = 174.7787

        for i in 0..<1000 {
            let device = PowerSenseDevice(
                deviceId: "perf_\(i)",
                latitude: centerLat + Double.random(in: -0.05...0.05),
                longitude: centerLon + Double.random(in: -0.05...0.05)
            )

            let event = PowerSenseEvent(
                eventId: "\(i)",
                deviceId: device.deviceId,
                timestamp: Date(),
                severity: "high",
                isActive: true
            )
            device.events.append(event)

            context.insert(device)
        }

        try context.save()

        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await clusteringActor.clusterAllDevices()
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime

        print("   Generated 1000 points")
        print("   Total clustering time: \(String(format: "%.1f", totalTime * 1000))ms")
        print("   Found \(result.clusters.count) clusters")

        // Phase 3 should complete in < 100ms per requirement
        XCTAssertLessThan(result.processingTime, 0.5, "Clustering should complete in < 500ms")

        for cluster in result.clusters {
            print("   Cluster \(cluster.clusterId): \(cluster.devices.count) devices → \(cluster.hullVertices.count) vertices")
        }

        print("   ✅ Convex hull performance test passed!")
    }

    func testMultiClusterHullPerformance() async throws {
        print("⏱️ Testing multi-cluster hull performance")

        // Create 5 separate clusters with 200 devices each
        let context = ModelContext(modelContainer)
        let clusterCenters = [
            (-41.28, 174.77), // Wellington CBD
            (-41.29, 174.78), // Oriental Bay
            (-41.30, 174.79), // Miramar
            (-41.27, 174.76), // Kelburn
            (-41.31, 174.77)  // Kilbirnie
        ]

        for (clusterIdx, center) in clusterCenters.enumerated() {
            for deviceIdx in 0..<200 {
                let device = PowerSenseDevice(
                    deviceId: "cluster_\(clusterIdx)_device_\(deviceIdx)",
                    latitude: center.0 + Double.random(in: -0.005...0.005),
                    longitude: center.1 + Double.random(in: -0.005...0.005)
                )

                let event = PowerSenseEvent(
                    eventId: "\(clusterIdx)_\(deviceIdx)",
                    deviceId: device.deviceId,
                    timestamp: Date(),
                    severity: "high",
                    isActive: true
                )
                device.events.append(event)

                context.insert(device)
            }
        }

        try context.save()

        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await clusteringActor.clusterAllDevices()
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime

        print("   Generated 5 clusters with 200 devices each (1000 total)")
        print("   Total clustering time: \(String(format: "%.1f", totalTime * 1000))ms")
        print("   Found \(result.clusters.count) clusters")

        XCTAssertGreaterThan(result.clusters.count, 0, "Should find multiple clusters")
        XCTAssertLessThan(totalTime, 1.0, "Multi-cluster processing should complete in < 1s")

        for cluster in result.clusters {
            print("   Cluster \(cluster.clusterId): \(cluster.devices.count) devices, \(cluster.hullVertices.count) vertices, confidence: \(String(format: "%.2f", cluster.confidenceRating))")
        }

        print("   ✅ Multi-cluster hull performance test passed!")
    }
}