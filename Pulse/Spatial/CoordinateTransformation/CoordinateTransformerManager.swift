// MARK: - WHAT IS THE PURPOSE OF THIS FILE? -


//  CoordinateTransformerManager.swift
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

//public import CoreLocation
//import OSLog
//
///// Cacheable transformer entry with usage tracking
//private struct TransformerEntry {
//    let transformer: CoordinateTransformer
//    var lastAccessed: Date
//    var accessCount: Int
//
//    init(transformer: CoordinateTransformer) {
//        self.transformer = transformer
//        self.lastAccessed = Date()
//        self.accessCount = 1
//    }
//
//    mutating func markAccessed() {
//        self.lastAccessed = Date()
//        self.accessCount += 1
//    }
//}

///// Modern injectable coordinate transformer manager using Actor for thread safety
//public actor CoordinateTransformerManager: Sendable {
//
//    private var transformers: [ProjectionSystem: TransformerEntry] = [:]
//    private let maxCacheSize: Int
//    private let cacheTimeout: TimeInterval
//    private let logger = Logger(subsystem: "pulse.spatial", category: "coordinate-manager")
//
//    // MARK: - Configuration
//
//    public struct Config: Sendable {
//        let maxCacheSize: Int
//        let cacheTimeout: TimeInterval
//
//        public init(maxCacheSize: Int = 5, cacheTimeout: TimeInterval = 300.0) {
//            self.maxCacheSize = maxCacheSize
//            self.cacheTimeout = cacheTimeout
//        }
//
//        public static let `default` = Config()
//    }
//
//    // MARK: - Initialization
//
//    public init(config: Config = .default) {
//        self.maxCacheSize = config.maxCacheSize
//        self.cacheTimeout = config.cacheTimeout
//        logger.info("🏗️ CoordinateTransformerManager initialized (cache: \(self.maxCacheSize), timeout: \(self.cacheTimeout)s)")
//    }
//
//    // MARK: - Public Interface
//
//    /// Get or create a cached transformer for the specified projection system
//    public func getTransformer(for projectionSystem: ProjectionSystem = .nztm2000) async throws -> CoordinateTransformer {
//        // Check for existing, non-expired transformer
//        if var entry = transformers[projectionSystem] {
//            let age = Date().timeIntervalSince(entry.lastAccessed)
//
//            if age < cacheTimeout {
//                entry.markAccessed()
//                transformers[projectionSystem] = entry
//                logger.debug("📋 Using cached transformer for \(String(describing: projectionSystem)) (accessed \(entry.accessCount) times)")
//                return entry.transformer
//            } else {
//                logger.debug("⏰ Transformer for \(String(describing: projectionSystem)) expired (age: \(String(format: "%.1f", age))s)")
//                transformers.removeValue(forKey: projectionSystem)
//            }
//        }
//
//        // Create new transformer
//        logger.info("🚀 Creating new CoordinateTransformer for \(String(describing: projectionSystem))")
//
//        do {
//            let newTransformer = try CoordinateTransformer(projectionSystem: projectionSystem)
//            let entry = TransformerEntry(transformer: newTransformer)
//
//            // Enforce cache size limit with LRU eviction
//            if transformers.count >= maxCacheSize {
//                evictLeastRecentlyUsed()
//            }
//
//            transformers[projectionSystem] = entry
//            logger.info("✅ Cached new transformer for \(String(describing: projectionSystem))")
//
//            return newTransformer
//        } catch {
//            logger.error("❌ Failed to create transformer for \(String(describing: projectionSystem)): \(error)")
//            throw ClusteringError.transformationFailed(projectionSystem: "\(projectionSystem)")
//        }
//    }
//
//    /// Transform a single coordinate using cached transformer
//    public func transform(
//        _ coordinate: CLLocationCoordinate2D,
//        using projectionSystem: ProjectionSystem = .nztm2000
//    ) async throws -> ProjectedCoordinate {
//        let transformer = try await getTransformer(for: projectionSystem)
//
//        return transformer.transform(coordinate)
//    }
//
//    /// Batch transform coordinates using cached transformer
//    public func batchTransform(
//        _ coordinates: [CLLocationCoordinate2D],
//        using projectionSystem: ProjectionSystem = .nztm2000
//    ) async throws -> [ProjectedCoordinate] {
//        let transformer = try await getTransformer(for: projectionSystem)
//
//        do {
//            return try transformer.batchTransform(coordinates)
//        } catch {
//            logger.error("❌ Batch transform failed for \(coordinates.count) coordinates: \(error)")
//            throw ClusteringError.transformationFailed(projectionSystem: "\(projectionSystem)")
//        }
//    }
//
//    /// Inverse transform using cached transformer
//    public func inverseTransform(_ projected: ProjectedCoordinate) async throws -> CLLocationCoordinate2D {
//        let transformer = try await getTransformer(for: projected.system)
//
//        let results = transformer.batchInverseTransform([projected])
//        guard let result = results.first else {
//            throw ClusteringError.transformationFailed(projectionSystem: "\(projected.system)")
//        }
//        return result
//    }
//
//    // MARK: - Cache Management
//
//    /// Clear all cached transformers
//    public func clearCache() {
//        let count = transformers.count
//        transformers.removeAll()
//        logger.info("🧹 Cleared \(count) cached transformers")
//    }
//
//    /// Get current cache information
//    public var cacheInfo: String {
//        let totalAccess = transformers.values.reduce(0) { $0 + $1.accessCount }
//        return "CoordinateTransformerManager: \(transformers.count)/\(maxCacheSize) cached transformers, \(totalAccess) total accesses"
//    }
//
//    /// Remove expired transformers
//    public func cleanupExpiredTransformers() {
//        let now = Date()
//        let initialCount = transformers.count
//
//        transformers = transformers.filter { _, entry in
//            now.timeIntervalSince(entry.lastAccessed) < cacheTimeout
//        }
//
//        let removed = initialCount - transformers.count
//        if removed > 0 {
//            logger.info("🧹 Cleaned up \(removed) expired transformers")
//        }
//    }
//
//    /// Memory pressure handler
//    public func handleMemoryPressure() {
//        logger.warning("⚠️ Memory pressure detected - clearing transformer cache")
//        clearCache()
//    }
//
//    // MARK: - Performance Metrics
//    public func getCacheMetrics() -> CacheMetrics {
//        let entries = Array(transformers.values)
//        let totalAccess = entries.reduce(0) { $0 + $1.accessCount }
//        let avgAccess = entries.isEmpty ? 0.0 : Double(totalAccess) / Double(entries.count)
//
//        return CacheMetrics(
//            cacheSize: transformers.count,
//            maxSize: maxCacheSize,
//            totalAccesses: totalAccess,
//            averageAccesses: avgAccess,
//            oldestEntry: entries.min(by: { $0.lastAccessed < $1.lastAccessed })?.lastAccessed
//        )
//    }
//
//    // MARK: - Private Methods
//
//    private func evictLeastRecentlyUsed() {
//        guard let lruKey = transformers.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key else {
//            return
//        }
//
//        logger.debug("🗑️ Evicting LRU transformer for \(String(describing: lruKey))")
//        transformers.removeValue(forKey: lruKey)
//    }
//}

// MARK: - Supporting Types

//public struct CacheMetrics: Sendable {
//    public let cacheSize: Int
//    public let maxSize: Int
//    public let totalAccesses: Int
//    public let averageAccesses: Double
//    public let oldestEntry: Date?
//
//    public var utilizationRatio: Double {
//        return maxSize > 0 ? Double(cacheSize) / Double(maxSize) : 0.0
//    }
//
//    public var description: String {
//        let ageString = if let oldest = oldestEntry {
//            String(format: "%.1fs", Date().timeIntervalSince(oldest))
//        } else {
//            "N/A"
//        }
//
//        return """
//        Cache Metrics:
//        - Size: \(cacheSize)/\(maxSize) (\(String(format: "%.1f", utilizationRatio * 100))%)
//        - Total accesses: \(totalAccesses)
//        - Average accesses per transformer: \(String(format: "%.1f", averageAccesses))
//        - Oldest entry age: \(ageString)
//        """
//    }
//}
