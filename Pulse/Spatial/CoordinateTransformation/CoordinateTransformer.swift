//
//  MetalCoordinateTransformer.swift
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

import Metal
import simd
import OSLog
public import CoreLocation

// MARK: - Public Types

/// Projected coordinate in meters
public struct ProjectedCoordinate: Sendable {
    public let x: Double  // Easting
    public let y: Double  // Northing
    public let system: ProjectionSystem
    
    public init(x: Double, y: Double, system: ProjectionSystem) {
        self.x = x
        self.y = y
        self.system = system
    }
    
    /// Convert to GameplayKit vector2 with Float precision
    public var vector2: SIMD2<Float> {
        return SIMD2<Float>(Float(x), Float(y))
    }
    
    /// Calculate euclidean distance to another projected coordinate
    public func distance(to other: ProjectedCoordinate) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return sqrt(dx * dx + dy * dy)
    }
    
    /// Calculate squared distance (faster, avoids sqrt)
    public func distanceSquared(to other: ProjectedCoordinate) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

/// Supported projection systems for coordinate transformation
///
/// For open-source contributors: Add new projection systems here following the pattern.
/// Each case must implement corresponding transform kernels in MetalShaderLibrary.
public enum ProjectionSystem: Equatable, Hashable, Sendable {
    case nztm2000        // New Zealand Transverse Mercator (EPSG:2193)
    case webMercator     // Web Mercator (EPSG:3857) - Global web mapping
    case utm(zone: Int, isNorthern: Bool)  // UTM zones with hemisphere for regional accuracy

    public var epsgCode: Int {
        switch self {
        case .nztm2000:
            return 2193
        case .webMercator:
            return 3857
        case .utm(let zone, let isNorthern):
            // UTM EPSG codes: Northern hemisphere 32600+zone, Southern hemisphere 32700+zone
            return isNorthern ? (32600 + zone) : (32700 + zone)
        }
    }
}

// MARK: - Performance Metrics

public struct TransformationMetrics {
    public let gpuTime: Double          // GPU processing time in seconds
    public let totalTime: Double        // Total time including setup in seconds
    public let coordinatesProcessed: Int
    public let throughput: Double       // coordinates per second
    public let memoryUsed: Int         // bytes of GPU memory used
    public let deviceName: String      // GPU device name

    // Phase 3: Hull and confidence computation metrics
    public let hullComputeTime: Double  // Time for convex hull computation (seconds)
    public let confidenceCalculateTime: Double // Time for confidence calculation (seconds)
    public let clustersProcessed: Int   // Number of clusters processed
    public let avgHullVertices: Double  // Average vertices per hull

    public init(
        gpuTime: Double,
        totalTime: Double,
        coordinatesProcessed: Int,
        memoryUsed: Int,
        deviceName: String,
        hullComputeTime: Double = 0.0,
        confidenceCalculateTime: Double = 0.0,
        clustersProcessed: Int = 0,
        avgHullVertices: Double = 0.0
    ) {
        self.gpuTime = gpuTime
        self.totalTime = totalTime
        self.coordinatesProcessed = coordinatesProcessed
        self.throughput = coordinatesProcessed > 0 ? Double(coordinatesProcessed) / totalTime : 0.0
        self.memoryUsed = memoryUsed
        self.deviceName = deviceName
        self.hullComputeTime = hullComputeTime
        self.confidenceCalculateTime = confidenceCalculateTime
        self.clustersProcessed = clustersProcessed
        self.avgHullVertices = avgHullVertices
    }
    
    public var description: String {
        let baseMetrics = """
        GPU Transformation Metrics:
        - Device: \(deviceName)
        - Coordinates: \(coordinatesProcessed.formatted())
        - GPU Time: \(String(format: "%.3f", gpuTime * 1000))ms
        - Total Time: \(String(format: "%.3f", totalTime * 1000))ms
        - Throughput: \(String(format: "%.0f", throughput)) coords/sec (\(String(format: "%.1f", throughput/1000))k/sec)
        - Memory: \(String(format: "%.1f", Double(memoryUsed) / 1024 / 1024))MB
        """

        if clustersProcessed > 0 {
            return baseMetrics + """

        Phase 3 Hull & Confidence:
        - Clusters: \(clustersProcessed)
        - Hull Time: \(String(format: "%.3f", hullComputeTime * 1000))ms
        - Confidence Time: \(String(format: "%.3f", confidenceCalculateTime * 1000))ms
        - Avg Hull Vertices: \(String(format: "%.1f", avgHullVertices))
        """
        } else {
            return baseMetrics
        }
    }
}

/// GPU memory usage metrics for monitoring and optimization
///
/// For open-source contributors: Use this to track memory consumption
/// and prevent GPU memory exhaustion on large datasets.
public struct GPUMemoryUsage {
    public let totalBufferMemory: Int      // Total buffer memory in bytes
    public let coordsBufferMemory: Int     // Coordinate buffer memory in bytes
    public let dbscanBufferMemory: Int     // DBSCAN-specific buffer memory in bytes
    public let deviceCount: Int            // Number of devices being processed

    /// Total memory usage in megabytes
    public var totalMemoryMB: Double {
        return Double(totalBufferMemory) / 1024.0 / 1024.0
    }

    /// Human-readable memory description for logging
    public var description: String {
        return "\(String(format: "%.1f", totalMemoryMB))MB total (\(deviceCount) devices)"
    }
}

// MARK: - Main Metal GPU CoordinateTransformer

/// GPU-accelerated coordinate transformation using Metal compute shaders
///
/// This class provides high-performance coordinate transformation and spatial clustering
/// optimized for infrastructure monitoring applications like PowerSense outage detection.
///
/// For open-source contributors:
/// - All GPU kernels are defined in MetalShaderLibrary
/// - Use SendableBuffer wrapper for Swift 6 concurrency compliance
/// - Performance is optimized for Apple Silicon (unified memory architecture)
/// - DBSCAN clustering targets sub-50ms performance for 10k+ devices
public final class CoordinateTransformer: Sendable {
    
    // MARK: - Metal Resources
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let logger = Logger.spatialGPU
    private let nztmPipelineState: MTLComputePipelineState
    private let webMercatorPipelineState: MTLComputePipelineState
    private let utmPipelineState: MTLComputePipelineState
    
    // MARK: - Configuration
    
    private let projectionSystem: ProjectionSystem
    private let threadsPerThreadgroup: MTLSize
    private let maxBufferSize: Int
    private let optimalBatchSize: Int
    
    // MARK: - Initialization
    
