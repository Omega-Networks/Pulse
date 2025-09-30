//
//  SpatialClusteringProtocols.swift
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

public import CoreLocation
import OSLog

// MARK: - Custom Error Types

public enum ClusteringError: LocalizedError {
    case invalidCoordinates(deviceId: String, latitude: Double, longitude: Double)
    case gpuInitializationFailed(String)
    case metalDeviceUnavailable
    case bufferCreationFailed(String)
    case kernelCompilationFailed(String)
    case transformationFailed(projectionSystem: String)
    case insufficientData(deviceCount: Int, minimum: Int)
    case indexingFailed(String)
    case clusteringFailed(String)
    case configurationInvalid(parameter: String, value: String)
    case memoryAllocationFailed(requiredBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCoordinates(let deviceId, let lat, let lon):
            return "Invalid coordinates for device \(deviceId): (\(lat), \(lon))"
        case .gpuInitializationFailed(let details):
            return "GPU initialization failed: \(details)"
        case .metalDeviceUnavailable:
            return "Metal device is not available on this system"
        case .bufferCreationFailed(let details):
            return "Metal buffer creation failed: \(details)"
        case .kernelCompilationFailed(let details):
            return "Metal kernel compilation failed: \(details)"
        case .transformationFailed(let projectionSystem):
            return "Coordinate transformation failed for projection system: \(projectionSystem)"
        case .insufficientData(let count, let minimum):
            return "Insufficient data for clustering: \(count) devices (minimum: \(minimum))"
        case .indexingFailed(let details):
            return "Spatial indexing failed: \(details)"
        case .clusteringFailed(let details):
            return "Clustering operation failed: \(details)"
        case .configurationInvalid(let parameter, let value):
            return "Invalid configuration - \(parameter): \(value)"
        case .memoryAllocationFailed(let bytes):
            return "Memory allocation failed: required \(bytes) bytes"
        }
    }
}

// MARK: - Logging Extensions

extension Logger {
    static let spatialClustering = Logger(subsystem: "pulse.spatial", category: "clustering")
    static let spatialIndexing = Logger(subsystem: "pulse.spatial", category: "indexing")
    static let spatialPerformance = Logger(subsystem: "pulse.spatial", category: "performance")
    static let spatialGPU = Logger(subsystem: "pulse.spatial", category: "gpu")
    static let spatialValidation = Logger(subsystem: "pulse.spatial", category: "validation")
}

// MARK: - Protocol Abstractions

/// Protocol defining spatial indexing capabilities for any device type
public protocol SpatialIndexer: Sendable {
    associatedtype SpatialDeviceType: SpatialDevice & Sendable

    /// Build spatial index from device collection
    func buildIndex(devices: [SpatialDeviceType]) async throws

    /// Find neighbors within epsilon distance of target device
    func findNeighbors(for deviceId: String, within epsilon: Double) async throws -> [SpatialDeviceType]

    /// Find neighbors within epsilon distance of a coordinate
    func findNeighbors(at coordinate: CLLocationCoordinate2D, within epsilon: Double) async throws -> [SpatialDeviceType]

    /// Query devices within a geographic region
    func queryDevices(in region: GeographicBounds) async throws -> [SpatialDeviceType]

    /// Get total number of indexed devices
    var deviceCount: Int { get async }

    /// Check if index is ready for queries
    var isIndexReady: Bool { get async }

    /// Performance metrics for monitoring
    var performanceMetrics: SpatialIndexMetrics { get async }
}

/// Protocol defining clustering capabilities
public protocol SpatialClusterer: Sendable {
    associatedtype Device: SpatialDevice & Sendable
    associatedtype ClusterResult

    /// Perform clustering on indexed devices
    func cluster(devices: [Device], parameters: ClusteringParameters) async throws -> ClusterResult

    /// Validate clustering configuration
    func validateParameters(_ parameters: ClusteringParameters) throws
}

// MARK: - Configuration Types

public struct ClusteringParameters: Sendable {
    public let epsilon: Double              // Radius for neighborhood search (meters)
    public let minPoints: Int              // Minimum points to form a cluster
    public let aggregationThreshold: Int   // Minimum devices per cluster for privacy
    public let maxDevices: Int             // Maximum devices to process

    // Phase 3: Confidence and hull parameters
    public let minConfidence: Double       // Minimum confidence threshold (0.0-1.0)
    public let minTotalDevices: Int        // Minimum total devices for confidence calculation
    public let enableHullComputation: Bool // Enable convex hull generation
    public let maxHullVertices: Int        // Maximum vertices per hull (performance cap)

    // Phase 4: Concave hull parameters
    public let useConcaveHull: Bool        // Use concave hull (alpha shapes) instead of convex
    public let alphaRadius: Double         // Alpha radius for concave hull (meters)

    public init(
        epsilon: Double = 150.0,  // Reduced from 250m to 150m for tighter cluster bounds
        minPoints: Int = 3,
        aggregationThreshold: Int = 5,
        maxDevices: Int = 2_000_000,
        minConfidence: Double = 0.5,
        minTotalDevices: Int = 5,
        enableHullComputation: Bool = true,
        maxHullVertices: Int = 500,
        useConcaveHull: Bool = true,  // Enabled - efficient grid-based spatial indexing algorithm
        alphaRadius: Double = 100.0  // Concavity in meters - LOWER = tighter (50-300m range)
    ) {
        self.epsilon = epsilon
        self.minPoints = minPoints
        self.aggregationThreshold = aggregationThreshold
        self.maxDevices = maxDevices
        self.minConfidence = minConfidence
        self.minTotalDevices = minTotalDevices
        self.enableHullComputation = enableHullComputation
        self.maxHullVertices = maxHullVertices
        self.useConcaveHull = useConcaveHull
        self.alphaRadius = alphaRadius
    }

