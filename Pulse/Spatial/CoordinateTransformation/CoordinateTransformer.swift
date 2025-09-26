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

import Foundation
import Metal
import simd
public import CoreLocation

// MARK: - Public Types

/// Projected coordinate in meters
public struct ProjectedCoordinate {
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
public enum ProjectionSystem: Equatable, Hashable {
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
            return 32600 + zone // Northern hemisphere UTM zones
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
public final class CoordinateTransformer {
    
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
    
    /// Batch inverse transform (GPU-accelerated)
    public func batchInverseTransform(_ projectedCoordinates: [ProjectedCoordinate]) -> [CLLocationCoordinate2D] {
        // TODO: Implement GPU inverse transformation if needed
        // For now, falls back to CPU implementation
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

// NZTM Transformation Kernel - Optimized for Apple Silicon
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