    /// Initialize GPU-accelerated transformer with specified projection system
    public init(projectionSystem: ProjectionSystem = .nztm2000) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalTransformError.deviceNotAvailable
        }
        
        self.device = device
        self.projectionSystem = projectionSystem
        
        print("🚀 Initializing Metal GPU CoordinateTransformer...")
        print("   Device: \(device.name)")
        print("   Unified Memory: \(device.hasUnifiedMemory)")
        print("   Max Buffer Length: \(device.maxBufferLength / 1024 / 1024)MB")
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalTransformError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
        // Create Metal library and pipeline states
        self.library = try Self.createMetalLibrary(device: device)
        self.nztmPipelineState = try Self.createPipelineState(library: library, functionName: "nztm_transform")
        self.webMercatorPipelineState = try Self.createPipelineState(library: library, functionName: "web_mercator_transform")
        self.utmPipelineState = try Self.createPipelineState(library: library, functionName: "utm_transform")
        
        // Configure optimal threading and batching
        self.threadsPerThreadgroup = MTLSize(
            width: min(1024, device.maxThreadsPerThreadgroup.width),
            height: 1,
            depth: 1
        )
        
        // Configure memory limits (conservative for stability)
        self.maxBufferSize = device.hasUnifiedMemory ?
            min(512 * 1024 * 1024, device.maxBufferLength) :  // 512MB on Apple Silicon
            min(64 * 1024 * 1024, device.maxBufferLength)     // 64MB on discrete GPUs
        
        // Calculate optimal batch size based on coordinate size
        let coordinateMemorySize = MemoryLayout<SIMD2<Float>>.size * 2 // Input + output
        self.optimalBatchSize = min(2_000_000, maxBufferSize / coordinateMemorySize)
        
        print("   ✅ Metal GPU initialization complete")
        print("   Threads per group: \(threadsPerThreadgroup.width)")
        print("   Optimal batch size: \(optimalBatchSize.formatted()) coordinates")
    }
    
    /// Initialize with optimal projection system for a given center coordinate
    public convenience init(optimizedFor centerCoordinate: CLLocationCoordinate2D) throws {
        let optimalSystem = Self.optimalProjectionSystem(for: centerCoordinate)
        try self.init(projectionSystem: optimalSystem)
    }
    
    // MARK: - Public Transform Interface
    
    /// Transform single coordinate (uses GPU for consistency but not optimal)
    public func transform(_ coordinate: CLLocationCoordinate2D) -> ProjectedCoordinate {
        // For single coordinates, we could use CPU calculation for efficiency,
        // but using GPU ensures consistent results with batch operations
        let results = (try? batchTransform([coordinate])) ?? []
        return results.first ?? ProjectedCoordinate(x: 0, y: 0, system: projectionSystem)
    }
    
    /// GPU-accelerated batch coordinate transformation - primary interface
    public func batchTransform(_ coordinates: [CLLocationCoordinate2D]) throws -> [ProjectedCoordinate] {
        let (results, _) = try batchTransformWithMetrics(coordinates)
        return results
    }
    
    /// GPU-accelerated batch transformation with detailed performance metrics
    public func batchTransformWithMetrics(_ coordinates: [CLLocationCoordinate2D]) throws -> ([ProjectedCoordinate], TransformationMetrics) {
        let totalStartTime = CFAbsoluteTimeGetCurrent()
        
        guard !coordinates.isEmpty else {
            let metrics = TransformationMetrics(
                gpuTime: 0, totalTime: 0, coordinatesProcessed: 0,
                memoryUsed: 0, deviceName: device.name
            )
            return ([], metrics)
        }
        
        print("   🔥 GPU transforming \(coordinates.count.formatted()) coordinates...")
        
        let results: [ProjectedCoordinate]
        let gpuTime: Double
        
        if coordinates.count <= optimalBatchSize {
            // Single batch processing
            let (batchResults, batchGpuTime) = try processSingleBatch(coordinates)
            results = batchResults
            gpuTime = batchGpuTime
        } else {
            // Multi-batch processing for large datasets
            let (batchResults, batchGpuTime) = try processLargeBatch(coordinates)
            results = batchResults
            gpuTime = batchGpuTime
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - totalStartTime
        let throughput = Double(coordinates.count) / totalTime
        
        // Calculate memory usage
        let inputMemory = coordinates.count * MemoryLayout<SIMD2<Float>>.size
        let outputMemory = results.count * MemoryLayout<SIMD2<Float>>.size
        let totalMemory = inputMemory + outputMemory
        
        let metrics = TransformationMetrics(
            gpuTime: gpuTime,
            totalTime: totalTime,
            coordinatesProcessed: coordinates.count,
            memoryUsed: totalMemory,
            deviceName: device.name
        )
        
        print("   ✅ GPU transformation complete: \(String(format: "%.0f", throughput)) coords/sec")
        
        return (results, metrics)
    }
    
    /// Batch inverse transform (CPU fallback - scheduled for Phase 2 GPU implementation)
    /// TODO Phase 2: Implement GPU inverse transformation for full GPU-only architecture
    public func batchInverseTransform(_ projectedCoordinates: [ProjectedCoordinate]) -> [CLLocationCoordinate2D] {
        // Phase 1 cleanup note: Keeping CPU fallback until Phase 2 GPU-only DBSCAN implementation
        // This will be replaced with GPU inverse transform kernels in Phase 2
        return projectedCoordinates.map { inverseTransformCPU($0) }
    }
    
    // MARK: - GPU Processing Implementation
    
    private func processSingleBatch(_ coordinates: [CLLocationCoordinate2D]) throws -> ([ProjectedCoordinate], Double) {
        let gpuStartTime = CFAbsoluteTimeGetCurrent()
        
        // Convert to GPU-friendly format
        let inputData = coordinates.map { coord in
            SIMD2<Float>(Float(coord.latitude), Float(coord.longitude))
        }
        
        // Create Metal buffers
        let inputBuffer = device.makeBuffer(
            bytes: inputData,
            length: inputData.count * MemoryLayout<SIMD2<Float>>.size,
            options: .storageModeShared
        )!
        
        let outputBuffer = device.makeBuffer(
            length: coordinates.count * MemoryLayout<SIMD2<Float>>.size,
            options: .storageModeShared
        )!
        
        // Execute GPU transformation
        try executeGPUKernel(
            inputBuffer: inputBuffer,
            outputBuffer: outputBuffer,
            coordinateCount: coordinates.count
        )
        
        // Read results (zero-copy on Apple Silicon)
        let outputPointer = outputBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: coordinates.count)
        let outputArray = Array(UnsafeBufferPointer(start: outputPointer, count: coordinates.count))
        
        // Convert back to ProjectedCoordinate
        let results = outputArray.map { result in
            ProjectedCoordinate(x: Double(result.x), y: Double(result.y), system: projectionSystem)
        }
        
        let gpuTime = CFAbsoluteTimeGetCurrent() - gpuStartTime
        return (results, gpuTime)
    }
    
    private func processLargeBatch(_ coordinates: [CLLocationCoordinate2D]) throws -> ([ProjectedCoordinate], Double) {
        let totalCount = coordinates.count
        let chunkSize = optimalBatchSize
        let totalChunks = (totalCount + chunkSize - 1) / chunkSize
        
        print("     📊 Processing \(totalCount.formatted()) coordinates in \(totalChunks) GPU batches")
        
        var allResults: [ProjectedCoordinate] = []
        allResults.reserveCapacity(totalCount)
        var totalGpuTime: Double = 0
        
        for chunkIndex in 0..<totalChunks {
            let startIndex = chunkIndex * chunkSize
            let endIndex = min(startIndex + chunkSize, totalCount)
            let chunk = Array(coordinates[startIndex..<endIndex])
            
            let (chunkResults, chunkGpuTime) = try processSingleBatch(chunk)
            allResults.append(contentsOf: chunkResults)
            totalGpuTime += chunkGpuTime
            
            // Progress reporting
            if (chunkIndex + 1) % max(1, totalChunks / 10) == 0 || chunkIndex == totalChunks - 1 {
                let progress = Double(chunkIndex + 1) / Double(totalChunks) * 100
                let processed = min(endIndex, totalCount)
                print("       GPU Progress: \(String(format: "%.1f", progress))% (\(processed.formatted())/\(totalCount.formatted()))")
            }
        }
        
        return (allResults, totalGpuTime)
    }
    
    private func executeGPUKernel(inputBuffer: MTLBuffer, outputBuffer: MTLBuffer, coordinateCount: Int) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }
        
        // Select and configure pipeline
        let pipelineState = getPipelineState(for: projectionSystem)
        computeEncoder.setComputePipelineState(pipelineState)
        
        // Set buffers
        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(outputBuffer, offset: 0, index: 1)
        
        // Set projection-specific parameters
        setProjectionParameters(encoder: computeEncoder, system: projectionSystem)
        
        // Calculate thread distribution
        let threadsPerGrid = MTLSize(width: coordinateCount, height: 1, depth: 1)
        
        // Dispatch compute shader
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()
        
        // Execute synchronously
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Check for GPU errors
        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Pipeline and Parameter Management
    
    private func getPipelineState(for system: ProjectionSystem) -> MTLComputePipelineState {
        switch system {
        case .nztm2000:
            return nztmPipelineState
        case .webMercator:
            return webMercatorPipelineState
        case .utm(_, _):
            return utmPipelineState
        }
    }
    
    private func setProjectionParameters(encoder: MTLComputeCommandEncoder, system: ProjectionSystem) {
        switch system {
        case .nztm2000:
            var params = NZTMParameters(
                centralMeridian: 173.0,
                falseEasting: 1600000.0,
                falseNorthing: 10000000.0,
                scaleFactor: 0.9996
            )
            encoder.setBytes(&params, length: MemoryLayout<NZTMParameters>.size, index: 2)
            
        case .webMercator:
            var params = WebMercatorParameters(
                earthRadius: 6378137.0,
                maxLatitude: 85.0511287798
            )
            encoder.setBytes(&params, length: MemoryLayout<WebMercatorParameters>.size, index: 2)
            
        case .utm(let zone, let isNorthern):
            var params = UTMParameters(
                zone: Int32(zone),
                centralMeridian: Float((zone - 1) * 6 - 177),
                falseEasting: 500000.0,
                scaleFactor: 0.9996,
                falseNorthing: isNorthern ? 0.0 : 10000000.0
            )
            encoder.setBytes(&params, length: MemoryLayout<UTMParameters>.size, index: 2)
        }
    }
    
    // MARK: - Projection System Selection
    
    /// Determine optimal projection system for a given center coordinate
    public static func optimalProjectionSystem(for center: CLLocationCoordinate2D) -> ProjectionSystem {
        // New Zealand region - use NZTM for highest accuracy
        if center.latitude >= -47.0 && center.latitude <= -34.0 &&
           center.longitude >= 166.0 && center.longitude <= 179.0 {
            return .nztm2000
        }
        
        // For other regions, determine appropriate UTM zone and hemisphere
        let utmZone = Int((center.longitude + 180) / 6) + 1
        let isNorthern = center.latitude >= 0
        return .utm(zone: utmZone, isNorthern: isNorthern)
    }
    
    // MARK: - CPU Fallback for Inverse Transform
    
    private func inverseTransformCPU(_ projected: ProjectedCoordinate) -> CLLocationCoordinate2D {
        switch projectionSystem {
        case .nztm2000:
            return inverseTransformFromNZTM(projected)
        case .webMercator:
            return inverseTransformFromWebMercator(projected)
        case .utm(let zone, let isNorthern):
            return inverseTransformFromUTM(projected, zone: zone, isNorthern: isNorthern)
        }
    }
    
    private func inverseTransformFromNZTM(_ projected: ProjectedCoordinate) -> CLLocationCoordinate2D {
        let x = projected.x - 1600000.0
        let y = projected.y - 10000000.0
        let lat = y / (0.9996 * 6378137.0)
        let lon = 173.0 * .pi / 180.0 + (x / (0.9996 * 6378137.0 * cos(lat)))
        return CLLocationCoordinate2D(latitude: lat * 180.0 / .pi, longitude: lon * 180.0 / .pi)
    }
    
    private func inverseTransformFromWebMercator(_ projected: ProjectedCoordinate) -> CLLocationCoordinate2D {
        let longitude = projected.x / 6378137.0 * 180.0 / .pi
        let latitude = (2.0 * atan(exp(projected.y / 6378137.0)) - .pi / 2.0) * 180.0 / .pi
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    private func inverseTransformFromUTM(_ projected: ProjectedCoordinate, zone: Int, isNorthern: Bool) -> CLLocationCoordinate2D {
        let centralMeridian = Double((zone - 1) * 6 - 177) * .pi / 180.0
        let x = projected.x - 500000.0

        // Handle southern hemisphere: subtract false northing (10,000,000m) if needed
        let y = isNorthern ? projected.y : projected.y - 10000000.0

        // Simplified inverse UTM transform
        let lat = y / (0.9996 * 6378137.0)
        let lon = centralMeridian + (x / (0.9996 * 6378137.0 * cos(lat)))
        return CLLocationCoordinate2D(latitude: lat * 180.0 / .pi, longitude: lon * 180.0 / .pi)
    }
    
    // MARK: - GPU Grid Indexing

    /// Build GPU grid index for offline devices and return neighbor counts
    /// Uses proper grid-based O(N * avg_cell_size) algorithm instead of O(N²) brute force
    public func buildGPUGridIndex(
        offlineCoordinates: [ProjectedCoordinate],
        deviceIndices: [Int32],
        epsilon: Double = 500.0,
        useGridOptimization: Bool = true
    ) throws -> (gridParams: GridIndexParameters, neighborResults: [GPUNeighborResult]) {
        guard !offlineCoordinates.isEmpty else {
            let bounds = SpatialBounds(minX: 0, maxX: 1000, minY: 0, maxY: 1000)
            let params = GridIndexParameters(bounds: bounds, cellSize: 353.0, epsilon: Float(epsilon))
            return (params, [])
        }

        print("🔥 Building GPU grid index for \(offlineCoordinates.count) offline devices...")

        // Calculate bounds and grid parameters
        let bounds = SpatialBounds.from(coordinates: offlineCoordinates)
        let cellSize = Float(epsilon / sqrt(2.0)) // ~353m for 500m epsilon
        let gridParams = GridIndexParameters(bounds: bounds, cellSize: cellSize, epsilon: Float(epsilon))

        let gridSize = Int(gridParams.gridWidth * gridParams.gridHeight)
        print("   Grid dimensions: \(gridParams.gridWidth)x\(gridParams.gridHeight) = \(gridSize) cells")
        print("   Cell size: \(cellSize)m, Search radius: \(epsilon)m")

        // Use GPU grid-based spatial indexing for optimal performance
        return try buildGridIndexOptimized(
            offlineCoordinates: offlineCoordinates,
            deviceIndices: deviceIndices,
            gridParams: gridParams,
            gridSize: gridSize
        )
    }

    /// Optimized grid-based neighbor counting - O(N * avg_cell_size)
    private func buildGridIndexOptimized(
        offlineCoordinates: [ProjectedCoordinate],
        deviceIndices: [Int32],
        gridParams: GridIndexParameters,
        gridSize: Int
    ) throws -> (gridParams: GridIndexParameters, neighborResults: [GPUNeighborResult]) {

        print("   Using optimized grid-based algorithm...")

        // Convert coordinates to GPU format
        let gpuCoords = offlineCoordinates.map { SIMD2<Float>(Float($0.x), Float($0.y)) }

        // Create coordinate buffer
        let coordsBuffer = device.makeBuffer(
            bytes: gpuCoords,
            length: gpuCoords.count * MemoryLayout<SIMD2<Float>>.size,
            options: .storageModeShared
        )!

        let indicesBuffer = device.makeBuffer(
            bytes: deviceIndices,
            length: deviceIndices.count * MemoryLayout<Int32>.size,
            options: .storageModeShared
        )!

        // Create GPU grid structure
        let grid = try GPUGrid(device: device, gridSize: gridSize, totalPoints: offlineCoordinates.count)

        // Phase 1: Count points per cell
        try executeGridCountKernel(coordsBuffer: coordsBuffer, grid: grid, gridParams: gridParams, coordinateCount: offlineCoordinates.count)

        // Phase 2: CPU prefix sum to convert counts to offsets (GPU prefix scan in Phase 2)
        let cellCountsPointer = grid.cellCounts.contents.bindMemory(to: Int32.self, capacity: gridSize)
        let cellOffsetsPointer = grid.cellOffsets.contents.bindMemory(to: Int32.self, capacity: gridSize)
        let cellPositionsPointer = grid.cellPositions.contents.bindMemory(to: Int32.self, capacity: gridSize)

        var runningSum: Int32 = 0
        for i in 0..<gridSize {
            cellOffsetsPointer[i] = runningSum
            cellPositionsPointer[i] = runningSum  // Copy for atomic positions
            runningSum += cellCountsPointer[i]
        }

        // Phase 3: Build point lists per cell
        try executeGridBuildKernel(coordsBuffer: coordsBuffer, grid: grid, gridParams: gridParams, coordinateCount: offlineCoordinates.count)

        // Phase 4: Count neighbors using grid
        let resultsBuffer = device.makeBuffer(
            length: offlineCoordinates.count * MemoryLayout<GPUNeighborResult>.size,
            options: .storageModeShared
        )!

        try executeGridNeighborKernel(
            coordsBuffer: coordsBuffer,
            indicesBuffer: indicesBuffer,
            resultsBuffer: resultsBuffer,
            grid: grid,
            gridParams: gridParams,
            coordinateCount: offlineCoordinates.count
        )

        // Read results
        let resultsPointer = resultsBuffer.contents().bindMemory(to: GPUNeighborResult.self, capacity: offlineCoordinates.count)
        let neighborResults = Array(UnsafeBufferPointer(start: resultsPointer, count: offlineCoordinates.count))

        let totalNeighbors = neighborResults.reduce(0) { $0 + Int($1.neighborCount) }
        let avgCellOccupancy = gridSize > 0 ? Double(offlineCoordinates.count) / Double(gridSize) : 0
        print("   ✅ Optimized GPU grid index built: \(totalNeighbors) neighbor relationships")
        print("   Grid efficiency: \(String(format: "%.3f", avgCellOccupancy)) avg points/cell")

        return (gridParams, neighborResults)
    }

    /// Execute grid count kernel (Phase 1 of optimized grid build)
    private func executeGridCountKernel(
        coordsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        coordinateCount: Int
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "gridCountPass")
        computeEncoder.setComputePipelineState(pipelineState)

        // Set buffers
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(grid.rawCellCounts, offset: 0, index: 1)

        // Set grid parameters
        var params = gridParams
        computeEncoder.setBytes(&params, length: MemoryLayout<GridIndexParameters>.size, index: 2)

        // Dispatch
        let threadsPerGrid = MTLSize(width: coordinateCount, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }

    /// Execute grid count kernel with offline flags (Phase 1 of flag-aware grid build)
    private func executeGridCountKernelWithFlags(
        coordsBuffer: MTLBuffer,
        offlineFlagsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        coordinateCount: Int
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "gridCountPassWithFlags")
        computeEncoder.setComputePipelineState(pipelineState)

        // Set buffers
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(offlineFlagsBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.rawCellCounts, offset: 0, index: 2)

        // Set grid parameters
        var params = gridParams
        computeEncoder.setBytes(&params, length: MemoryLayout<GridIndexParameters>.size, index: 3)

        // Dispatch
        let threadsPerGrid = MTLSize(width: coordinateCount, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }

    /// Execute grid build kernel (Phase 3 of optimized grid build)
    private func executeGridBuildKernel(
        coordsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        coordinateCount: Int
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "gridBuildPass")
        computeEncoder.setComputePipelineState(pipelineState)

        // Set buffers
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(grid.rawPointIndices, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.rawCellOffsets, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.rawCellPositions, offset: 0, index: 3)

        // Set grid parameters
        var params = gridParams
        computeEncoder.setBytes(&params, length: MemoryLayout<GridIndexParameters>.size, index: 4)

        // Dispatch
        let threadsPerGrid = MTLSize(width: coordinateCount, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }

    /// Execute grid build kernel with offline flags (Phase 3 of flag-aware grid build)
    private func executeGridBuildKernelWithFlags(
        coordsBuffer: MTLBuffer,
        offlineFlagsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        coordinateCount: Int
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "gridBuildPassWithFlags")
        computeEncoder.setComputePipelineState(pipelineState)

        // Set buffers
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(offlineFlagsBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.rawPointIndices, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.rawCellOffsets, offset: 0, index: 3)
        computeEncoder.setBuffer(grid.rawCellCounts, offset: 0, index: 4) // Reusing as positions (reset to 0 earlier)

        // Set grid parameters
        var params = gridParams
        computeEncoder.setBytes(&params, length: MemoryLayout<GridIndexParameters>.size, index: 5)

        // Dispatch
        let threadsPerGrid = MTLSize(width: coordinateCount, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }


    /// Execute grid neighbor counting kernel (Phase 4 of optimized grid build)
    private func executeGridNeighborKernel(
        coordsBuffer: MTLBuffer,
        indicesBuffer: MTLBuffer,
        resultsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        coordinateCount: Int
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "countNeighborsGrid")
        computeEncoder.setComputePipelineState(pipelineState)

        // Set buffers
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(grid.rawPointIndices, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.rawCellOffsets, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.rawCellCounts, offset: 0, index: 3)
        computeEncoder.setBuffer(resultsBuffer, offset: 0, index: 4)
        computeEncoder.setBuffer(indicesBuffer, offset: 0, index: 5)

        // Set grid parameters
        var params = gridParams
        computeEncoder.setBytes(&params, length: MemoryLayout<GridIndexParameters>.size, index: 6)

        // Set total count
        var totalCount = UInt32(coordinateCount)
        computeEncoder.setBytes(&totalCount, length: MemoryLayout<UInt32>.size, index: 7)

        // Dispatch
        let threadsPerGrid = MTLSize(width: coordinateCount, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }

    /// Execute on-demand neighbor search kernel
    internal func executeFindNeighborsKernel(
        coordsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        queryId: Int
    ) throws -> [Int] {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "findNeighborsKernel")
        computeEncoder.setComputePipelineState(pipelineState)

        // Create output buffers
        let maxNeighbors = 1000 // Safety limit
        let outputNeighborsBuffer = device.makeBuffer(
            length: maxNeighbors * MemoryLayout<Int32>.size,
            options: .storageModeShared
        )!

        let outputCountBuffer = device.makeBuffer(
            length: MemoryLayout<Int32>.size,
            options: .storageModeShared
        )!

        // Initialize count to 0
        let countPointer = outputCountBuffer.contents().bindMemory(to: Int32.self, capacity: 1)
        countPointer[0] = 0

        // Set buffers
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(grid.rawPointIndices, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.rawCellOffsets, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.rawCellCounts, offset: 0, index: 3)
        computeEncoder.setBuffer(outputNeighborsBuffer, offset: 0, index: 4)
        computeEncoder.setBuffer(outputCountBuffer, offset: 0, index: 5)

        // Set grid parameters
        var params = gridParams
        computeEncoder.setBytes(&params, length: MemoryLayout<GridIndexParameters>.size, index: 6)

        // Set query ID
        var queryIdVar = Int32(queryId)
        computeEncoder.setBytes(&queryIdVar, length: MemoryLayout<Int32>.size, index: 7)

        // Dispatch with 9 threads (3x3 neighboring cells)
        let threadsPerGrid = MTLSize(width: 9, height: 1, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 9, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }

        // Read results
        let neighborCount = Int(countPointer[0])
        guard neighborCount > 0 else { return [] }

        let neighborsPointer = outputNeighborsBuffer.contents().bindMemory(to: Int32.self, capacity: maxNeighbors)
        let neighborIds = Array(UnsafeBufferPointer(start: neighborsPointer, count: min(neighborCount, maxNeighbors)))

        return neighborIds.map { Int($0) }
    }

    /// Build persistent GPU grid for on-demand neighbor queries with full coordinate indexing
    internal func buildPersistentGPUGrid(
        allCoordinates: [ProjectedCoordinate], // ALL device coordinates for full grid coverage
        offlineFlags: [Bool], // Offline status for each device (same order as allCoordinates)
        epsilon: Double = 500.0
    ) throws -> (gridParams: GridIndexParameters, grid: GPUGrid, coordsBuffer: MTLBuffer, offlineFlagsBuffer: MTLBuffer) {
        guard !allCoordinates.isEmpty else {
            throw MetalTransformError.insufficientData("No coordinates provided")
        }

        guard allCoordinates.count == offlineFlags.count else {
            throw MetalTransformError.insufficientData("Coordinates and offline flags count mismatch")
        }

        print("🔧 GPU Grid Build: Starting with \(allCoordinates.count) total devices...")

        // Calculate bounds and grid parameters from ALL coordinates for full coverage
        let bounds = SpatialBounds.from(coordinates: allCoordinates)
        let cellSize = Float(epsilon / sqrt(2.0)) // ~353m for 500m epsilon
        let gridParams = GridIndexParameters(bounds: bounds, cellSize: cellSize, epsilon: Float(epsilon))

        let gridSize = Int(gridParams.gridWidth * gridParams.gridHeight)
        print("   Grid dimensions: \(gridParams.gridWidth)x\(gridParams.gridHeight) = \(gridSize) cells")

        // Create coordinate buffer with ALL device coordinates
        let gpuCoords = allCoordinates.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let coordsBuffer = device.makeBuffer(
            bytes: gpuCoords,
            length: gpuCoords.count * MemoryLayout<SIMD2<Float>>.size,
            options: .storageModeShared
        )!

        // Create offline flags buffer for selective processing
        let offlineFlagsBuffer = device.makeBuffer(
            bytes: offlineFlags,
            length: offlineFlags.count * MemoryLayout<Bool>.size,
            options: .storageModeShared
        )!

        // Create GPU grid sized for all devices
        let grid = try GPUGrid(device: device, gridSize: gridSize, totalPoints: allCoordinates.count)

        let gridBuildStart = CFAbsoluteTimeGetCurrent()

        // Phase 1: Count points per cell (with offline filtering)
        print("   Phase 1: Counting offline points per cell...")
        try executeGridCountKernelWithFlags(
            coordsBuffer: coordsBuffer,
            offlineFlagsBuffer: offlineFlagsBuffer,
            grid: grid,
            gridParams: gridParams,
            coordinateCount: allCoordinates.count
        )

        // Phase 2: CPU prefix sum to convert counts to offsets (GPU prefix scan in Phase 2)
        print("   Phase 2: Computing cell offsets...")
        let cellCountsPointer = grid.cellCounts.contents.bindMemory(to: Int32.self, capacity: gridSize)
        let cellOffsetsPointer = grid.cellOffsets.contents.bindMemory(to: Int32.self, capacity: gridSize)

        var runningSum: Int32 = 0
        for i in 0..<gridSize {
            cellOffsetsPointer[i] = runningSum
            runningSum += cellCountsPointer[i]
            cellCountsPointer[i] = 0 // Reset for build phase (reused as positions)
        }

        // Phase 3: Build point lists with offline filtering
        print("   Phase 3: Building point indices (offline only)...")
        try executeGridBuildKernelWithFlags(
            coordsBuffer: coordsBuffer,
            offlineFlagsBuffer: offlineFlagsBuffer,
            grid: grid,
            gridParams: gridParams,
            coordinateCount: allCoordinates.count
        )

        let gridBuildTime = CFAbsoluteTimeGetCurrent() - gridBuildStart
        print("✅ GPU Grid Build: Completed in \(String(format: "%.3f", gridBuildTime))s")

        return (gridParams, grid, coordsBuffer, offlineFlagsBuffer)
    }

    /// Create DBSCAN buffers for GPU clustering (Phase 2)
    internal func createDBSCANBuffers(deviceCount: Int) throws -> GPUDBSCANBuffers {
        return try GPUDBSCANBuffers(device: device, deviceCount: deviceCount)
    }

    /// Create hull and confidence buffers for GPU polygon computation (Phase 3)
    internal func createHullAndConfidenceBuffers(clusterCount: Int, maxPointsPerCluster: Int) throws -> GPUHullBuffers {
        // Cap max points based on GPU memory recommendations
        let recommendedMaxWorkingSet = device.recommendedMaxWorkingSetSize
        let estimatedBufferSize = maxPointsPerCluster * MemoryLayout<SIMD2<Float>>.size * clusterCount

        let adjustedMaxPoints = estimatedBufferSize > Int(recommendedMaxWorkingSet / 2)
            ? min(maxPointsPerCluster, Int(recommendedMaxWorkingSet) / (clusterCount * MemoryLayout<SIMD2<Float>>.size))
            : maxPointsPerCluster

        logger.debug("🔧 GPU Hull Buffers: \(clusterCount) clusters, max \(adjustedMaxPoints) points/cluster")

        return try GPUHullBuffers(device: device, clusterCount: clusterCount, maxPointsPerCluster: adjustedMaxPoints)
    }

    /// Create coordinates buffer for optimized cluster data
    internal func createCoordinatesBuffer(from coordinates: [SIMD2<Float>]) throws -> SendableBuffer {
        guard let buffer = device.makeBuffer(
            bytes: coordinates,
            length: coordinates.count * MemoryLayout<SIMD2<Float>>.size,
            options: .storageModeShared
        ) else {
            throw MetalTransformError.gpuExecutionFailed("Failed to create coordinates buffer")
        }
        return SendableBuffer(buffer)
    }

    /// Create offline flags buffer for optimized cluster data
    internal func createOfflineFlagsBuffer(from flags: [UInt8]) throws -> SendableBuffer {
        guard let buffer = device.makeBuffer(
            bytes: flags,
            length: flags.count * MemoryLayout<UInt8>.size,
            options: .storageModeShared
        ) else {
            throw MetalTransformError.gpuExecutionFailed("Failed to create offline flags buffer")
        }
        return SendableBuffer(buffer)
    }

    /// Perform GPU-accelerated hull and confidence computation (Phase 3)
    ///
    /// This method coordinates the complete Phase 3 pipeline:
    /// - Bitonic sort of cluster coordinates
    /// - Parallel monotone chain hull construction
    /// - Grid-based confidence calculation with expanded bounds
    ///
    /// Returns hull vertices and confidence pairs for CPU post-processing
    internal func performGPUHullAndConfidence(
        coordsBuffer: MTLBuffer,
        offlineFlagsBuffer: MTLBuffer,
        clusterOffsets: [Int32],
        gridParams: GridIndexParameters,
        grid: GPUGrid,
        clusterCount: Int,
        maxPointsPerCluster: Int
    ) async throws -> GPUHullAndConfidenceResult {

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("🔺 Phase 3: Starting GPU hull & confidence computation for \(clusterCount) clusters")

        logger.info("🔧 Creating hull and confidence buffers...")
        let hullBuffers = try createHullAndConfidenceBuffers(clusterCount: clusterCount, maxPointsPerCluster: maxPointsPerCluster)
        logger.info("✅ Hull and confidence buffers created successfully")

        // Upload cluster offsets
        logger.info("🔧 Creating cluster offsets buffer...")
        let clusterOffsetsBuffer = device.makeBuffer(
            bytes: clusterOffsets,
            length: clusterOffsets.count * MemoryLayout<Int32>.size,
            options: .storageModeShared
        )!
        logger.info("✅ Cluster offsets buffer created")

        // Phase 3 parameters
        logger.info("🔧 Setting up Phase 3 parameters...")
        let phase3Params = Phase3Parameters(
            clustersCount: Int32(clusterCount),
            maxPointsPerCluster: Int32(maxPointsPerCluster),
            maxHullVertices: Int32(512), // Increased for larger clusters, simplify post-compute if needed
            epsilon: Float(1000.0), // 1000m expansion for better coverage in sparse areas
            minTotalDevices: Int32(5), // Minimum for valid confidence
            gridCellSize: Float(gridParams.cellSize),
            gridWidth: Int32(gridParams.gridWidth),
            gridHeight: Int32(gridParams.gridHeight),
            collinearThreshold: Float(0.3) // 0.3m collinear tolerance - more aggressive pruning
        )
        logger.info("✅ Phase 3 parameters configured")

        // Phase 3A: Bitonic sort coordinates by X
        logger.info("🔧 Starting Phase 3A: Bitonic sort coordinates by X...")
        let sortTime = CFAbsoluteTimeGetCurrent()
        try executeBitonicSortKernel(
            coordsBuffer: coordsBuffer,
            clusterOffsetsBuffer: clusterOffsetsBuffer,
            tempWorkBuffer: hullBuffers.rawTempSortBuffer,
            phase3Params: phase3Params,
            clusterCount: clusterCount
        )
        let sortDuration = CFAbsoluteTimeGetCurrent() - sortTime
        logger.info("✅ Phase 3A completed: Bitonic sort (\(String(format: "%.1f", sortDuration * 1000))ms)")

        // Phase 3B: Build convex hulls with pruning
        logger.info("🔧 Starting Phase 3B: Build convex hulls with pruning...")
        let hullTime = CFAbsoluteTimeGetCurrent()
        try await executeBuildHullKernel(
            coordsBuffer: coordsBuffer,
            hullVerticesBuffer: hullBuffers.rawHullVertices,
            hullCountsBuffer: hullBuffers.rawHullCounts,
            clusterOffsetsBuffer: clusterOffsetsBuffer,
            tempHullBuffer: hullBuffers.rawTempSortBuffer, // Reuse temp buffer
            phase3Params: phase3Params,
            clusterCount: clusterCount
        )
        let hullDuration = CFAbsoluteTimeGetCurrent() - hullTime
        logger.info("✅ Phase 3B completed: Hull construction (\(String(format: "%.1f", hullDuration * 1000))ms)")

        // Phase 3C: Calculate confidence using grid
        logger.info("🔧 Starting Phase 3C: Calculate confidence using grid...")
        let confidenceTime = CFAbsoluteTimeGetCurrent()
        try await executeConfidenceKernel(
            coordsBuffer: coordsBuffer,
            offlineFlagsBuffer: offlineFlagsBuffer,
            grid: grid,
            gridParams: gridParams,
            hullVerticesBuffer: hullBuffers.rawHullVertices,
            hullCountsBuffer: hullBuffers.rawHullCounts,
            confidencePairsBuffer: hullBuffers.rawConfidencePairs,
            phase3Params: phase3Params,
            clusterCount: clusterCount
        )
        let confidenceDuration = CFAbsoluteTimeGetCurrent() - confidenceTime
        logger.info("✅ Phase 3C completed: Confidence calculation (\(String(format: "%.1f", confidenceDuration * 1000))ms)")

        let totalDuration = CFAbsoluteTimeGetCurrent() - startTime

        logger.info("""
        ✅ Phase 3 GPU Complete:
           Sort: \(String(format: "%.1f", sortDuration * 1000))ms
           Hull: \(String(format: "%.1f", hullDuration * 1000))ms
           Confidence: \(String(format: "%.1f", confidenceDuration * 1000))ms
           Total: \(String(format: "%.1f", totalDuration * 1000))ms
        """)

        // Return results for CPU post-processing
        return GPUHullAndConfidenceResult(
            hullBuffers: hullBuffers,
            sortTime: sortDuration,
            hullTime: hullDuration,
            confidenceTime: confidenceDuration,
            totalTime: totalDuration,
            clustersProcessed: clusterCount
        )
    }

    // MARK: - Phase 3 Kernel Execution Methods

    /// Execute preprocessing kernel to reduce hull input points
    private func executePreprocessingKernel(
        inputCoordsBuffer: MTLBuffer,
        outputCoordsBuffer: MTLBuffer,
        outputCountsBuffer: MTLBuffer,
        clusterOffsetsBuffer: MTLBuffer,
        phase3Params: Phase3Parameters,
        clusterCount: Int
    ) throws {
        logger.info("🔧 Starting hull preprocessing to reduce point count...")
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "preprocessHullPoints")
        computeEncoder.setComputePipelineState(pipelineState)

        computeEncoder.setBuffer(inputCoordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(outputCoordsBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(outputCountsBuffer, offset: 0, index: 2)
        computeEncoder.setBuffer(clusterOffsetsBuffer, offset: 0, index: 3)

        var params = phase3Params
        computeEncoder.setBytes(&params, length: MemoryLayout<Phase3Parameters>.size, index: 4)

        let threadgroupSize = MTLSize(width: 1, height: 1, depth: 1) // One thread per cluster
        let numThreadgroups = MTLSize(width: clusterCount, height: 1, depth: 1)

        computeEncoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            logger.error("❌ Preprocessing kernel failed: \\(error.localizedDescription)")
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }

        logger.info("✅ Hull preprocessing completed")
    }

    /// Execute bitonic sort kernel for coordinate sorting
    private func executeBitonicSortKernel(
        coordsBuffer: MTLBuffer,
        clusterOffsetsBuffer: MTLBuffer,
        tempWorkBuffer: MTLBuffer,
        phase3Params: Phase3Parameters,
        clusterCount: Int
    ) throws {
        logger.info("🔧 Creating command buffer for bitonic sort...")
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }
        logger.info("✅ Command buffer and encoder created for bitonic sort")

        logger.info("🔧 Setting up pipeline state for bitonicSortByX kernel...")
        let pipelineState = try getOrCreatePipelineState(functionName: "bitonicSortByX")
        computeEncoder.setComputePipelineState(pipelineState)
        logger.info("✅ Pipeline state configured")

        logger.info("🔧 Setting buffers and parameters...")
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(clusterOffsetsBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(tempWorkBuffer, offset: 0, index: 2)

        var params = phase3Params
        computeEncoder.setBytes(&params, length: MemoryLayout<Phase3Parameters>.size, index: 3)
        logger.info("✅ Buffers and parameters set")

        let threadgroupSize = MTLSize(width: 256, height: 1, depth: 1)
        let numThreadgroups = MTLSize(width: clusterCount, height: 1, depth: 1)
        logger.info("🔧 Dispatching GPU threads: \(numThreadgroups.width) threadgroups × \(threadgroupSize.width) threads")

        computeEncoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        logger.info("✅ GPU dispatch completed, encoder ended")

        logger.info("🔧 Committing command buffer and waiting for completion...")
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        logger.info("✅ Bitonic sort kernel completed successfully")

        if let error = commandBuffer.error {
            logger.error("❌ Bitonic sort kernel failed: \(error.localizedDescription)")
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }

    /// Execute convex hull construction kernel
    private func executeBuildHullKernel(
        coordsBuffer: MTLBuffer,
        hullVerticesBuffer: MTLBuffer,
        hullCountsBuffer: MTLBuffer,
        clusterOffsetsBuffer: MTLBuffer,
        tempHullBuffer: MTLBuffer,
        phase3Params: Phase3Parameters,
        clusterCount: Int
    ) async throws {
        logger.info("🔧 Creating command buffer for hull construction...")
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }
        logger.info("✅ Command buffer and encoder created for hull construction")

        logger.info("🔧 Setting up pipeline state for buildConvexHullSequential kernel...")
        let pipelineState = try getOrCreatePipelineState(functionName: "buildConvexHullSequential")
        computeEncoder.setComputePipelineState(pipelineState)
        logger.info("✅ Hull pipeline state configured")

        logger.info("🔧 Setting hull buffers and parameters...")
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(hullVerticesBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(hullCountsBuffer, offset: 0, index: 2)
        computeEncoder.setBuffer(clusterOffsetsBuffer, offset: 0, index: 3)
        computeEncoder.setBuffer(tempHullBuffer, offset: 0, index: 4)

        var params = phase3Params
        computeEncoder.setBytes(&params, length: MemoryLayout<Phase3Parameters>.size, index: 5)
        logger.info("✅ Hull buffers and parameters set")

        let threadgroupSize = MTLSize(width: 1, height: 1, depth: 1)  // Single thread per cluster
        let numThreadgroups = MTLSize(width: clusterCount, height: 1, depth: 1)
        logger.info("🔧 Dispatching hull GPU threads: \(numThreadgroups.width) clusters × \(threadgroupSize.width) thread/cluster (sequential)")

        computeEncoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        logger.info("✅ Hull GPU dispatch completed, encoder ended")

        // Use proper async execution
        commandBuffer.commit()
        await commandBuffer.completed()

        if let error = commandBuffer.error {
            logger.error("❌ Hull construction kernel failed: \(error.localizedDescription)")
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }

        logger.info("✅ Hull construction kernel completed successfully")
    }

    /// Execute confidence calculation kernel using grid optimization
    private func executeConfidenceKernel(
        coordsBuffer: MTLBuffer,
        offlineFlagsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        hullVerticesBuffer: MTLBuffer,
        hullCountsBuffer: MTLBuffer,
        confidencePairsBuffer: MTLBuffer,
        phase3Params: Phase3Parameters,
        clusterCount: Int
    ) async throws {
        logger.info("🔧 Creating command buffer for confidence calculation...")
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }
        logger.info("✅ Command buffer and encoder created for confidence calculation")

        logger.info("🔧 Setting up pipeline state for calculateConfidenceWithGrid kernel...")
        let pipelineState = try getOrCreatePipelineState(functionName: "calculateConfidenceWithGrid")
        computeEncoder.setComputePipelineState(pipelineState)
        logger.info("✅ Confidence pipeline state configured")

        logger.info("🔧 Setting confidence buffers and parameters...")
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(offlineFlagsBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.rawCellOffsets, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.rawCellCounts, offset: 0, index: 3)
        computeEncoder.setBuffer(grid.rawPointIndices, offset: 0, index: 4)
        computeEncoder.setBuffer(hullVerticesBuffer, offset: 0, index: 5)
        computeEncoder.setBuffer(hullCountsBuffer, offset: 0, index: 6)
        computeEncoder.setBuffer(confidencePairsBuffer, offset: 0, index: 7)

        var params3 = phase3Params
        computeEncoder.setBytes(&params3, length: MemoryLayout<Phase3Parameters>.size, index: 8)

        var gridParameters = gridParams
        computeEncoder.setBytes(&gridParameters, length: MemoryLayout<GridIndexParameters>.size, index: 9)
        logger.info("✅ Confidence buffers and parameters set")

        let threadgroupSize = MTLSize(width: 64, height: 1, depth: 1)
        let numThreadgroups = MTLSize(width: clusterCount, height: 1, depth: 1)
        logger.info("🔧 Dispatching confidence GPU threads: \(numThreadgroups.width) threadgroups × \(threadgroupSize.width) threads")

        computeEncoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        logger.info("✅ Confidence GPU dispatch completed, encoder ended")

        logger.info("🔧 Committing confidence command buffer with async handler...")

        return try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    self.logger.error("❌ Confidence calculation kernel failed: \(error.localizedDescription)")
                    continuation.resume(throwing: MetalTransformError.gpuExecutionFailed(error.localizedDescription))
                    return
                }

                if buffer.status == .error {
                    self.logger.error("❌ Confidence buffer status error")
                    continuation.resume(throwing: MetalTransformError.gpuExecutionFailed("Command buffer status error"))
                    return
                }

                self.logger.info("✅ Confidence calculation kernel completed successfully")
                continuation.resume()
            }

            commandBuffer.commit()
        }
    }

    /// Perform GPU-accelerated DBSCAN clustering using Metal compute shaders
    ///
    /// This implements the complete DBSCAN algorithm on GPU with the following phases:
    /// - Phase 1: Neighbor search with core point detection
    /// - Phase 2a: Initialize cluster labels for core points
    /// - Phase 2b: Iterative label propagation until convergence
    /// - Phase 2c: Finalize labels with path compression
    ///
    /// For open-source contributors: This is the main entry point for GPU DBSCAN.
    /// Requires spatial grid to be pre-built via buildPersistentGPUGrid()
    internal func performGPUDBSCAN(
        coordsBuffer: MTLBuffer,
        offlineFlagsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        dbscanParams: DBSCANParameters,
        deviceCount: Int
    ) throws -> DBSCANResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        print("🧠 GPU DBSCAN: Starting clustering for \(deviceCount) devices...")
        print("   Parameters: epsilon=\(dbscanParams.epsilon)m, minPoints=\(dbscanParams.minPoints), threshold=\(dbscanParams.aggregationThreshold)")

        // Create DBSCAN buffers
        let dbscanBuffers = try createDBSCANBuffers(deviceCount: deviceCount)

        // Monitor GPU memory usage
        let memoryUsage = getGPUMemoryUsage(deviceCount: deviceCount)
        print("   🔧 GPU Memory: \(memoryUsage.description)")

        // Phase 1: Neighbor search with core point detection
        print("   Phase 1: Neighbor search and core point detection...")
        let phase1Time = CFAbsoluteTimeGetCurrent()
        try executeDBSCANNeighborSearchKernel(
            coordsBuffer: coordsBuffer,
            offlineFlagsBuffer: offlineFlagsBuffer,
            grid: grid,
            gridParams: gridParams,
            dbscanParams: dbscanParams,
            dbscanBuffers: dbscanBuffers,
            deviceCount: deviceCount
        )
        let phase1Duration = CFAbsoluteTimeGetCurrent() - phase1Time

        // Phase 2a: Initialize cluster labels for core points
        print("   Phase 2a: Initialize cluster labels...")
        let phase2aTime = CFAbsoluteTimeGetCurrent()
        try executeDBSCANInitializeLabelsKernel(
            offlineFlagsBuffer: offlineFlagsBuffer,
            dbscanBuffers: dbscanBuffers,
            deviceCount: deviceCount
        )
        let phase2aDuration = CFAbsoluteTimeGetCurrent() - phase2aTime

        // Phase 2b: Iterative label propagation until convergence
        print("   Phase 2b: Label propagation...")
        let propagationTime = CFAbsoluteTimeGetCurrent()
        let iterations = try executeDBSCANLabelPropagation(
            coordsBuffer: coordsBuffer,
            offlineFlagsBuffer: offlineFlagsBuffer,
            grid: grid,
            gridParams: gridParams,
            dbscanParams: dbscanParams,
            dbscanBuffers: dbscanBuffers,
            deviceCount: deviceCount
        )
        let propagationDuration = CFAbsoluteTimeGetCurrent() - propagationTime

        // Phase 2c: Finalize labels with path compression
        print("   Phase 2c: Finalizing labels...")
        let phase2cTime = CFAbsoluteTimeGetCurrent()
        try executeDBSCANFinalizeLabelsKernel(
            offlineFlagsBuffer: offlineFlagsBuffer,
            dbscanBuffers: dbscanBuffers,
            deviceCount: deviceCount
        )
        let phase2cDuration = CFAbsoluteTimeGetCurrent() - phase2cTime

        // Extract results from GPU buffers
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        let result = try extractDBSCANResults(
            dbscanBuffers: dbscanBuffers,
            offlineFlagsBuffer: offlineFlagsBuffer,
            deviceCount: deviceCount,
            iterations: iterations,
            processingTime: processingTime
        )

        print("✅ GPU DBSCAN: Completed in \(String(format: "%.3f", processingTime * 1000))ms")
        print("   Phase 1: \(String(format: "%.3f", phase1Duration * 1000))ms (neighbor search)")
        print("   Phase 2a: \(String(format: "%.3f", phase2aDuration * 1000))ms (initialize labels)")
        print("   Phase 2b: \(String(format: "%.3f", propagationDuration * 1000))ms (propagation, \(iterations) iterations)")
        print("   Phase 2c: \(String(format: "%.3f", phase2cDuration * 1000))ms (finalize labels)")
        print("   Results: \(result.clusterCount) clusters, \(result.corePoints) core points, \(result.noisePoints) noise")
        print("   Memory: \(memoryUsage.description)")

        return result
    }

    // MARK: - GPU Memory Monitoring

    private func getGPUMemoryUsage(deviceCount: Int) -> GPUMemoryUsage {
        // Calculate memory usage for typical DBSCAN buffers
        let coordsBufferSize = deviceCount * MemoryLayout<SIMD2<Float>>.size
        let dbscanBufferSize = calculateDBSCANBufferSize(deviceCount: deviceCount)

        return GPUMemoryUsage(
            totalBufferMemory: coordsBufferSize + dbscanBufferSize,
            coordsBufferMemory: coordsBufferSize,
            dbscanBufferMemory: dbscanBufferSize,
            deviceCount: deviceCount
        )
    }

    private func calculateDBSCANBufferSize(deviceCount: Int) -> Int {
        let clusterLabelsSize = deviceCount * MemoryLayout<Int32>.size
        let neighborCountsSize = deviceCount * MemoryLayout<Int32>.size
        let corePointsSize = deviceCount * MemoryLayout<Bool>.size
        let changedFlagSize = MemoryLayout<Int32>.size

        return clusterLabelsSize + neighborCountsSize + corePointsSize + changedFlagSize
    }

    // MARK: - DBSCAN Kernel Execution Methods (Phase 2)

    internal func executeDBSCANNeighborSearchKernel(
        coordsBuffer: MTLBuffer,
        offlineFlagsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        dbscanParams: DBSCANParameters,
        dbscanBuffers: GPUDBSCANBuffers,
        deviceCount: Int
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "dbscanNeighborSearchKernel")
        computeEncoder.setComputePipelineState(pipelineState)

        // Set buffers
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(offlineFlagsBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.rawPointIndices, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.rawCellOffsets, offset: 0, index: 3)
        computeEncoder.setBuffer(grid.rawCellCounts, offset: 0, index: 4)
        computeEncoder.setBuffer(dbscanBuffers.rawNeighborCounts, offset: 0, index: 5)
        computeEncoder.setBuffer(dbscanBuffers.rawCorePoints, offset: 0, index: 6)

        // Set parameters
        var gridParamsVar = gridParams
        computeEncoder.setBytes(&gridParamsVar, length: MemoryLayout<GridIndexParameters>.size, index: 7)
        var dbscanParamsVar = dbscanParams
        computeEncoder.setBytes(&dbscanParamsVar, length: MemoryLayout<DBSCANParameters>.size, index: 8)

        // Dispatch threads
        let threadsPerGrid = MTLSize(width: deviceCount, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }

    private func executeDBSCANInitializeLabelsKernel(
        offlineFlagsBuffer: MTLBuffer,
        dbscanBuffers: GPUDBSCANBuffers,
        deviceCount: Int
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "dbscanInitializeLabelsKernel")
        computeEncoder.setComputePipelineState(pipelineState)

        // Set buffers
        computeEncoder.setBuffer(offlineFlagsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(dbscanBuffers.rawCorePoints, offset: 0, index: 1)
        computeEncoder.setBuffer(dbscanBuffers.rawClusterLabels, offset: 0, index: 2)
        computeEncoder.setBuffer(dbscanBuffers.rawChangedFlag, offset: 0, index: 3)

        // Dispatch threads
        let threadsPerGrid = MTLSize(width: deviceCount, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }

    private func executeDBSCANLabelPropagation(
        coordsBuffer: MTLBuffer,
        offlineFlagsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        dbscanParams: DBSCANParameters,
        dbscanBuffers: GPUDBSCANBuffers,
        deviceCount: Int
    ) throws -> Int {
        let maxIterations = 50
        var iterations = 0

        let pipelineState = try getOrCreatePipelineState(functionName: "dbscanLabelPropagationKernel")

        print("   🔄 Starting DBSCAN label propagation (max \(maxIterations) iterations)...")
        let startTime = CFAbsoluteTimeGetCurrent()

        for iteration in 0..<maxIterations {
            // Reset changed flag
            memset(dbscanBuffers.changedFlag.contents, 0, MemoryLayout<Int32>.size)

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw MetalTransformError.commandBufferCreationFailed
            }

            computeEncoder.setComputePipelineState(pipelineState)

            // Set buffers
            computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(offlineFlagsBuffer, offset: 0, index: 1)
            computeEncoder.setBuffer(dbscanBuffers.rawCorePoints, offset: 0, index: 2)
            computeEncoder.setBuffer(grid.rawPointIndices, offset: 0, index: 3)
            computeEncoder.setBuffer(grid.rawCellOffsets, offset: 0, index: 4)
            computeEncoder.setBuffer(grid.rawCellCounts, offset: 0, index: 5)
            computeEncoder.setBuffer(dbscanBuffers.rawClusterLabels, offset: 0, index: 6)
            computeEncoder.setBuffer(dbscanBuffers.rawChangedFlag, offset: 0, index: 7)

            // Set parameters
            var gridParamsVar = gridParams
            computeEncoder.setBytes(&gridParamsVar, length: MemoryLayout<GridIndexParameters>.size, index: 8)
            var dbscanParamsVar = dbscanParams
            computeEncoder.setBytes(&dbscanParamsVar, length: MemoryLayout<DBSCANParameters>.size, index: 9)

            // Dispatch threads
            let threadsPerGrid = MTLSize(width: deviceCount, height: 1, depth: 1)
            computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            computeEncoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            if let error = commandBuffer.error {
                throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
            }

            // Check convergence
            let changedFlagPointer = dbscanBuffers.changedFlag.contents.bindMemory(to: Int32.self, capacity: 1)
            let changed = changedFlagPointer[0]

            iterations = iteration + 1

            // Log progress periodically for long-running clusters
            if iteration > 0 && iteration % 10 == 0 {
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                print("      Iteration \(iteration): labels still propagating (\(String(format: "%.1f", elapsed * 1000))ms elapsed)")
            }

            if changed == 0 {
                break // Converged
            }
        }

        let propagationTime = CFAbsoluteTimeGetCurrent() - startTime

        if iterations >= maxIterations {
            print("   ⚠️  WARNING: DBSCAN label propagation reached maximum iterations (\(maxIterations)) without convergence")
            print("      This may indicate complex clustering topology or inadequate epsilon/minPoints parameters")
            print("      Processing time: \(String(format: "%.3f", propagationTime * 1000))ms")
        } else {
            print("   ✅ DBSCAN label propagation converged in \(iterations) iterations (\(String(format: "%.3f", propagationTime * 1000))ms)")
        }

        return iterations
    }

    private func executeDBSCANFinalizeLabelsKernel(
        offlineFlagsBuffer: MTLBuffer,
        dbscanBuffers: GPUDBSCANBuffers,
        deviceCount: Int
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        let pipelineState = try getOrCreatePipelineState(functionName: "dbscanFinalizeLabelsKernel")
        computeEncoder.setComputePipelineState(pipelineState)

        // Set buffers
        computeEncoder.setBuffer(offlineFlagsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(dbscanBuffers.rawClusterLabels, offset: 0, index: 1)

        // Dispatch threads
        let threadsPerGrid = MTLSize(width: deviceCount, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw MetalTransformError.gpuExecutionFailed(error.localizedDescription)
        }
    }

    private func extractDBSCANResults(
        dbscanBuffers: GPUDBSCANBuffers,
        offlineFlagsBuffer: MTLBuffer,
        deviceCount: Int,
        iterations: Int,
        processingTime: Double
    ) throws -> DBSCANResult {
        // Read labels from GPU buffer
        let labelsPointer = dbscanBuffers.clusterLabels.contents.bindMemory(to: Int32.self, capacity: deviceCount)
        let labels = Array(UnsafeBufferPointer(start: labelsPointer, count: deviceCount))

        // Read core points flag
        let corePointsPointer = dbscanBuffers.corePoints.contents.bindMemory(to: Bool.self, capacity: deviceCount)
        let corePointsFlags = Array(UnsafeBufferPointer(start: corePointsPointer, count: deviceCount))

        // Read offline flags
        let offlineFlagsPointer = offlineFlagsBuffer.contents().bindMemory(to: Bool.self, capacity: deviceCount)
        let offlineFlags = Array(UnsafeBufferPointer(start: offlineFlagsPointer, count: deviceCount))

        // Count statistics
        var uniqueLabels = Set<Int32>()
        var noisePoints = 0
        var corePoints = 0

        for i in 0..<deviceCount {
            if offlineFlags[i] {
                if labels[i] == -1 {
                    noisePoints += 1
                } else {
                    uniqueLabels.insert(labels[i])
                }

                if corePointsFlags[i] {
                    corePoints += 1
                }
            }
        }

        let clusterCount = uniqueLabels.count

        // Calculate memory usage
        let labelBufferSize = deviceCount * MemoryLayout<Int32>.size
        let boolBufferSize = deviceCount * MemoryLayout<Bool>.size
        let totalMemory = labelBufferSize * 3 + boolBufferSize * 2 + MemoryLayout<Int32>.size

        return DBSCANResult(
            labels: labels,
            clusterCount: clusterCount,
            noisePoints: noisePoints,
            corePoints: corePoints,
            iterations: iterations,
            processingTime: processingTime,
            memoryUsed: totalMemory
        )
    }

    /// Get or create pipeline state for a specific function (with caching)
    private func getOrCreatePipelineState(functionName: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: functionName) else {
            throw MetalTransformError.functionNotFound(functionName)
        }

        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw MetalTransformError.pipelineStateCreationFailed(error.localizedDescription)
        }
    }


    // MARK: - Static Factory Methods

    private static func createMetalLibrary(device: MTLDevice) throws -> MTLLibrary {
        let source = MetalShaderLibrary.coordinateTransformShaders
        
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw MetalTransformError.shaderCompilationFailed(error.localizedDescription)
        }
    }
    
    private static func createPipelineState(library: MTLLibrary, functionName: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: functionName) else {
            throw MetalTransformError.functionNotFound(functionName)
        }
        
        do {
            return try library.device.makeComputePipelineState(function: function)
        } catch {
            throw MetalTransformError.pipelineStateCreationFailed(error.localizedDescription)
        }
    }
}

