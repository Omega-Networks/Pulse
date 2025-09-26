//
//  SpatialClusteringTests.swift
//  Pulse
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

import Foundation
import MapKit
import CoreLocation

// MARK: - Spatial Clustering Test Suite

func testSpatialClustering() async {
    print("🗺️ Testing Spatial Clustering System")
    print("=" * 50)
    
    do {
        // Test 1: Create mock PowerSenseDevice dataset
        print("\n📊 Test 1: Generate Mock Device Dataset")
        let devices = generateMockPowerSenseDevices()
        print("Generated \(devices.count) mock PowerSenseDevices")
        
        let offlineDevices = devices.filter { $0.isOffline == true }
        print("Offline devices: \(offlineDevices.count) (\(String(format: "%.1f", Double(offlineDevices.count) / Double(devices.count) * 100))%)")
        
        // Test 2: Build spatial index
        print("\n🏗️ Test 2: Build Spatial Index")
        let spatialIndex = try SpatialIndexManager(devices: devices, projectionSystem: .nztm2000)
        
        // Test 3: Test neighbor search
        print("\n🔍 Test 3: Neighbor Search Performance")
        await testNeighborSearch(spatialIndex: spatialIndex, devices: devices)
        
        // Test 4: DBSCAN clustering
        print("\n🎯 Test 4: DBSCAN Clustering")
        await testDBSCANClustering(spatialIndex: spatialIndex)
        
        // Test 5: Viewport-based clustering
        print("\n📱 Test 5: Viewport-Based Clustering")
        await testViewportClustering(devices: devices)
        
        // Test 6: Performance with large dataset
        print("\n⚡ Test 6: Large Dataset Performance")
        await testLargeDatasetPerformance()
        
        print("\n✅ All spatial clustering tests completed!")
        
    } catch {
        print("❌ Spatial clustering test failed: \(error)")
    }
}

// MARK: - Mock Data Generation

func generateMockPowerSenseDevices() -> [MockPowerSenseDevice] {
    let wellingtonBounds = GeographicBounds(
        minLatitude: -41.5, maxLatitude: -41.0,
        minLongitude: 174.5, maxLongitude: 175.2
    )
    
    var devices: [MockPowerSenseDevice] = []
    
    // Generate clustered outage areas (realistic outage patterns)
    let outageAreas = [
        // Wellington CBD cluster
        OutageArea(center: CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762),
                  radius: 800.0, deviceCount: 25, outageRate: 0.8),
        
        // Lower Hutt cluster
        OutageArea(center: CLLocationCoordinate2D(latitude: -41.2093, longitude: 174.9076),
                  radius: 1200.0, deviceCount: 35, outageRate: 0.7),
        
        // Upper Hutt cluster
        OutageArea(center: CLLocationCoordinate2D(latitude: -41.1244, longitude: 175.0714),
                  radius: 600.0, deviceCount: 15, outageRate: 0.9),
        
        // Kapiti Coast cluster
        OutageArea(center: CLLocationCoordinate2D(latitude: -40.9006, longitude: 175.0114),
                  radius: 1500.0, deviceCount: 20, outageRate: 0.6)
    ]
    
    // Generate devices in outage clusters
    for (areaIndex, area) in outageAreas.enumerated() {
        for deviceIndex in 0..<area.deviceCount {
            let deviceCoord = generateRandomCoordinateInCircle(
                center: area.center,
                radiusMeters: area.radius
            )
            
            let isOffline = Double.random(in: 0...1) < area.outageRate
            let device = MockPowerSenseDevice(
                deviceId: "OUTAGE_\(areaIndex)_\(deviceIndex)",
                latitude: deviceCoord.latitude,
                longitude: deviceCoord.longitude,
                isOffline: isOffline
            )
            devices.append(device)
        }
    }
    
    // Generate background devices across Wellington region
    let backgroundDeviceCount = 5000
    for i in 0..<backgroundDeviceCount {
        let randomLat = Double.random(in: wellingtonBounds.minLatitude...wellingtonBounds.maxLatitude)
        let randomLon = Double.random(in: wellingtonBounds.minLongitude...wellingtonBounds.maxLongitude)
        
        // Much lower outage rate for background devices
        let isOffline = Double.random(in: 0...1) < 0.05
        
        let device = MockPowerSenseDevice(
            deviceId: "BG_\(i)",
            latitude: randomLat,
            longitude: randomLon,
            isOffline: isOffline
        )
        devices.append(device)
    }
    
    return devices
}

struct OutageArea {
    let center: CLLocationCoordinate2D
    let radius: Double // meters
    let deviceCount: Int
    let outageRate: Double
}

