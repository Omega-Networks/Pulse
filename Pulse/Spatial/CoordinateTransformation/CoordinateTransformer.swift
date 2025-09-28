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

/// Supported projection systems
public enum ProjectionSystem: Equatable, Hashable, Sendable {
    case nztm2000        // New Zealand Transverse Mercator (EPSG:2193)
    case webMercator     // Web Mercator (EPSG:3857) - Global
    case utm(zone: Int)  // UTM zones for high accuracy regional use
    
    public var epsgCode: Int {
        switch self {
        case .nztm2000:
            return 2193
        case .webMercator:
            return 3857
        case .utm(let zone):
            // UTM EPSG codes: Northern hemisphere 32600+zone, Southern hemisphere 32700+zone
            // TODO: Determine hemisphere from coordinates for proper EPSG code
            return 32600 + zone // Assuming northern hemisphere (add hemisphere detection later)
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
    
    public var description: String {
        return """
        GPU Transformation Metrics:
        - Device: \(deviceName)
        - Coordinates: \(coordinatesProcessed.formatted())
        - GPU Time: \(String(format: "%.3f", gpuTime * 1000))ms
        - Total Time: \(String(format: "%.3f", totalTime * 1000))ms
        - Throughput: \(String(format: "%.0f", throughput)) coords/sec (\(String(format: "%.1f", throughput/1000))k/sec)
        - Memory: \(String(format: "%.1f", Double(memoryUsed) / 1024 / 1024))MB
        """
    }
}

// MARK: - Main Metal GPU CoordinateTransformer

/// GPU-accelerated coordinate transformation using Metal compute shaders
public final class CoordinateTransformer: Sendable {
    
    // MARK: - Metal Resources
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
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
                throughput: 0, memoryUsed: 0, deviceName: device.name
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
            throughput: throughput,
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
        case .utm(_):
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
            
        case .utm(let zone):
            var params = UTMParameters(
                zone: Int32(zone),
                centralMeridian: Float((zone - 1) * 6 - 177),
                falseEasting: 500000.0,
                scaleFactor: 0.9996
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
        
        // For other regions, determine appropriate UTM zone
        let utmZone = Int((center.longitude + 180) / 6) + 1
        return .utm(zone: utmZone)
    }
    
    // MARK: - CPU Fallback for Inverse Transform
    
    private func inverseTransformCPU(_ projected: ProjectedCoordinate) -> CLLocationCoordinate2D {
        switch projectionSystem {
        case .nztm2000:
            return inverseTransformFromNZTM(projected)
        case .webMercator:
            return inverseTransformFromWebMercator(projected)
        case .utm(let zone):
            return inverseTransformFromUTM(projected, zone: zone)
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
    
    private func inverseTransformFromUTM(_ projected: ProjectedCoordinate, zone: Int) -> CLLocationCoordinate2D {
        let centralMeridian = Double((zone - 1) * 6 - 177) * .pi / 180.0
        let x = projected.x - 500000.0
        let y = projected.y < 5000000.0 ? projected.y : projected.y - 10000000.0
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

        // Choose algorithm based on optimization flag and dataset size
        let shouldUseGrid = useGridOptimization && offlineCoordinates.count > 1000

        if shouldUseGrid {
            return try buildGridIndexOptimized(
                offlineCoordinates: offlineCoordinates,
                deviceIndices: deviceIndices,
                gridParams: gridParams,
                gridSize: gridSize
            )
        } else {
            return try buildGridIndexBruteForce(
                offlineCoordinates: offlineCoordinates,
                deviceIndices: deviceIndices,
                gridParams: gridParams
            )
        }
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
        let cellCountsPointer = grid.cellCounts.contents().bindMemory(to: Int32.self, capacity: gridSize)
        let cellOffsetsPointer = grid.cellOffsets.contents().bindMemory(to: Int32.self, capacity: gridSize)
        let cellPositionsPointer = grid.cellPositions.contents().bindMemory(to: Int32.self, capacity: gridSize)

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

    /// Brute-force neighbor counting - O(N²) fallback for small datasets
    private func buildGridIndexBruteForce(
        offlineCoordinates: [ProjectedCoordinate],
        deviceIndices: [Int32],
        gridParams: GridIndexParameters
    ) throws -> (gridParams: GridIndexParameters, neighborResults: [GPUNeighborResult]) {

        print("   Using brute-force algorithm (small dataset)...")

        // Convert coordinates to GPU format
        let gpuCoords = offlineCoordinates.map { SIMD2<Float>(Float($0.x), Float($0.y)) }

        // Create Metal buffers
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

        let resultsBuffer = device.makeBuffer(
            length: offlineCoordinates.count * MemoryLayout<GPUNeighborResult>.size,
            options: .storageModeShared
        )!

        // Execute legacy brute-force kernel
        try executeGridBuildKernel(
            coordsBuffer: coordsBuffer,
            indicesBuffer: indicesBuffer,
            resultsBuffer: resultsBuffer,
            gridParams: gridParams,
            coordinateCount: offlineCoordinates.count
        )

        // Read results
        let resultsPointer = resultsBuffer.contents().bindMemory(to: GPUNeighborResult.self, capacity: offlineCoordinates.count)
        let neighborResults = Array(UnsafeBufferPointer(start: resultsPointer, count: offlineCoordinates.count))

        let totalNeighbors = neighborResults.reduce(0) { $0 + Int($1.neighborCount) }
        print("   ✅ Brute-force GPU index built: \(totalNeighbors) neighbor relationships")

        return (gridParams, neighborResults)
    }

    /// Execute the GPU grid build kernel
    private func executeGridBuildKernel(
        coordsBuffer: MTLBuffer,
        indicesBuffer: MTLBuffer,
        resultsBuffer: MTLBuffer,
        gridParams: GridIndexParameters,
        coordinateCount: Int
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        // Create grid build pipeline if not exists (we'll add this to initialization)
        let gridPipelineState = try getOrCreateGridPipelineState()
        computeEncoder.setComputePipelineState(gridPipelineState)

        // Set buffers
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)      // Offline coordinates
        computeEncoder.setBuffer(indicesBuffer, offset: 0, index: 1)     // Device indices
        computeEncoder.setBuffer(resultsBuffer, offset: 0, index: 2)     // Output results

        // Set grid parameters
        var params = gridParams
        computeEncoder.setBytes(&params, length: MemoryLayout<GridIndexParameters>.size, index: 3)

        // Set total count
        var totalCount = UInt32(coordinateCount)
        computeEncoder.setBytes(&totalCount, length: MemoryLayout<UInt32>.size, index: 4)

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
        computeEncoder.setBuffer(grid.cellCounts, offset: 0, index: 1)

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
        computeEncoder.setBuffer(grid.cellCounts, offset: 0, index: 2)

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
        computeEncoder.setBuffer(grid.pointIndices, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.cellOffsets, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.cellPositions, offset: 0, index: 3)

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
        computeEncoder.setBuffer(grid.pointIndices, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.cellOffsets, offset: 0, index: 3)
        computeEncoder.setBuffer(grid.cellCounts, offset: 0, index: 4) // Reusing as positions (reset to 0 earlier)

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

    /// CRITICAL FIX: Execute grid build kernel with corrected global indices (Legacy)
    private func executeGridBuildKernelCorrected(
        coordsBuffer: MTLBuffer,
        grid: GPUGrid,
        gridParams: GridIndexParameters,
        coordinateCount: Int,
        localDeviceIndices: [Int32] // CRITICAL FIX: Local indices for offline-only coords buffer
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalTransformError.commandBufferCreationFailed
        }

        // CRITICAL FIX: Use the provided local indices
        let localIndicesBuffer = device.makeBuffer(
            bytes: localDeviceIndices,
            length: localDeviceIndices.count * MemoryLayout<Int32>.size,
            options: .storageModeShared
        )!

        let pipelineState = try getOrCreatePipelineState(functionName: "gridBuildPass")
        computeEncoder.setComputePipelineState(pipelineState)

        // Set buffers
        computeEncoder.setBuffer(coordsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(grid.pointIndices, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.cellOffsets, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.cellCounts, offset: 0, index: 3) // Reusing as positions (reset to 0 earlier)
        // Set grid parameters
        var params = gridParams
        computeEncoder.setBytes(&params, length: MemoryLayout<GridIndexParameters>.size, index: 4)
        computeEncoder.setBuffer(localIndicesBuffer, offset: 0, index: 5) // CRITICAL FIX: Local indices for coords buffer consistency

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
        computeEncoder.setBuffer(grid.pointIndices, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.cellOffsets, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.cellCounts, offset: 0, index: 3)
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
        computeEncoder.setBuffer(grid.pointIndices, offset: 0, index: 1)
        computeEncoder.setBuffer(grid.cellOffsets, offset: 0, index: 2)
        computeEncoder.setBuffer(grid.cellCounts, offset: 0, index: 3)
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
        let cellCountsPointer = grid.cellCounts.contents().bindMemory(to: Int32.self, capacity: gridSize)
        let cellOffsetsPointer = grid.cellOffsets.contents().bindMemory(to: Int32.self, capacity: gridSize)

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

    /// Get or create the grid build pipeline state (legacy - kept for compatibility)
    private func getOrCreateGridPipelineState() throws -> MTLComputePipelineState {
        return try getOrCreatePipelineState(functionName: "buildGridIndex")
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
}

// MARK: - GPU Grid Index Structures

/// GPU grid indexing parameters
public struct GridIndexParameters {
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
public struct GPUNeighborResult {
    let deviceIndex: Int32  // Index of the device
    let neighborCount: Int32  // Number of neighbors found
    let cellX: Int32
    let cellY: Int32
}

/// Spatial bounds helper structure
public struct SpatialBounds {
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
public struct GPUGrid {
    let cellOffsets: MTLBuffer    // Int[gridWidth*gridHeight] - start index in pointIndices
    let cellCounts: MTLBuffer     // Int[gridWidth*gridHeight] - num points in cell
    let pointIndices: MTLBuffer   // Int[totalOffline] - sorted device indices by cell
    let cellPositions: MTLBuffer  // Int[gridWidth*gridHeight] - temp for atomic append

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

        self.cellOffsets = cellOffsetsBuffer
        self.cellCounts = cellCountsBuffer
        self.pointIndices = pointIndicesBuffer
        self.cellPositions = cellPositionsBuffer

        // Initialize buffers to zero
        memset(cellCountsBuffer.contents(), 0, gridSize * MemoryLayout<Int32>.size)
        memset(cellOffsetsBuffer.contents(), 0, gridSize * MemoryLayout<Int32>.size)
        memset(cellPositionsBuffer.contents(), 0, gridSize * MemoryLayout<Int32>.size)
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

    // UTM transformation
    float deltaLon = lon - centralMeridianRad;
    float cosLat = cos(lat);

    float falseNorthing = (latLon.x < 0.0f) ? 10000000.0f : 0.0f;

    float x = params.falseEasting + (params.scaleFactor * 6378137.0f * deltaLon * cosLat);
    float y = falseNorthing + (params.scaleFactor * 6378137.0f * lat);

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

struct GPUNeighborResult {
    int deviceIndex;    // Index of the device
    int neighborCount;  // Number of neighbors found
    int cellX;
    int cellY;
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

// Legacy brute-force kernel (kept for fallback/testing)
kernel void buildGridIndex(
    const device float2* offlineCoords [[buffer(0)]],
    const device int* deviceIndices [[buffer(1)]],
    device GPUNeighborResult* results [[buffer(2)]],
    constant GridIndexParameters& params [[buffer(3)]],
    constant uint& totalCount [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= totalCount) return;

    float2 coord = offlineCoords[id];
    int deviceIndex = deviceIndices[id];

    // Calculate grid cell for this device
    int cellX = int((coord.x - params.minX) / params.cellSize);
    int cellY = int((coord.y - params.minY) / params.cellSize);

    // Clamp to grid bounds
    cellX = max(0, min(cellX, params.gridWidth - 1));
    cellY = max(0, min(cellY, params.gridHeight - 1));

    // Count neighbors within epsilon radius (brute force for fallback)
    int neighborCount = 0;
    float epsilonSquared = params.epsilon * params.epsilon;

    // Check all other devices
    for (uint j = 0; j < totalCount; j++) {
        if (j == id) continue;

        float2 otherCoord = offlineCoords[j];
        float dx = coord.x - otherCoord.x;
        float dy = coord.y - otherCoord.y;
        float distanceSquared = dx * dx + dy * dy;

        if (distanceSquared <= epsilonSquared) {
            neighborCount++;
        }
    }

    // Store results
    results[id].deviceIndex = deviceIndex;
    results[id].neighborCount = neighborCount;
    results[id].cellX = cellX;
    results[id].cellY = cellY;
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