// MARK: - Parameter Structures for GPU

private struct NZTMParameters {
    let centralMeridian: Float
    let falseEasting: Float
    let falseNorthing: Float
    let scaleFactor: Float
}

private struct WebMercatorParameters {
    let earthRadius: Float
    let maxLatitude: Float
}

private struct UTMParameters {
    let zone: Int32
    let centralMeridian: Float
    let falseEasting: Float
    let scaleFactor: Float
    let falseNorthing: Float
}

// MARK: - GPU Grid Index Structures

/// GPU grid indexing parameters
public struct GridIndexParameters: Sendable {
    let minX: Float
    let minY: Float
    let cellSize: Float
    let gridWidth: Int32
    let gridHeight: Int32
    let epsilon: Float  // Search radius for neighbor queries

    public init(bounds: SpatialBounds, cellSize: Float, epsilon: Float) {
        self.minX = Float(bounds.minX)
        self.minY = Float(bounds.minY)
        self.cellSize = cellSize
        self.gridWidth = Int32(ceil((bounds.maxX - bounds.minX) / Double(cellSize)))
        self.gridHeight = Int32(ceil((bounds.maxY - bounds.minY) / Double(cellSize)))
        self.epsilon = epsilon
    }
}

/// GPU grid index result for a single device
public struct GPUNeighborResult: Sendable {
    let deviceIndex: Int32  // Index of the device
    let neighborCount: Int32  // Number of neighbors found
    let cellX: Int32
    let cellY: Int32
}

