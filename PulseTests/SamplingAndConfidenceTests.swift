//
//  SamplingAndConfidenceTests.swift
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

final class SamplingAndConfidenceTests: XCTestCase {

    private var modelContainer: ModelContainer!
    private var clusteringActor: SpatialClusteringActor!

    override func setUp() async throws {
        try await super.setUp()

        let schema = Schema([PowerSenseDevice.self, PowerSenseEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: schema, configurations: [config])

        let clusterConfig = SpatialClusteringConfig()
        clusteringActor = try SpatialClusteringActor(modelContainer: modelContainer, config: clusterConfig)
    }

    override func tearDown() async throws {
        clusteringActor = nil
        modelContainer = nil
        try await super.tearDown()
    }

    // MARK: - Sampling Tests

    func testFarthestPointSamplingWithLargeCluster() async throws {
        // Create 2000 devices in tight cluster (will trigger sampling at 1000 threshold)
        let context = ModelContext(modelContainer)
        let centerLat = -41.2924
        let centerLon = 174.7787

        for i in 0..<2000 {
            let device = PowerSenseDevice(
                deviceId: "sample_\(i)",
                latitude: centerLat + Double.random(in: -0.01...0.01),
                longitude: centerLon + Double.random(in: -0.01...0.01)
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

        // Verify sampling was applied (check logs) and hulls are still valid
        for cluster in result.clusters {
            XCTAssertGreaterThanOrEqual(cluster.hullVertices.count, 3, "Sampled cluster should have valid hull")
            XCTAssertLessThanOrEqual(cluster.hullVertices.count, 50, "Hull should respect vertex limit")
        }
    }

    func testSamplingPreservesExtrema() async throws {
        // Create rectangular cluster with clear extrema
        let context = ModelContext(modelContainer)
        let minLat = -41.30, maxLat = -41.28
        let minLon = 174.76, maxLon = 174.78

        // Add 1500 random points in rectangle
        for i in 0..<1500 {
            let device = PowerSenseDevice(
                deviceId: "rect_\(i)",
                latitude: Double.random(in: minLat...maxLat),
                longitude: Double.random(in: minLon...maxLon)
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

        // Add extrema points explicitly
        let extrema = [
            (minLat, minLon, "sw"),
            (minLat, maxLon, "se"),
            (maxLat, minLon, "nw"),
            (maxLat, maxLon, "ne")
        ]

        for (idx, (lat, lon, corner)) in extrema.enumerated() {
            let device = PowerSenseDevice(
                deviceId: "extrema_\(corner)",
                latitude: lat,
                longitude: lon
            )

            let event = PowerSenseEvent(
                eventId: "extrema_\(idx)",
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

        // Verify hull includes bounding box corners (extrema preserved)
        for cluster in result.clusters {
            let hullLats = cluster.hullVertices.map { $0.latitude }
            let hullLons = cluster.hullVertices.map { $0.longitude }

            let hullMinLat = hullLats.min() ?? 0
            let hullMaxLat = hullLats.max() ?? 0
            let hullMinLon = hullLons.min() ?? 0
            let hullMaxLon = hullLons.max() ?? 0

            // Hull should approximately match input bounds (allowing for tolerance)
            XCTAssertLessThan(abs(hullMinLat - minLat), 0.001, "Hull should preserve min latitude")
            XCTAssertLessThan(abs(hullMaxLat - maxLat), 0.001, "Hull should preserve max latitude")
            XCTAssertLessThan(abs(hullMinLon - minLon), 0.001, "Hull should preserve min longitude")
            XCTAssertLessThan(abs(hullMaxLon - maxLon), 0.001, "Hull should preserve max longitude")
        }
    }

    // MARK: - Confidence Tests

    func testConfidenceWithDenseOutageCluster() async throws {
        let context = ModelContext(modelContainer)
        let centerLat = -41.2924
        let centerLon = 174.7787

        // Create dense offline cluster (90 offline)
        for i in 0..<90 {
            let device = PowerSenseDevice(
                deviceId: "dense_offline_\(i)",
                latitude: centerLat + Double.random(in: -0.002...0.002),
                longitude: centerLon + Double.random(in: -0.002...0.002)
            )

            let event = PowerSenseEvent(
                eventId: "dense_\(i)",
                deviceId: device.deviceId,
                timestamp: Date(),
                severity: "high",
                isActive: true
            )
            device.events.append(event)

            context.insert(device)
        }

        // Add 10 online devices in same area
        for i in 0..<10 {
            let device = PowerSenseDevice(
                deviceId: "dense_online_\(i)",
                latitude: centerLat + Double.random(in: -0.002...0.002),
                longitude: centerLon + Double.random(in: -0.002...0.002)
            )
            // No event = online
            context.insert(device)
        }

        try context.save()

        let result = try await clusteringActor.clusterAllDevices()

        for cluster in result.clusters {
            // Should have high confidence (close to 0.9)
            XCTAssertGreaterThan(cluster.confidenceRating, 0.7, "Dense cluster should have high confidence")
        }
    }

    func testConfidenceWithSparseOutageCluster() async throws {
        let context = ModelContext(modelContainer)
        let centerLat = -41.2924
        let centerLon = 174.7787

        // Create sparse offline cluster (30 offline)
        for i in 0..<30 {
            let device = PowerSenseDevice(
                deviceId: "sparse_offline_\(i)",
                latitude: centerLat + Double.random(in: -0.005...0.005),
                longitude: centerLon + Double.random(in: -0.005...0.005)
            )

            let event = PowerSenseEvent(
                eventId: "sparse_\(i)",
                deviceId: device.deviceId,
                timestamp: Date(),
                severity: "high",
                isActive: true
            )
            device.events.append(event)

            context.insert(device)
        }

        // Add 70 online devices in same area
        for i in 0..<70 {
            let device = PowerSenseDevice(
                deviceId: "sparse_online_\(i)",
                latitude: centerLat + Double.random(in: -0.005...0.005),
                longitude: centerLon + Double.random(in: -0.005...0.005)
            )
            context.insert(device)
        }

        try context.save()

        let result = try await clusteringActor.clusterAllDevices()

        for cluster in result.clusters {
            // Should have lower confidence (around 0.3)
            XCTAssertGreaterThan(cluster.confidenceRating, 0.0, "Sparse cluster should have some confidence")
            XCTAssertLessThan(cluster.confidenceRating, 0.6, "Sparse cluster should have lower confidence")
        }
    }

    func testConfidenceWithBackgroundNoise() async throws {
        let context = ModelContext(modelContainer)
        let clusterLat = -41.2924
        let clusterLon = 174.7787

        // Create tight offline cluster (50 devices)
        for i in 0..<50 {
            let device = PowerSenseDevice(
                deviceId: "cluster_\(i)",
                latitude: clusterLat + Double.random(in: -0.001...0.001),
                longitude: clusterLon + Double.random(in: -0.001...0.001)
            )

            let event = PowerSenseEvent(
                eventId: "cluster_\(i)",
                deviceId: device.deviceId,
                timestamp: Date(),
                severity: "high",
                isActive: true
            )
            device.events.append(event)

            context.insert(device)
        }

        // Add 200 online devices in wider area (background)
        for i in 0..<200 {
            let device = PowerSenseDevice(
                deviceId: "background_\(i)",
                latitude: clusterLat + Double.random(in: -0.02...0.02),
                longitude: clusterLon + Double.random(in: -0.02...0.02)
            )
            context.insert(device)
        }

        try context.save()

        let result = try await clusteringActor.clusterAllDevices()

        for cluster in result.clusters {
            // Confidence should reflect ratio within hull, not just cluster
            XCTAssertGreaterThan(cluster.confidenceRating, 0.0, "Should have measurable confidence")
        }
    }

    func testConfidenceCalculationAccuracy() async throws {
        let context = ModelContext(modelContainer)
        let centerLat = -41.2924
        let centerLon = 174.7787

        // Create exact 50/50 ratio cluster
        for i in 0..<50 {
            let device = PowerSenseDevice(
                deviceId: "half_offline_\(i)",
                latitude: centerLat + Double.random(in: -0.003...0.003),
                longitude: centerLon + Double.random(in: -0.003...0.003)
            )

            let event = PowerSenseEvent(
                eventId: "half_\(i)",
                deviceId: device.deviceId,
                timestamp: Date(),
                severity: "high",
                isActive: true
            )
            device.events.append(event)

            context.insert(device)
        }

        for i in 0..<50 {
            let device = PowerSenseDevice(
                deviceId: "half_online_\(i)",
                latitude: centerLat + Double.random(in: -0.003...0.003),
                longitude: centerLon + Double.random(in: -0.003...0.003)
            )
            context.insert(device)
        }

        try context.save()

        let result = try await clusteringActor.clusterAllDevices()

        for cluster in result.clusters {
            let confidence = cluster.confidenceRating

            // Should be approximately 0.5 (allowing for clustering effects)
            XCTAssertGreaterThan(confidence, 0.3, "50/50 ratio should yield ~0.5 confidence (lower bound)")
            XCTAssertLessThan(confidence, 0.7, "50/50 ratio should yield ~0.5 confidence (upper bound)")
        }
    }
}