func generateRandomCoordinateInCircle(center: CLLocationCoordinate2D, radiusMeters: Double) -> CLLocationCoordinate2D {
    // Convert radius from meters to degrees (approximate)
    let radiusDegrees = radiusMeters / 111000.0
    
    let angle = Double.random(in: 0...(2 * Double.pi))
    let distance = Double.random(in: 0...radiusDegrees) * sqrt(Double.random(in: 0...1))
    
    let lat = center.latitude + distance * cos(angle)
    let lon = center.longitude + distance * sin(angle)
    
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

// MARK: - Test Functions

func testNeighborSearch(spatialIndex: SpatialIndexManager, devices: [MockPowerSenseDevice]) async {
    let testDevice = devices.first { $0.isOffline == true } ?? devices[0]
    
    let searchRadius = 500.0 // 500 meters
    let startTime = CFAbsoluteTimeGetCurrent()
    
    let neighbors = spatialIndex.findNeighbors(for: testDevice.deviceId, within: searchRadius)
    
    let searchTime = CFAbsoluteTimeGetCurrent() - startTime
    
    print("   Test device: \(testDevice.deviceId) at (\(testDevice.latitude), \(testDevice.longitude))")
    print("   Search radius: \(searchRadius)m")
    print("   Neighbors found: \(neighbors.count)")
    print("   Search time: \(String(format: "%.3f", searchTime * 1000))ms")
    
    let offlineNeighbors = neighbors.filter { $0.isOffline == true }
    print("   Offline neighbors: \(offlineNeighbors.count)")
    
    if searchTime < 0.001 {
        print("   ✅ Neighbor search performance: Excellent (<1ms)")
    } else if searchTime < 0.01 {
        print("   ✅ Neighbor search performance: Good (<10ms)")
    } else {
        print("   ⚠️  Neighbor search performance: Could be improved (>\(String(format: "%.1f", searchTime * 1000))ms)")
    }
}

func testDBSCANClustering(spatialIndex: SpatialIndexManager) async {
    // Test different parameter sets
    let parameterSets = [
        ("Urban", DBSCANClusterer.Parameters.urban),
        ("Suburban", DBSCANClusterer.Parameters.suburban),
        ("Rural", DBSCANClusterer.Parameters.rural)
    ]
    
    for (name, parameters) in parameterSets {
        print("\n   Testing \(name) parameters (ε=\(parameters.epsilon)m, minPts=\(parameters.minPoints)):")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let clusterer = DBSCANClusterer(spatialIndex: spatialIndex, parameters: parameters)
        let clusters = clusterer.clusterOfflineDevices()
        
        let clusteringTime = CFAbsoluteTimeGetCurrent() - startTime
        
        print("     Clusters found: \(clusters.count)")
        print("     Clustering time: \(String(format: "%.3f", clusteringTime))s")
        
        if !clusters.isEmpty {
            let clusterSizes = clusters.map { $0.devices.count }
            let totalDevicesInClusters = clusterSizes.reduce(0, +)
            let avgClusterSize = Double(totalDevicesInClusters) / Double(clusters.count)
            let maxClusterSize = clusterSizes.max() ?? 0
            
            print("     Total devices clustered: \(totalDevicesInClusters)")
            print("     Average cluster size: \(String(format: "%.1f", avgClusterSize)) devices")
            print("     Largest cluster: \(maxClusterSize) devices")
            
            // Show severity breakdown
            let severityCounts = clusters.reduce(into: [DeviceCluster.ClusterSeverity: Int]()) { counts, cluster in
                counts[cluster.severity, default: 0] += 1
            }
            
            for (severity, count) in severityCounts.sorted(by: { $0.key.priority > $1.key.priority }) {
                print("     \(severity): \(count) clusters")
            }
        }
        
        if clusteringTime < 1.0 {
            print("     ✅ Clustering performance: Excellent (<1s)")
        } else if clusteringTime < 5.0 {
            print("     ✅ Clustering performance: Good (<5s)")
        } else {
            print("     ⚠️  Clustering performance: Could be improved (>\(String(format: "%.1f", clusteringTime))s)")
        }
    }
}

func testViewportClustering(devices: [MockPowerSenseDevice]) async {
    do {
        let manager = try OutageClusteringManager(projectionSystem: .nztm2000)
        
        // Create test viewport centered on Wellington
        let wellingtonCenter = CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762)
        let span = MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.3)
        let region = MKCoordinateRegion(center: wellingtonCenter, span: span)
        let viewport = MKMapRect(region)
        
        print("   Viewport center: \(wellingtonCenter)")
        print("   Viewport span: \(span)")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let clusters = try await manager.clusterDevicesInViewport(
            devices: devices,
            viewport: viewport,
            paddingKm: 50.0, // Smaller padding for test
            clusteringParameters: .suburban
        )
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        
        print("   Clusters in viewport: \(clusters.count)")
        print("   Total processing time: \(String(format: "%.3f", totalTime))s")
        
        // Show top clusters by severity
        print("   Top clusters by severity:")
        for (index, cluster) in clusters.prefix(5).enumerated() {
            print("     \(index + 1). Cluster \(cluster.clusterId): \(cluster.devices.count) devices (\(cluster.severity))")
            print("        Centroid: (\(String(format: "%.4f", cluster.centroid.x)), \(String(format: "%.4f", cluster.centroid.y)))")
            print("        Bounding box: \(String(format: "%.0f", cluster.boundingBox.width))m × \(String(format: "%.0f", cluster.boundingBox.height))m")
        }
        
        if totalTime < 2.0 {
            print("   ✅ Viewport clustering performance: Excellent (<2s)")
        } else if totalTime < 5.0 {
            print("   ✅ Viewport clustering performance: Good (<5s)")
        } else {
            print("   ⚠️  Viewport clustering performance: Could be improved (>\(String(format: "%.1f", totalTime))s)")
        }
        
    } catch {
        print("   ❌ Viewport clustering failed: \(error)")
    }
}