/// Spatial bounds helper structure
public struct SpatialBounds: Sendable {
    public let minX, maxX, minY, maxY: Double

    public init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    /// Create bounds from projected coordinates with padding
    public static func from(coordinates: [ProjectedCoordinate], padding: Double = 1000.0) -> SpatialBounds {
        guard !coordinates.isEmpty else {
            return SpatialBounds(minX: 0, maxX: 1000, minY: 0, maxY: 1000)
        }

        let minX = coordinates.map(\.x).min()! - padding
        let maxX = coordinates.map(\.x).max()! + padding
        let minY = coordinates.map(\.y).min()! - padding
        let maxY = coordinates.map(\.y).max()! + padding

        return SpatialBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }
}

/// GPU grid structure for efficient neighbor search
public struct GPUGrid: Sendable {
    let cellOffsets: SendableBuffer    // Int[gridWidth*gridHeight] - start index in pointIndices
    let cellCounts: SendableBuffer     // Int[gridWidth*gridHeight] - num points in cell
    let pointIndices: SendableBuffer   // Int[totalOffline] - sorted device indices by cell
    let cellPositions: SendableBuffer  // Int[gridWidth*gridHeight] - temp for atomic append

    init(device: MTLDevice, gridSize: Int, totalPoints: Int) throws {
        guard let cellOffsetsBuffer = device.makeBuffer(
            length: gridSize * MemoryLayout<Int32>.size,
            options: .storageModeShared
        ),
        let cellCountsBuffer = device.makeBuffer(
            length: gridSize * MemoryLayout<Int32>.size,
            options: .storageModeShared
        ),
        let pointIndicesBuffer = device.makeBuffer(
            length: totalPoints * MemoryLayout<Int32>.size,
            options: .storageModeShared
        ),
        let cellPositionsBuffer = device.makeBuffer(
            length: gridSize * MemoryLayout<Int32>.size,
            options: .storageModeShared
        ) else {
            throw MetalTransformError.gpuExecutionFailed("Failed to create GPU grid buffers")
        }

        self.cellOffsets = SendableBuffer(cellOffsetsBuffer)
        self.cellCounts = SendableBuffer(cellCountsBuffer)
        self.pointIndices = SendableBuffer(pointIndicesBuffer)
        self.cellPositions = SendableBuffer(cellPositionsBuffer)

        // Initialize buffers to zero
        memset(cellCountsBuffer.contents(), 0, gridSize * MemoryLayout<Int32>.size)
        memset(cellOffsetsBuffer.contents(), 0, gridSize * MemoryLayout<Int32>.size)
        memset(cellPositionsBuffer.contents(), 0, gridSize * MemoryLayout<Int32>.size)
    }