    public static let `default` = ClusteringParameters()

    /// Validate parameters for correctness
    public func validate() throws {
        guard epsilon > 0 else {
            throw ClusteringError.configurationInvalid(parameter: "epsilon", value: "\(epsilon)")
        }
        guard minPoints > 0 else {
            throw ClusteringError.configurationInvalid(parameter: "minPoints", value: "\(minPoints)")
        }
        guard aggregationThreshold >= minPoints else {
            throw ClusteringError.configurationInvalid(parameter: "aggregationThreshold", value: "\(aggregationThreshold)")
        }
        guard maxDevices > 0 else {
            throw ClusteringError.configurationInvalid(parameter: "maxDevices", value: "\(maxDevices)")
        }
        guard minConfidence >= 0.0 && minConfidence <= 1.0 else {
            throw ClusteringError.configurationInvalid(parameter: "minConfidence", value: "\(minConfidence)")
        }
        guard minTotalDevices > 0 else {
            throw ClusteringError.configurationInvalid(parameter: "minTotalDevices", value: "\(minTotalDevices)")
        }
        guard maxHullVertices > 2 else {
            throw ClusteringError.configurationInvalid(parameter: "maxHullVertices", value: "\(maxHullVertices)")
        }
        guard alphaRadius > 0 else {
            throw ClusteringError.configurationInvalid(parameter: "alphaRadius", value: "\(alphaRadius)")
        }
    }
}

// MARK: - Performance Metrics

public struct SpatialIndexMetrics: Sendable {
    public var indexBuildTime: TimeInterval = 0
    public var queryCount: Int = 0
    public var averageQueryTime: TimeInterval = 0
    public var lastQueryTime: TimeInterval = 0
    public var memoryUsage: Int = 0 // bytes
    public var gpuUtilization: Double = 0 // 0.0-1.0

    public init() {}
}

// Using existing ClusteringMetrics from SpatialClusteringSystem.swift

// MARK: - Dependency Injection Types

/// Configuration for spatial clustering components
public struct SpatialClusteringConfig: Sendable {
    public let projectionSystem: ProjectionSystem
    public let clusteringParameters: ClusteringParameters
    public let enableGPUAcceleration: Bool
    public let enablePerformanceLogging: Bool
    internal let cacheValidityDuration: TimeInterval

    public init(
        projectionSystem: ProjectionSystem = .nztm2000,
        clusteringParameters: ClusteringParameters = .default,
        enableGPUAcceleration: Bool = true,
        enablePerformanceLogging: Bool = true,
        cacheValidityDuration: TimeInterval = 30.0
    ) {
        self.projectionSystem = projectionSystem
        self.clusteringParameters = clusteringParameters
        self.enableGPUAcceleration = enableGPUAcceleration
        self.enablePerformanceLogging = enablePerformanceLogging
        self.cacheValidityDuration = cacheValidityDuration
    }

    public static let `default` = SpatialClusteringConfig()
}

// MARK: - Data Transfer Objects

/// Sendable DTO for PowerSenseDevice - decouples GPU processing from SwiftData models
public struct PowerSenseDeviceDTO: SpatialDevice, Sendable {
    public let deviceId: String
    public let latitude: Double
    public let longitude: Double
    public let isOffline: Bool?
    public let eventTimestamp: Date?  // Timestamp of most recent active event

    /// Initialize from SwiftData model
    init(from model: PowerSenseDevice) {
        self.deviceId = model.deviceId
        self.latitude = model.latitude
        self.longitude = model.longitude
        self.isOffline = model.isOffline
        self.eventTimestamp = model.lastStatusChange  // Use existing computed property
    }

    /// Direct initializer for testing
    public init(deviceId: String, latitude: Double, longitude: Double, isOffline: Bool? = nil, eventTimestamp: Date? = nil) {
        self.deviceId = deviceId
        self.latitude = latitude
        self.longitude = longitude
        self.isOffline = isOffline
        self.eventTimestamp = eventTimestamp
    }
}

// MARK: - Helper Extensions

extension Array where Element: SpatialDevice {
    /// Filter devices that are offline
    public var offlineDevices: [Element] {
        return filter { $0.isOffline == true }
    }

    /// Filter devices with valid coordinates
    public var validCoordinateDevices: [Element] {
        return filter { device in
            device.latitude >= -90 && device.latitude <= 90 &&
            device.longitude >= -180 && device.longitude <= 180 &&
            device.latitude != 0.0 && device.longitude != 0.0
        }
    }

    /// Get geographic bounds of all devices
    public var geographicBounds: GeographicBounds? {
        guard !isEmpty else { return nil }

        let lats = map { $0.latitude }
        let lons = map { $0.longitude }

        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else {
            return nil
        }

        return GeographicBounds(
            minLatitude: minLat,
            maxLatitude: maxLat,
            minLongitude: minLon,
            maxLongitude: maxLon
        )
    }
}