func testLargeDatasetPerformance() async {
    print("   Generating large dataset (500k devices)...")

    let bounds = GeographicBounds(
        minLatitude: -47.0, maxLatitude: -34.0,
        minLongitude: 166.0, maxLongitude: 179.0
    )

    var largeDeviceSet: [MockPowerSenseDevice] = []

    // Generate realistic device distribution across New Zealand
    for i in 0..<500_000 {
        let lat = Double.random(in: bounds.minLatitude...bounds.maxLatitude)
        let lon = Double.random(in: bounds.minLongitude...bounds.maxLongitude)
        let isOffline = Double.random(in: 0...1) < 0.03 // 3% outage rate
        
        largeDeviceSet.append(MockPowerSenseDevice(
            deviceId: "LARGE_\(i)",
            latitude: lat,
            longitude: lon,
            isOffline: isOffline
        ))
    }
    
    do {
        let totalStartTime = CFAbsoluteTimeGetCurrent()
        
        // Build spatial index
        let indexStartTime = CFAbsoluteTimeGetCurrent()
        let spatialIndex = try SpatialIndexManager(devices: largeDeviceSet, projectionSystem: .nztm2000)
        let indexTime = CFAbsoluteTimeGetCurrent() - indexStartTime
        
        // Perform clustering
        let clusterStartTime = CFAbsoluteTimeGetCurrent()
        let clusterer = DBSCANClusterer(spatialIndex: spatialIndex, parameters: .suburban)
        let clusters = clusterer.clusterOfflineDevices()
        let clusterTime = CFAbsoluteTimeGetCurrent() - clusterStartTime
        
        let totalTime = CFAbsoluteTimeGetCurrent() - totalStartTime
        
        let offlineCount = largeDeviceSet.filter { $0.isOffline == true }.count
        
        print("   Dataset: \(largeDeviceSet.count.formatted()) devices")
        print("   Offline devices: \(offlineCount.formatted())")
        print("   Spatial index time: \(String(format: "%.3f", indexTime))s")
        print("   Clustering time: \(String(format: "%.3f", clusterTime))s")
        print("   Total time: \(String(format: "%.3f", totalTime))s")
        print("   Clusters found: \(clusters.count)")
        
        if totalTime < 30.0 {
            print("   ✅ Large dataset performance: Excellent (<30s for 500k devices)")
        } else if totalTime < 60.0 {
            print("   ✅ Large dataset performance: Good (<60s for 500k devices)")
        } else {
            print("   ⚠️  Large dataset performance: Could be improved (>\(String(format: "%.1f", totalTime))s for 500k devices)")
        }

        // Project performance for 1M devices (based on 500k test)
        let scaleFactor = 1_000_000.0 / 500_000.0
        let projected1MTime = totalTime * scaleFactor

        print("   Projected 1M device time: \(String(format: "%.3f", projected1MTime))s")

        if projected1MTime < 60.0 {
            print("   🎯 1M PowerSenseDevice projection: Ready for production (<1min)")
        } else if projected1MTime < 300.0 {
            print("   ✅ 1M PowerSenseDevice projection: Acceptable for background processing (<5min)")
        } else {
            print("   ⚠️  1M PowerSenseDevice projection: May need optimization (>\(String(format: "%.1f", projected1MTime))s)")
        }
        
    } catch {
        print("   ❌ Large dataset test failed: \(error)")
    }
}

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

// Note: testSpatialClustering() should be called from within the application
// when spatial clustering testing is needed, not executed at the top level.