    // Helper methods to unwrap for kernel use
    var rawCellOffsets: MTLBuffer { cellOffsets.buffer }
    var rawCellCounts: MTLBuffer { cellCounts.buffer }
    var rawPointIndices: MTLBuffer { pointIndices.buffer }
    var rawCellPositions: MTLBuffer { cellPositions.buffer }
}

// MARK: - GPU DBSCAN Structures (Phase 2)

/// DBSCAN parameters for GPU clustering
public struct DBSCANParameters: Sendable {
    let epsilon: Float              // Search radius in projected meters
    let minPoints: Int32            // Minimum points to form a cluster
    let aggregationThreshold: Int32  // Privacy threshold for cluster filtering

    public init(epsilon: Double = 500.0, minPoints: Int = 3, aggregationThreshold: Int = 5) {
        self.epsilon = Float(epsilon)
        self.minPoints = Int32(minPoints)
        self.aggregationThreshold = Int32(aggregationThreshold)
    }
}

/// GPU DBSCAN clustering result
public struct DBSCANResult: Sendable {
    public let labels: [Int32]              // Cluster labels (-1 for noise)
    public let clusterCount: Int            // Number of valid clusters found
    public let noisePoints: Int             // Number of noise points
    public let corePoints: Int              // Number of core points
    public let iterations: Int              // Iterations to convergence
    public let processingTime: Double       // Total GPU processing time
    public let memoryUsed: Int             // GPU memory used in bytes

    public init(labels: [Int32], clusterCount: Int, noisePoints: Int, corePoints: Int,
                iterations: Int, processingTime: Double, memoryUsed: Int) {
        self.labels = labels
        self.clusterCount = clusterCount
        self.noisePoints = noisePoints
        self.corePoints = corePoints
        self.iterations = iterations
        self.processingTime = processingTime
        self.memoryUsed = memoryUsed
    }
}

/// Result structure for Phase 3 GPU hull and confidence computation
public struct GPUHullAndConfidenceResult: Sendable {
    public let hullBuffers: GPUHullBuffers
    public let sortTime: Double
    public let hullTime: Double
    public let confidenceTime: Double
    public let totalTime: Double
    public let clustersProcessed: Int

    public init(hullBuffers: GPUHullBuffers, sortTime: Double, hullTime: Double,
                confidenceTime: Double, totalTime: Double, clustersProcessed: Int) {
        self.hullBuffers = hullBuffers
        self.sortTime = sortTime
        self.hullTime = hullTime
        self.confidenceTime = confidenceTime
        self.totalTime = totalTime
        self.clustersProcessed = clustersProcessed
    }
}

/// Phase 3 parameters structure for Metal kernels
private struct Phase3Parameters {
    let clustersCount: Int32
    let maxPointsPerCluster: Int32
    let maxHullVertices: Int32
    let epsilon: Float
    let minTotalDevices: Int32
    let gridCellSize: Float
    let gridWidth: Int32
    let gridHeight: Int32
    let collinearThreshold: Float
}

/// GPU buffers for DBSCAN clustering
public struct GPUDBSCANBuffers: Sendable {
    let clusterLabels: SendableBuffer    // Int32[deviceCount] - cluster IDs (-1 for noise)
    let corePoints: SendableBuffer       // Bool[deviceCount] - marks core points
    let neighborCounts: SendableBuffer   // Int32[deviceCount] - neighbor counts per point
    let changedFlag: SendableBuffer      // atomic_int - convergence detection flag
    let tempLabels: SendableBuffer       // Int32[deviceCount] - temporary labels for updates

    init(device: MTLDevice, deviceCount: Int) throws {
        let labelBufferLength = deviceCount * MemoryLayout<Int32>.size
        let boolBufferLength = deviceCount * MemoryLayout<Bool>.size
        let flagBufferLength = MemoryLayout<Int32>.size

        guard let clusterLabelsBuffer = device.makeBuffer(
                length: labelBufferLength, options: .storageModeShared),
              let corePointsBuffer = device.makeBuffer(
                length: boolBufferLength, options: .storageModeShared),
              let neighborCountsBuffer = device.makeBuffer(
                length: labelBufferLength, options: .storageModeShared),
              let changedFlagBuffer = device.makeBuffer(
                length: flagBufferLength, options: .storageModeShared),
              let tempLabelsBuffer = device.makeBuffer(
                length: labelBufferLength, options: .storageModeShared) else {
            throw MetalTransformError.gpuExecutionFailed("Failed to create DBSCAN buffers")
        }

        self.clusterLabels = SendableBuffer(clusterLabelsBuffer)
        self.corePoints = SendableBuffer(corePointsBuffer)
        self.neighborCounts = SendableBuffer(neighborCountsBuffer)
        self.changedFlag = SendableBuffer(changedFlagBuffer)
        self.tempLabels = SendableBuffer(tempLabelsBuffer)

        // Initialize buffers
        memset(clusterLabelsBuffer.contents(), -1, labelBufferLength)  // -1 for noise/unprocessed
        memset(corePointsBuffer.contents(), 0, boolBufferLength)       // false for non-core
        memset(neighborCountsBuffer.contents(), 0, labelBufferLength)  // zero neighbors initially
        memset(changedFlagBuffer.contents(), 0, flagBufferLength)      // no changes initially
        memset(tempLabelsBuffer.contents(), -1, labelBufferLength)     // -1 for temp labels
    }

    // Helper methods to unwrap for kernel use
    var rawClusterLabels: MTLBuffer { clusterLabels.buffer }
    var rawCorePoints: MTLBuffer { corePoints.buffer }
    var rawNeighborCounts: MTLBuffer { neighborCounts.buffer }
    var rawChangedFlag: MTLBuffer { changedFlag.buffer }
    var rawTempLabels: MTLBuffer { tempLabels.buffer }

    /// Release GPU memory for cleanup
    func releaseBuffers() {
        // Metal buffers are automatically released when deallocated
        // This method is for future memory management extensions
    }
}

/// GPU buffers for convex hull and confidence computation (Phase 3)
public struct GPUHullBuffers: Sendable {
    let clusterOffsets: SendableBuffer      // Int32[clusterCount * 2] - start/count pairs per cluster
    let hullVertices: SendableBuffer        // SIMD2<Float>[maxHullVertices] - flattened hull vertices
    let hullCounts: SendableBuffer          // Int32[clusterCount] - vertex count per hull
    let confidencePairs: SendableBuffer     // float2[clusterCount] - offline/total counts
    let tempSortBuffer: SendableBuffer      // SIMD2<Float>[maxPointsPerCluster] - temporary sort space

    init(device: MTLDevice, clusterCount: Int, maxPointsPerCluster: Int) throws {
        let clusterOffsetsLength = clusterCount * 2 * MemoryLayout<Int32>.size
        let maxHullVertices = clusterCount * min(maxPointsPerCluster, 512) // Increased cap for larger clusters
        let hullVerticesLength = maxHullVertices * MemoryLayout<SIMD2<Float>>.size
        let hullCountsLength = clusterCount * MemoryLayout<Int32>.size
        let confidencePairsLength = clusterCount * MemoryLayout<SIMD2<Float>>.size
        let tempSortLength = maxPointsPerCluster * MemoryLayout<SIMD2<Float>>.size

        guard let clusterOffsetsBuffer = device.makeBuffer(
                length: clusterOffsetsLength, options: .storageModeShared),
              let hullVerticesBuffer = device.makeBuffer(
                length: hullVerticesLength, options: .storageModeShared),
              let hullCountsBuffer = device.makeBuffer(
                length: hullCountsLength, options: .storageModeShared),
              let confidencePairsBuffer = device.makeBuffer(
                length: confidencePairsLength, options: .storageModeShared),
              let tempSortBuffer = device.makeBuffer(
                length: tempSortLength, options: .storageModeShared) else {
            throw MetalTransformError.gpuExecutionFailed("Failed to create hull buffers")
        }

        self.clusterOffsets = SendableBuffer(clusterOffsetsBuffer)
        self.hullVertices = SendableBuffer(hullVerticesBuffer)
        self.hullCounts = SendableBuffer(hullCountsBuffer)
        self.confidencePairs = SendableBuffer(confidencePairsBuffer)
        self.tempSortBuffer = SendableBuffer(tempSortBuffer)

        // Initialize buffers
        memset(clusterOffsetsBuffer.contents(), 0, clusterOffsetsLength)
        memset(hullVerticesBuffer.contents(), 0, hullVerticesLength)
        memset(hullCountsBuffer.contents(), 0, hullCountsLength)
        memset(confidencePairsBuffer.contents(), 0, confidencePairsLength)
        memset(tempSortBuffer.contents(), 0, tempSortLength)
    }

    // Helper methods to unwrap for kernel use
    var rawClusterOffsets: MTLBuffer { clusterOffsets.buffer }
    var rawHullVertices: MTLBuffer { hullVertices.buffer }
    var rawHullCounts: MTLBuffer { hullCounts.buffer }
    var rawConfidencePairs: MTLBuffer { confidencePairs.buffer }
    var rawTempSortBuffer: MTLBuffer { tempSortBuffer.buffer }

    /// Release GPU memory for cleanup
    func releaseBuffers() {
        // Metal buffers are automatically released when deallocated
        // Memory management tracking can be added here in future
    }
}

// MARK: - Metal Shader Library

private struct MetalShaderLibrary {
    static let coordinateTransformShaders = """
#include <metal_stdlib>
using namespace metal;

struct NZTMParameters {
    float centralMeridian;
    float falseEasting;
    float falseNorthing;
    float scaleFactor;
};

struct WebMercatorParameters {
    float earthRadius;
    float maxLatitude;
};

struct UTMParameters {
    int zone;
    float centralMeridian;
    float falseEasting;
    float scaleFactor;
    float falseNorthing;
};

// MARK: - DBSCAN GPU Structures (Phase 2)

struct DBSCANParameters {
    float epsilon;
    int minPoints;
    int aggregationThreshold;
};

struct GPUNeighborResult {
    int deviceIndex;    // Index of the device
    int neighborCount;  // Number of neighbors found
    int cellX;
    int cellY;
};

// NZTM Transformation Kernel
kernel void nztm_transform(
    const device float2* input [[buffer(0)]],
    device float2* output [[buffer(1)]],
    constant NZTMParameters& params [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    float2 latLon = input[id];
    
    // Convert degrees to radians with high precision
    const float degToRad = 0x1.1df46ap-6f; // π/180 in hex float for precision
    float lat = latLon.x * degToRad;
    float lon = latLon.y * degToRad;
    float centralMeridianRad = params.centralMeridian * degToRad;
    
    // NZTM transformation optimized for GPU
    float deltaLon = lon - centralMeridianRad;
    float cosLat = cos(lat);
    
    // Use fast_math functions for GPU optimization
    float x = params.falseEasting + (params.scaleFactor * 6378137.0f * deltaLon * cosLat);
    float y = params.falseNorthing + (params.scaleFactor * 6378137.0f * lat);
    
    output[id] = float2(x, y);
}

// Web Mercator Transformation Kernel
kernel void web_mercator_transform(
    const device float2* input [[buffer(0)]],
    device float2* output [[buffer(1)]],
    constant WebMercatorParameters& params [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    float2 latLon = input[id];
    
    // Clamp latitude to Web Mercator limits
    float lat = clamp(latLon.x, -params.maxLatitude, params.maxLatitude);
    float lon = latLon.y;
    
    const float degToRad = 0x1.1df46ap-6f;
    
    // Web Mercator transformation
    float x = lon * params.earthRadius * degToRad;
    float y = params.earthRadius * log(tan(0x1.921fb6p-2f + lat * 0x1.1df46ap-7f)); // π/4 + lat*π/360
    
    output[id] = float2(x, y);
}

// UTM Transformation Kernel
kernel void utm_transform(
    const device float2* input [[buffer(0)]],
    device float2* output [[buffer(1)]],
    constant UTMParameters& params [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    float2 latLon = input[id];

    const float degToRad = 0x1.1df46ap-6f;
    float lat = latLon.x * degToRad;
    float lon = latLon.y * degToRad;
    float centralMeridianRad = params.centralMeridian * degToRad;

    // UTM transformation using proper hemisphere handling
    float deltaLon = lon - centralMeridianRad;
    float cosLat = cos(lat);

    // Use falseNorthing from parameters (0 for northern, 10000000 for southern hemisphere)
    float x = params.falseEasting + (params.scaleFactor * 6378137.0f * deltaLon * cosLat);
    float y = params.falseNorthing + (params.scaleFactor * 6378137.0f * lat);

    output[id] = float2(x, y);
}

// MARK: - GPU Grid Index Kernel

struct GridIndexParameters {
    float minX;
    float minY;
    float cellSize;
    int gridWidth;
    int gridHeight;
    float epsilon;
};

// GPU Grid Pass 1: Count points per cell (atomic)
kernel void gridCountPass(
    const device float2* coords [[buffer(0)]],
    device atomic_int* cellCounts [[buffer(1)]],
    constant GridIndexParameters& params [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    float2 p = coords[id];
    int cx = int((p.x - params.minX) / params.cellSize);
    int cy = int((p.y - params.minY) / params.cellSize);
    cx = max(0, min(cx, params.gridWidth - 1));
    cy = max(0, min(cy, params.gridHeight - 1));

    int cellIdx = cy * params.gridWidth + cx;
    atomic_fetch_add_explicit(&cellCounts[cellIdx], 1, memory_order_relaxed);
}

// GPU Grid Pass 1 with Flags: Count offline points per cell (atomic)
kernel void gridCountPassWithFlags(
    const device float2* coords [[buffer(0)]],
    const device bool* offlineFlags [[buffer(1)]],
    device atomic_int* cellCounts [[buffer(2)]],
    constant GridIndexParameters& params [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    // Only process offline devices
    if (!offlineFlags[id]) return;

    float2 p = coords[id];
    int cx = int((p.x - params.minX) / params.cellSize);
    int cy = int((p.y - params.minY) / params.cellSize);
    cx = max(0, min(cx, params.gridWidth - 1));
    cy = max(0, min(cy, params.gridHeight - 1));

    int cellIdx = cy * params.gridWidth + cx;
    atomic_fetch_add_explicit(&cellCounts[cellIdx], 1, memory_order_relaxed);
}

// GPU Grid Pass 2: Build sorted point lists per cell
kernel void gridBuildPass(
    const device float2* coords [[buffer(0)]],
    device int* pointIndices [[buffer(1)]],
    const device int* cellOffsets [[buffer(2)]],
    device atomic_int* cellPositions [[buffer(3)]],
    constant GridIndexParameters& params [[buffer(4)]],
    const device int* localIndices [[buffer(5)]], // CRITICAL FIX: Local device indices buffer
    uint id [[thread_position_in_grid]]
) {
    float2 p = coords[id]; // id is local to offline devices (0..<offlineCount)
    int cx = int((p.x - params.minX) / params.cellSize);
    int cy = int((p.y - params.minY) / params.cellSize);
    cx = max(0, min(cx, params.gridWidth - 1));
    cy = max(0, min(cy, params.gridHeight - 1));

    int cellIdx = cy * params.gridWidth + cx;
    int pos = atomic_fetch_add_explicit(&cellPositions[cellIdx], 1, memory_order_relaxed);

    // CRITICAL FIX: Store the local index (should just be id for offline-only coords)
    pointIndices[cellOffsets[cellIdx] + pos] = localIndices[id]; // This should just be = int(id)
}

// GPU Grid Pass 2 with Flags: Build sorted point lists per cell (offline only)
kernel void gridBuildPassWithFlags(
    const device float2* coords [[buffer(0)]],
    const device bool* offlineFlags [[buffer(1)]],
    device int* pointIndices [[buffer(2)]],
    const device int* cellOffsets [[buffer(3)]],
    device atomic_int* cellPositions [[buffer(4)]],
    constant GridIndexParameters& params [[buffer(5)]],
    uint id [[thread_position_in_grid]]
) {
    // Only process offline devices
    if (!offlineFlags[id]) return;

    float2 p = coords[id]; // id is global device index
    int cx = int((p.x - params.minX) / params.cellSize);
    int cy = int((p.y - params.minY) / params.cellSize);
    cx = max(0, min(cx, params.gridWidth - 1));
    cy = max(0, min(cy, params.gridHeight - 1));

    int cellIdx = cy * params.gridWidth + cx;
    int pos = atomic_fetch_add_explicit(&cellPositions[cellIdx], 1, memory_order_relaxed);

    // Store the global device index for full coordinate buffer compatibility
    pointIndices[cellOffsets[cellIdx] + pos] = int(id);
}

// GPU Grid-Based Neighbor Counting - O(N * avg_cell_size) instead of O(N²)
kernel void countNeighborsGrid(
    const device float2* coords [[buffer(0)]],
    const device int* pointIndices [[buffer(1)]],
    const device int* cellOffsets [[buffer(2)]],
    const device int* cellCounts [[buffer(3)]],
    device GPUNeighborResult* results [[buffer(4)]],
    const device int* deviceIndices [[buffer(5)]],
    constant GridIndexParameters& params [[buffer(6)]],
    constant uint& totalCount [[buffer(7)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= totalCount) return;

    float2 coord = coords[id];
    int deviceIndex = deviceIndices[id];

    // Calculate grid cell for this device
    int cx = int((coord.x - params.minX) / params.cellSize);
    int cy = int((coord.y - params.minY) / params.cellSize);
    cx = max(0, min(cx, params.gridWidth - 1));
    cy = max(0, min(cy, params.gridHeight - 1));

    int neighborCount = 0;
    float epsilonSquared = params.epsilon * params.epsilon;

    // Scan 3x3 neighborhood of cells (9-cell scan for epsilon coverage)
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int nx = cx + dx;
            int ny = cy + dy;
            if (nx < 0 || nx >= params.gridWidth || ny < 0 || ny >= params.gridHeight) continue;

            int cellIdx = ny * params.gridWidth + nx;
            int start = cellOffsets[cellIdx];
            int count = cellCounts[cellIdx];

            // Check all points in this neighboring cell
            for (int j = 0; j < count; j++) {
                int otherId = pointIndices[start + j];
                if (otherId == int(id)) continue; // Skip self

                float2 other = coords[otherId];
                float dx_dist = coord.x - other.x;
                float dy_dist = coord.y - other.y;
                float distanceSquared = dx_dist * dx_dist + dy_dist * dy_dist;

                if (distanceSquared <= epsilonSquared) {
                    neighborCount++;
                }
            }
        }
    }

    // Store results
    results[id].deviceIndex = deviceIndex;
    results[id].neighborCount = neighborCount;
    results[id].cellX = cx;
    results[id].cellY = cy;
}


// On-demand neighbor search kernel for findNeighbors queries
kernel void findNeighborsKernel(
    const device float2* coords [[buffer(0)]],
    const device int* pointIndices [[buffer(1)]],
    const device int* cellOffsets [[buffer(2)]],
    const device int* cellCounts [[buffer(3)]],
    device int* outputNeighbors [[buffer(4)]],
    device atomic_int* outputCount [[buffer(5)]],
    constant GridIndexParameters& params [[buffer(6)]],
    constant int& queryId [[buffer(7)]],
    uint tid [[thread_position_in_grid]]
) {
    // Each thread processes one neighboring cell (9 threads total for 3x3 grid)
    if (tid >= 9) return;

    // Get query coordinate and compute its grid cell
    float2 queryCoord = coords[queryId];
    int cx = int((queryCoord.x - params.minX) / params.cellSize);
    int cy = int((queryCoord.y - params.minY) / params.cellSize);

    // Calculate which neighboring cell this thread processes
    int dx = int(tid % 3) - 1; // -1, 0, 1
    int dy = int(tid / 3) - 1; // -1, 0, 1
    int nx = cx + dx;
    int ny = cy + dy;

    // Check bounds
    if (nx < 0 || nx >= params.gridWidth || ny < 0 || ny >= params.gridHeight) return;

    // Get cell data
    int cellIdx = ny * params.gridWidth + nx;
    int start = cellOffsets[cellIdx];
    int count = cellCounts[cellIdx];

    float epsilonSquared = params.epsilon * params.epsilon;

    // Check all points in this cell
    for (int j = 0; j < count; j++) {
        int otherId = pointIndices[start + j];
        if (otherId == queryId) continue; // Skip self

        float2 otherCoord = coords[otherId];
        float2 diff = queryCoord - otherCoord;
        float distanceSquared = dot(diff, diff);

        if (distanceSquared <= epsilonSquared) {
            // Atomically add to output
            int pos = atomic_fetch_add_explicit(outputCount, 1, memory_order_relaxed);
            if (pos < 1000) { // Safety limit - adjust based on expected max neighbors
                outputNeighbors[pos] = otherId;
            }
        }
    }
}

// MARK: - DBSCAN GPU Kernels (Phase 2)

// DBSCAN Phase 1: Neighbor search with core point detection
// Fused kernel that counts neighbors and marks core points in one pass
kernel void dbscanNeighborSearchKernel(
    const device float2* coords [[buffer(0)]],              // All device coordinates
    const device bool* offlineFlags [[buffer(1)]],          // Offline status flags
    const device int* pointIndices [[buffer(2)]],           // Grid point indices
    const device int* cellOffsets [[buffer(3)]],            // Grid cell offsets
    const device int* cellCounts [[buffer(4)]],             // Grid cell counts
    device int* neighborCounts [[buffer(5)]],               // Output: neighbor counts
    device bool* corePoints [[buffer(6)]],                  // Output: core point flags
    constant GridIndexParameters& gridParams [[buffer(7)]], // Grid parameters
    constant DBSCANParameters& dbscanParams [[buffer(8)]],  // DBSCAN parameters
    uint id [[thread_position_in_grid]]
) {
    // Only process offline devices
    if (!offlineFlags[id]) {
        neighborCounts[id] = 0;
        corePoints[id] = false;
        return;
    }

    float2 coord = coords[id];

    // Calculate grid cell for this device
    int cx = int((coord.x - gridParams.minX) / gridParams.cellSize);
    int cy = int((coord.y - gridParams.minY) / gridParams.cellSize);
    cx = max(0, min(cx, gridParams.gridWidth - 1));
    cy = max(0, min(cy, gridParams.gridHeight - 1));

    int neighborCount = 0;
    float epsilonSquared = dbscanParams.epsilon * dbscanParams.epsilon;

    // Scan 3x3 neighborhood of cells for neighbors
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int nx = cx + dx;
            int ny = cy + dy;
            if (nx < 0 || nx >= gridParams.gridWidth || ny < 0 || ny >= gridParams.gridHeight) continue;

            int cellIdx = ny * gridParams.gridWidth + nx;
            int start = cellOffsets[cellIdx];
            int count = cellCounts[cellIdx];

            // Check all points in this neighboring cell
            for (int j = 0; j < count; j++) {
                int otherId = pointIndices[start + j];
                if (otherId == int(id)) continue; // Skip self

                // Only count offline neighbors (density-connected clustering)
                if (!offlineFlags[otherId]) continue;

                float2 otherCoord = coords[otherId];
                float dx_dist = coord.x - otherCoord.x;
                float dy_dist = coord.y - otherCoord.y;
                float distanceSquared = dx_dist * dx_dist + dy_dist * dy_dist;

                if (distanceSquared <= epsilonSquared) {
                    neighborCount++;
                }
            }
        }
    }

    // Store neighbor count and determine if this is a core point
    neighborCounts[id] = neighborCount;
    corePoints[id] = (neighborCount >= dbscanParams.minPoints);
}

// DBSCAN Phase 2a: Initialize cluster labels for core points
kernel void dbscanInitializeLabelsKernel(
    const device bool* offlineFlags [[buffer(0)]],          // Offline status flags
    const device bool* corePoints [[buffer(1)]],            // Core point flags
    device int* clusterLabels [[buffer(2)]],                // Output: initial cluster labels
    device atomic_int* changedFlag [[buffer(3)]],           // Changed flag for convergence
    uint id [[thread_position_in_grid]]
) {
    if (!offlineFlags[id]) {
        clusterLabels[id] = -1; // Non-offline devices are noise
        return;
    }

    if (corePoints[id]) {
        // Core points get their own ID as initial cluster label
        clusterLabels[id] = int(id);
        atomic_store_explicit(changedFlag, 1, memory_order_relaxed); // Mark as changed for first iteration
    } else {
        // Non-core points start as noise (-1)
        clusterLabels[id] = -1;
    }
}

// DBSCAN Phase 2b: Label propagation with union-find
// Iteratively propagate cluster labels through offline connections
kernel void dbscanLabelPropagationKernel(
    const device float2* coords [[buffer(0)]],              // All device coordinates
    const device bool* offlineFlags [[buffer(1)]],          // Offline status flags
    const device bool* corePoints [[buffer(2)]],            // Core point flags
    const device int* pointIndices [[buffer(3)]],           // Grid point indices
    const device int* cellOffsets [[buffer(4)]],            // Grid cell offsets
    const device int* cellCounts [[buffer(5)]],             // Grid cell counts
    device atomic_int* clusterLabels [[buffer(6)]],         // Cluster labels (atomic for updates)
    device atomic_int* changedFlag [[buffer(7)]],           // Changed flag for convergence
    constant GridIndexParameters& gridParams [[buffer(8)]], // Grid parameters
    constant DBSCANParameters& dbscanParams [[buffer(9)]],  // DBSCAN parameters
    uint id [[thread_position_in_grid]]
) {
    // Only process offline devices
    if (!offlineFlags[id]) return;

    int currentLabel = atomic_load_explicit(&clusterLabels[id], memory_order_relaxed);

    // Skip if this device is still noise and not a core point
    if (currentLabel == -1 && !corePoints[id]) return;

    float2 coord = coords[id];

    // Calculate grid cell for this device
    int cx = int((coord.x - gridParams.minX) / gridParams.cellSize);
    int cy = int((coord.y - gridParams.minY) / gridParams.cellSize);
    cx = max(0, min(cx, gridParams.gridWidth - 1));
    cy = max(0, min(cy, gridParams.gridHeight - 1));

    float epsilonSquared = dbscanParams.epsilon * dbscanParams.epsilon;
    int minLabel = currentLabel == -1 ? INT_MAX : currentLabel;

    // Scan 3x3 neighborhood for connected components
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int nx = cx + dx;
            int ny = cy + dy;
            if (nx < 0 || nx >= gridParams.gridWidth || ny < 0 || ny >= gridParams.gridHeight) continue;

            int cellIdx = ny * gridParams.gridWidth + nx;
            int start = cellOffsets[cellIdx];
            int count = cellCounts[cellIdx];

            // Check all points in this neighboring cell
            for (int j = 0; j < count; j++) {
                int otherId = pointIndices[start + j];
                if (otherId == int(id)) continue; // Skip self

                // Only connect through offline devices
                if (!offlineFlags[otherId]) continue;

                float2 otherCoord = coords[otherId];
                float dx_dist = coord.x - otherCoord.x;
                float dy_dist = coord.y - otherCoord.y;
                float distanceSquared = dx_dist * dx_dist + dy_dist * dy_dist;

                if (distanceSquared <= epsilonSquared) {
                    int otherLabel = atomic_load_explicit(&clusterLabels[otherId], memory_order_relaxed);

                    // Union-find: merge clusters by finding minimum label
                    if (otherLabel != -1 && otherLabel < minLabel) {
                        minLabel = otherLabel;
                    }

                    // For non-core points, adopt label from any connected core point
                    if (!corePoints[id] && corePoints[otherId] && otherLabel != -1) {
                        minLabel = min(minLabel == INT_MAX ? otherLabel : minLabel, otherLabel);
                    }
                }
            }
        }
    }

    // Update label if we found a better (smaller) one
    if (minLabel != INT_MAX && minLabel != currentLabel) {
        int oldLabel = atomic_exchange_explicit(&clusterLabels[id], minLabel, memory_order_relaxed);
        if (oldLabel != minLabel) {
            atomic_store_explicit(changedFlag, 1, memory_order_relaxed);
        }
    }
}

// DBSCAN Phase 2c: Finalize labels with path compression
kernel void dbscanFinalizeLabelsKernel(
    const device bool* offlineFlags [[buffer(0)]],          // Offline status flags
    device int* clusterLabels [[buffer(1)]],                // Cluster labels to finalize
    uint id [[thread_position_in_grid]]
) {
    if (!offlineFlags[id]) {
        clusterLabels[id] = -1; // Ensure non-offline devices are noise
        return;
    }

    int label = clusterLabels[id];
    if (label == -1) return; // Already noise

    // Path compression: follow chain to find root label
    int root = label;
    while (root != int(id) && clusterLabels[root] != root && clusterLabels[root] != -1) {
        root = clusterLabels[root];
    }

    // Update with compressed path
    if (root != label) {
        clusterLabels[id] = root;
    }
}

// MARK: - Phase 3: Convex Hull and Confidence Computation
// Monotone Chain Algorithm adapted for GPU
// Reference: GPU Gems 2, Chapter 46 - Improved GPU Sorting
// Complexity: O(n log n) bitonic sort + O(n) hull construction per cluster

struct Phase3Parameters {
    int clustersCount;
    int maxPointsPerCluster;
    int maxHullVertices;
    float epsilon;               // Confidence expansion radius (500m)
    int minTotalDevices;         // Minimum devices for valid confidence (5)
    float gridCellSize;          // Reuse Phase 1 grid (~353m)
    int gridWidth;
    int gridHeight;
    float collinearThreshold;    // Epsilon for collinear point detection (1.0m)
};

// Helper: Cross product for orientation test (positive = CCW/left turn)
inline float cross2D(float2 a, float2 b, float2 c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

// Helper: Distance squared between two points
inline float distanceSquared(float2 a, float2 b) {
    float dx = b.x - a.x;
    float dy = b.y - a.y;
    return dx * dx + dy * dy;
}

// Custom atomic min for float2 (component-wise)
inline void atomic_min_float2(threadgroup float2* dest, float2 val) {
    threadgroup atomic_int* dest_x = (threadgroup atomic_int*)((threadgroup char*)dest);
    threadgroup atomic_int* dest_y = (threadgroup atomic_int*)((threadgroup char*)dest + sizeof(float));
    atomic_fetch_min_explicit(dest_x, as_type<int>(val.x), memory_order_relaxed);
    atomic_fetch_min_explicit(dest_y, as_type<int>(val.y), memory_order_relaxed);
}

// Custom atomic max for float2
inline void atomic_max_float2(threadgroup float2* dest, float2 val) {
    threadgroup atomic_int* dest_x = (threadgroup atomic_int*)((threadgroup char*)dest);
    threadgroup atomic_int* dest_y = (threadgroup atomic_int*)((threadgroup char*)dest + sizeof(float));
    atomic_fetch_max_explicit(dest_x, as_type<int>(val.x), memory_order_relaxed);
    atomic_fetch_max_explicit(dest_y, as_type<int>(val.y), memory_order_relaxed);
}

// Phase 3: Parallel multi-pass bitonic sort by X-coordinate with Y tiebreaker
// Threadgroup-only for sync; dispatch per cluster for large sets
kernel void bitonicSortByX(
    device float2* coordinates [[buffer(0)]],         // Coordinates to sort
    device int* clusterOffsets [[buffer(1)]],         // Start/count pairs per cluster
    device float2* tempWorkBuffer [[buffer(2)]],      // Global buffer for large clusters
    constant Phase3Parameters& params [[buffer(3)]],
    uint clusterIndex [[threadgroup_position_in_grid]],
    uint localIndex [[thread_position_in_threadgroup]],
    uint threadsPerGroup [[threads_per_threadgroup]]
) {
    if (clusterIndex >= uint(params.clustersCount)) return;

    int startIdx = clusterOffsets[clusterIndex * 2];
    int count = clusterOffsets[clusterIndex * 2 + 1];

    if (count < 3 || localIndex >= uint(count)) return;

    // Pad to power of 2 for bitonic (threadgroup size)
    uint paddedCount = 1u << uint(ceil(log2(float(threadsPerGroup))));

    threadgroup float2 sharedCoords[1024]; // Adjust to max threadsPerGroup

    // Load with padding (INF for sort stability)
    float2 coord = (localIndex < uint(count)) ? coordinates[startIdx + localIndex] : float2(INFINITY, INFINITY);
    sharedCoords[localIndex] = coord;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Bitonic sort phases (threadgroup sync)
    for (uint k = 2; k <= paddedCount; k <<= 1) {
        for (uint j = k >> 1; j > 0; j >>= 1) {
            uint ixj = localIndex ^ j;

            if (ixj > localIndex && ixj < paddedCount) {
                float2 a = sharedCoords[localIndex];
                float2 b = sharedCoords[ixj];

                // Sort by X, then Y
                bool shouldSwap = ((localIndex & k) == 0)
                    ? (a.x > b.x || (abs(a.x - b.x) < params.collinearThreshold && a.y > b.y))
                    : (a.x < b.x || (abs(a.x - b.x) < params.collinearThreshold && a.y < b.y));

                if (shouldSwap) {
                    sharedCoords[localIndex] = b;
                    sharedCoords[ixj] = a;
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
    }

    // Write back if within count
    if (localIndex < uint(count)) coordinates[startIdx + localIndex] = sharedCoords[localIndex];
}

// Phase 3: Parallel monotone chain hull with pruning
// Full threadgroup participation for pruning
kernel void buildConvexHullWithPruning(
    const device float2* sortedCoords [[buffer(0)]],    // X-sorted coordinates
    device float2* hullVertices [[buffer(1)]],          // Output hull vertices (flattened)
    device int* hullCounts [[buffer(2)]],               // Vertices per hull
    device int* clusterOffsets [[buffer(3)]],           // Start/count pairs per cluster
    device float2* tempHullBuffer [[buffer(4)]],        // Temp space for hull construction
    constant Phase3Parameters& params [[buffer(5)]],
    uint clusterIndex [[threadgroup_position_in_grid]],
    uint localIndex [[thread_position_in_threadgroup]],
    uint threadsPerGroup [[threads_per_threadgroup]]
) {
    if (clusterIndex >= uint(params.clustersCount)) return;

    int startIdx = clusterOffsets[clusterIndex * 2];
    int count = clusterOffsets[clusterIndex * 2 + 1];

    if (count < 3) {
        if (localIndex == 0) {
            hullCounts[clusterIndex] = 0;
        }
        return;
    }

    // Parallel segment building: Divide points across threads
    threadgroup float2 sharedLower[256];
    threadgroup float2 sharedUpper[256];
    threadgroup atomic_int sharedLowerCount;
    threadgroup atomic_int sharedUpperCount;

    if (localIndex == 0) {
        atomic_store_explicit(&sharedLowerCount, 0, memory_order_relaxed);
        atomic_store_explicit(&sharedUpperCount, 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Parallel lower hull: Left-to-right, prune per segment
    for (uint i = localIndex; i < uint(count); i += threadsPerGroup) {
        float2 point = sortedCoords[startIdx + i];

        // Atomic pruning with compare-and-swap loop (safety cap to prevent infinite loops)
        int loopCount = 0;
        while (loopCount < 1000) { // Safety cap: max 1000 iterations
            loopCount++;
            int currentCount = atomic_load_explicit(&sharedLowerCount, memory_order_relaxed);
            if (currentCount < 2) {
                // Can add point directly
                int pos = atomic_fetch_add_explicit(&sharedLowerCount, 1, memory_order_relaxed);
                if (pos < 256) sharedLower[pos] = point;
                break;
            } else {
                // Check if point creates right turn
                float cross = cross2D(sharedLower[currentCount-2], sharedLower[currentCount-1], point);
                if (cross <= params.collinearThreshold) {
                    // Try to remove last point
                    if (atomic_compare_exchange_weak_explicit(&sharedLowerCount, &currentCount, currentCount-1, memory_order_relaxed, memory_order_relaxed)) {
                        continue; // Successfully removed, check again
                    }
                } else {
                    // Point is valid, add it
                    int pos = atomic_fetch_add_explicit(&sharedLowerCount, 1, memory_order_relaxed);
                    if (pos < 256) sharedLower[pos] = point;
                    break;
                }
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Parallel upper hull: Right-to-left, similar pruning
    for (uint i = localIndex; i < uint(count); i += threadsPerGroup) {
        float2 point = sortedCoords[startIdx + (count - 1 - int(i))]; // Reverse

        int upperLoopCount = 0;
        while (upperLoopCount < 1000) { // Safety cap: max 1000 iterations
            upperLoopCount++;
            int currentCount = atomic_load_explicit(&sharedUpperCount, memory_order_relaxed);
            if (currentCount < 2) {
                int pos = atomic_fetch_add_explicit(&sharedUpperCount, 1, memory_order_relaxed);
                if (pos < 256) sharedUpper[pos] = point;
                break;
            } else {
                float cross = cross2D(sharedUpper[currentCount-2], sharedUpper[currentCount-1], point);
                if (cross <= params.collinearThreshold) {
                    if (atomic_compare_exchange_weak_explicit(&sharedUpperCount, &currentCount, currentCount-1, memory_order_relaxed, memory_order_relaxed)) {
                        continue;
                    }
                } else {
                    int pos = atomic_fetch_add_explicit(&sharedUpperCount, 1, memory_order_relaxed);
                    if (pos < 256) sharedUpper[pos] = point;
                    break;
                }
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Thread 0 merges into final clockwise hull
    if (localIndex == 0) {
        int lowerCount = atomic_load_explicit(&sharedLowerCount, memory_order_relaxed);
        int upperCount = atomic_load_explicit(&sharedUpperCount, memory_order_relaxed);

        int hullOffset = clusterIndex * params.maxHullVertices;
        int finalCount = 0;

        // Add lower hull (skip last to avoid dup)
        for (int i = 0; i < lowerCount - 1 && finalCount < params.maxHullVertices; i++) {
            hullVertices[hullOffset + finalCount++] = sharedLower[i];
        }

        // Add upper hull (skip last)
        for (int i = 0; i < upperCount - 1 && finalCount < params.maxHullVertices; i++) {
            hullVertices[hullOffset + finalCount++] = sharedUpper[i];
        }

        hullCounts[clusterIndex] = finalCount;
    }
}

// Helper functions for preprocessing kernel
float crossProduct2D(float2 a, float2 b, float2 c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

// Check if point is inside quadrilateral using cross products
bool isInsideQuad(float2 p, float2 q1, float2 q2, float2 q3, float2 q4) {
    // Point is inside if it's on the same side of all edges
    float c1 = crossProduct2D(q1, q2, p);
    float c2 = crossProduct2D(q2, q3, p);
    float c3 = crossProduct2D(q3, q4, p);
    float c4 = crossProduct2D(q4, q1, p);

    // All same sign means inside (with small epsilon for numerical stability)
    float epsilon = 1e-6;
    return (c1 >= -epsilon && c2 >= -epsilon && c3 >= -epsilon && c4 >= -epsilon) ||
           (c1 <= epsilon && c2 <= epsilon && c3 <= epsilon && c4 <= epsilon);
}

// Enhanced preprocessing kernel: Discard interior points using proper QuickHull-style filtering
// This reduces the effective point count by 50-90% in dense clusters using point-in-quad logic
kernel void preprocessHullPoints(
    const device float2* inputCoords [[buffer(0)]],     // Input coordinates
    device float2* outputCoords [[buffer(1)]],          // Filtered coordinates
    device int* outputCounts [[buffer(2)]],             // Points kept per cluster
    device int* clusterOffsets [[buffer(3)]],           // Start/count pairs
    constant Phase3Parameters& params [[buffer(4)]],
    uint clusterIndex [[thread_position_in_grid]]
) {
    if (clusterIndex >= uint(params.clustersCount)) return;

    int startIdx = clusterOffsets[clusterIndex * 2];
    int count = clusterOffsets[clusterIndex * 2 + 1];

    if (count < 3) {
        outputCounts[clusterIndex] = 0;
        return;
    }

    // Find extrema points (candidates for quad vertices)
    float2 minXPoint = inputCoords[startIdx], maxXPoint = inputCoords[startIdx];
    float2 minYPoint = inputCoords[startIdx], maxYPoint = inputCoords[startIdx];
    int minXIdx = 0, maxXIdx = 0, minYIdx = 0, maxYIdx = 0;

    for (int i = 1; i < count; i++) {
        float2 p = inputCoords[startIdx + i];

        if (p.x < minXPoint.x || (p.x == minXPoint.x && p.y < minXPoint.y)) {
            minXPoint = p; minXIdx = i;
        }
        if (p.x > maxXPoint.x || (p.x == maxXPoint.x && p.y > maxXPoint.y)) {
            maxXPoint = p; maxXIdx = i;
        }
        if (p.y < minYPoint.y || (p.y == minYPoint.y && p.x < minYPoint.x)) {
            minYPoint = p; minYIdx = i;
        }
        if (p.y > maxYPoint.y || (p.y == maxYPoint.y && p.x > maxYPoint.x)) {
            maxYPoint = p; maxYIdx = i;
        }
    }

    // Form convex quad from extrema points (sort them to ensure proper order)
    float2 quadPoints[4] = { minXPoint, minYPoint, maxXPoint, maxYPoint };

    // Sort quad points by angle around centroid for proper ordering
    float2 centroid = (minXPoint + maxXPoint + minYPoint + maxYPoint) * 0.25f;

    // Simple angular sort (for 4 points, bubble sort is fine)
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3 - i; j++) {
            float2 v1 = quadPoints[j] - centroid;
            float2 v2 = quadPoints[j + 1] - centroid;
            float angle1 = atan2(v1.y, v1.x);
            float angle2 = atan2(v2.y, v2.x);

            if (angle1 > angle2) {
                float2 temp = quadPoints[j];
                quadPoints[j] = quadPoints[j + 1];
                quadPoints[j + 1] = temp;
            }
        }
    }

    int outputOffset = clusterIndex * params.maxPointsPerCluster;
    int keepCount = 0;

    // Filter points: keep extrema + boundary candidates + points outside quad
    for (int i = 0; i < count && keepCount < params.maxPointsPerCluster; i++) {
        float2 point = inputCoords[startIdx + i];
        bool keep = false;

        // Always keep extreme points (guaranteed hull vertices)
        if (i == minXIdx || i == maxXIdx || i == minYIdx || i == maxYIdx) {
            keep = true;
        } else {
            // Test if point is outside the convex quad formed by extrema
            if (!isInsideQuad(point, quadPoints[0], quadPoints[1], quadPoints[2], quadPoints[3])) {
                keep = true;
            } else {
                // For points inside quad, keep boundary candidates (close to edges)
                float minDistToEdge = INFINITY;
                for (int e = 0; e < 4; e++) {
                    float2 p1 = quadPoints[e];
                    float2 p2 = quadPoints[(e + 1) % 4];

                    // Distance from point to edge
                    float2 edge = p2 - p1;
                    float2 toPoint = point - p1;
                    float edgeLen = length(edge);
                    if (edgeLen > 0) {
                        float proj = dot(toPoint, edge) / edgeLen;
                        proj = clamp(proj, 0.0f, edgeLen);
                        float2 closest = p1 + (edge / edgeLen) * proj;
                        float dist = length(point - closest);
                        minDistToEdge = min(minDistToEdge, dist);
                    }
                }

                // Keep if close to quad boundary (potential hull candidate)
                if (minDistToEdge < 100.0) { // 100m threshold for boundary candidates
                    keep = true;
                }
            }
        }

        if (keep) {
            outputCoords[outputOffset + keepCount] = point;
            keepCount++;
        }
    }

    outputCounts[clusterIndex] = keepCount;
}

// Phase 3: Sequential convex hull using monotone chain algorithm
// Single thread per cluster - eliminates atomic contention and deadlocks
kernel void buildConvexHullSequential(
    const device float2* sortedCoords [[buffer(0)]],    // X-sorted coordinates
    device float2* hullVertices [[buffer(1)]],          // Output hull vertices (flattened)
    device int* hullCounts [[buffer(2)]],               // Vertices per hull
    device int* clusterOffsets [[buffer(3)]],           // Start/count pairs per cluster
    device float2* tempHullBuffer [[buffer(4)]],        // Unused in sequential version
    constant Phase3Parameters& params [[buffer(5)]],
    uint clusterIndex [[threadgroup_position_in_grid]]
) {
    if (clusterIndex >= uint(params.clustersCount)) return;

    int startIdx = clusterOffsets[clusterIndex * 2];
    int count = clusterOffsets[clusterIndex * 2 + 1];

    if (count < 3) {
        hullCounts[clusterIndex] = 0;
        return;
    }

    // Safety cap - balance between capability and Metal stack limits (~32KB per thread)
    if (count > 2048) {
        hullCounts[clusterIndex] = 0;
        return;
    }

    // Local arrays allocated on thread's stack - conservative size for Metal stack limits
    float2 localLower[2048];
    float2 localUpper[2048];
    int lowerCount = 0;
    int upperCount = 0;

    // Build lower hull: Left-to-right sweep
    for (int i = 0; i < count; i++) {
        float2 point = sortedCoords[startIdx + i];

        // Remove points that create right turns (non-convex)
        while (lowerCount >= 2) {
            float cross = cross2D(localLower[lowerCount-2], localLower[lowerCount-1], point);
            if (cross <= params.collinearThreshold) {
                lowerCount--; // Remove last point
            } else {
                break; // Keep point
            }
        }

        // Add current point
        if (lowerCount < 2048) {
            localLower[lowerCount++] = point;
        }
    }

    // Build upper hull: Right-to-left sweep
    for (int i = count - 1; i >= 0; i--) {
        float2 point = sortedCoords[startIdx + i];

        // Remove points that create right turns
        while (upperCount >= 2) {
            float cross = cross2D(localUpper[upperCount-2], localUpper[upperCount-1], point);
            if (cross <= params.collinearThreshold) {
                upperCount--; // Remove last point
            } else {
                break; // Keep point
            }
        }

        // Add current point
        if (upperCount < 2048) {
            localUpper[upperCount++] = point;
        }
    }

    // Combine lower and upper hulls into output buffer with deduplication
    int hullOutputOffset = clusterIndex * params.maxHullVertices;
    int outputIdx = 0;
    float dedupThreshold = params.collinearThreshold * params.collinearThreshold; // Squared distance

    // Copy lower hull (excluding last point to avoid duplication)
    for (int i = 0; i < lowerCount - 1 && outputIdx < params.maxHullVertices; i++) {
        float2 point = localLower[i];

        // Check for duplicates against previous points
        bool isDuplicate = false;
        if (outputIdx > 0) {
            float2 diff = point - hullVertices[hullOutputOffset + outputIdx - 1];
            if (dot(diff, diff) < dedupThreshold) {
                isDuplicate = true;
            }
        }

        if (!isDuplicate) {
            hullVertices[hullOutputOffset + outputIdx++] = point;
        }
    }

    // Copy upper hull (excluding last point to avoid duplication)
    for (int i = 0; i < upperCount - 1 && outputIdx < params.maxHullVertices; i++) {
        float2 point = localUpper[i];

        // Check for duplicates against previous points
        bool isDuplicate = false;
        if (outputIdx > 0) {
            float2 diff = point - hullVertices[hullOutputOffset + outputIdx - 1];
            if (dot(diff, diff) < dedupThreshold) {
                isDuplicate = true;
            }
        }

        if (!isDuplicate) {
            hullVertices[hullOutputOffset + outputIdx++] = point;
        }
    }

    // Validate hull vertex count - ensure minimum viable hull
    if (outputIdx < 3) {
        hullCounts[clusterIndex] = 0; // Degenerate hull
    } else {
        hullCounts[clusterIndex] = min(outputIdx, params.maxHullVertices);
    }
}

// Phase 3: Grid-optimized confidence calculation
// Reuses Phase 1 spatial index
kernel void calculateConfidenceWithGrid(
    const device float2* coordinates [[buffer(0)]],      // All device coordinates
    const device bool* offlineFlags [[buffer(1)]],       // Offline status flags
    const device int* cellOffsets [[buffer(2)]],         // Phase 1 grid cell offsets
    const device int* cellCounts [[buffer(3)]],          // Phase 1 grid cell counts
    const device int* pointIndices [[buffer(4)]],        // Phase 1 point indices
    const device float2* hullVertices [[buffer(5)]],     // Hull vertices
    const device int* hullCounts [[buffer(6)]],          // Vertices per hull
    device float2* confidencePairs [[buffer(7)]],        // Output: offline/total counts
    constant Phase3Parameters& params [[buffer(8)]],
    constant GridIndexParameters& gridParams [[buffer(9)]],
    uint clusterIndex [[threadgroup_position_in_grid]],
    uint localIndex [[thread_position_in_threadgroup]],
    uint threadsPerGroup [[threads_per_threadgroup]]
) {
    if (clusterIndex >= uint(params.clustersCount)) return;

    int hullCount = hullCounts[clusterIndex];
    if (hullCount < 3) {
        if (localIndex == 0) {
            confidencePairs[clusterIndex] = float2(0.0, 0.0);
        }
        return;
    }

    int hullOffset = clusterIndex * params.maxHullVertices;

    // Parallel min/max reduction for bounds
    threadgroup float2 sharedMin;
    threadgroup float2 sharedMax;
    if (localIndex == 0) {
        sharedMin = hullVertices[hullOffset];
        sharedMax = hullVertices[hullOffset];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint i = localIndex; i < uint(hullCount); i += threadsPerGroup) {
        float2 hullVertex = hullVertices[hullOffset + i];
        atomic_min_float2(&sharedMin, hullVertex);
        atomic_max_float2(&sharedMax, hullVertex);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float2 minBounds = sharedMin - params.epsilon;
    float2 maxBounds = sharedMax + params.epsilon;

    // Grid cell bounds
    int minCellX = max(0, int((minBounds.x - gridParams.minX) / params.gridCellSize));
    int maxCellX = min(params.gridWidth - 1, int((maxBounds.x - gridParams.minX) / params.gridCellSize));
    int minCellY = max(0, int((minBounds.y - gridParams.minY) / params.gridCellSize));
    int maxCellY = min(params.gridHeight - 1, int((maxBounds.y - gridParams.minY) / params.gridCellSize));

    // Parallel reduction using threadgroup atomics
    threadgroup atomic_int sharedOfflineCount;
    threadgroup atomic_int sharedTotalCount;

    if (localIndex == 0) {
        atomic_store_explicit(&sharedOfflineCount, 0, memory_order_relaxed);
        atomic_store_explicit(&sharedTotalCount, 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Load-balanced cell processing with safeguards for large clusters
    int totalCells = (maxCellX - minCellX + 1) * (maxCellY - minCellY + 1);

    // Safeguard: Cap total cells to prevent GPU timeout
    if (totalCells > 10000) {
        // Early return with zero confidence for extremely large grids
        confidencePairs[clusterIndex] = float2(0.0, 1.0); // 0% confidence
        return;
    }

    for (int cellIdx = localIndex; cellIdx < totalCells; cellIdx += threadsPerGroup) {
        int cellX = minCellX + (cellIdx % (maxCellX - minCellX + 1));
        int cellY = minCellY + (cellIdx / (maxCellX - minCellX + 1));

        int gridIdx = cellY * params.gridWidth + cellX;
        int cellStart = cellOffsets[gridIdx];
        int cellCount = cellCounts[gridIdx];

        // Safeguard: Cap cell count to prevent long loops
        int safeCellCount = min(cellCount, 1000);

        for (int i = 0; i < safeCellCount; i++) {
            int deviceIdx = pointIndices[cellStart + i];
            float2 coord = coordinates[deviceIdx];

            if (coord.x >= minBounds.x && coord.x <= maxBounds.x &&
                coord.y >= minBounds.y && coord.y <= maxBounds.y) {
                atomic_fetch_add_explicit(&sharedTotalCount, 1, memory_order_relaxed);
                if (offlineFlags[deviceIdx]) {
                    atomic_fetch_add_explicit(&sharedOfflineCount, 1, memory_order_relaxed);
                }
            }
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (localIndex == 0) {
        int offlineCount = atomic_load_explicit(&sharedOfflineCount, memory_order_relaxed);
        int totalCount = atomic_load_explicit(&sharedTotalCount, memory_order_relaxed);

        confidencePairs[clusterIndex] = float2(float(offlineCount), float(max(totalCount, params.minTotalDevices)));
    }
}
"""
}

// MARK: - Error Handling

public enum MetalTransformError: Error, LocalizedError {
    case deviceNotAvailable
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case shaderCompilationFailed(String)
    case functionNotFound(String)
    case pipelineStateCreationFailed(String)
    case gpuExecutionFailed(String)
    case insufficientData(String)
    
    public var errorDescription: String? {
        switch self {
        case .deviceNotAvailable:
            return "Metal GPU device not available. This device may not support Metal compute shaders."
        case .commandQueueCreationFailed:
            return "Failed to create Metal command queue."
        case .commandBufferCreationFailed:
            return "Failed to create Metal command buffer."
        case .shaderCompilationFailed(let details):
            return "Metal shader compilation failed: \(details)"
        case .functionNotFound(let name):
            return "Metal compute function '\(name)' not found in shader library."
        case .pipelineStateCreationFailed(let details):
            return "Failed to create Metal compute pipeline: \(details)"
        case .gpuExecutionFailed(let details):
            return "GPU execution failed: \(details)"
        case .insufficientData(let details):
            return "Insufficient data for GPU processing: \(details)"
        }
    }
}

// MARK: - Extensions

extension ProjectedCoordinate: Equatable {
    public static func == (lhs: ProjectedCoordinate, rhs: ProjectedCoordinate) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y && lhs.system.epsgCode == rhs.system.epsgCode
    }
}

extension ProjectedCoordinate: CustomStringConvertible {
    public var description: String {
        return "ProjectedCoordinate(x: \(x), y: \(y), system: \(system))"
    }
}

// MARK: - Validation Helper

extension CoordinateTransformer {
    /// Validate transformation accuracy by round-trip testing
    public func validateTransformation(_ coordinate: CLLocationCoordinate2D, tolerance: Double = 0.001) -> Bool {
        let projected = transform(coordinate)
        let roundTrip = batchInverseTransform([projected]).first ?? CLLocationCoordinate2D()
        
        let latDiff = abs(coordinate.latitude - roundTrip.latitude)
        let lonDiff = abs(coordinate.longitude - roundTrip.longitude)
        
        return latDiff <= tolerance && lonDiff <= tolerance
    }
}
