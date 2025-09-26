//
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

import Foundation
import CoreLocation

// Import the spatial clustering types to access ProjectionSystem and ProjectedCoordinate
// Note: This requires the spatial clustering module to be properly organized

/// Singleton manager for CoordinateTransformer instances to prevent GPU memory leaks
public final class CoordinateTransformerManager: @unchecked Sendable {
    public static let shared = CoordinateTransformerManager()

    private var transformers: [ProjectionSystem: CoordinateTransformer] = [:]
    private let queue = DispatchQueue(label: "com.pulse.transformer-manager", qos: .userInteractive)

    private init() {}

    /// Get or create a shared transformer for the specified projection system
    internal func getTransformer(for projectionSystem: ProjectionSystem = .nztm2000) throws -> CoordinateTransformer {
        return try queue.sync {
            if let existingTransformer = transformers[projectionSystem] {
                return existingTransformer
            }

            print("🚀 Creating shared CoordinateTransformer for \(projectionSystem)")
            let newTransformer = try CoordinateTransformer(projectionSystem: projectionSystem)
            transformers[projectionSystem] = newTransformer
            return newTransformer
        }
    }

    /// Transform a single coordinate using shared transformer
    internal func transform(_ coordinate: CLLocationCoordinate2D, using projectionSystem: ProjectionSystem = .nztm2000) -> ProjectedCoordinate {
        do {
            let transformer = try getTransformer(for: projectionSystem)
            return transformer.transform(coordinate)
        } catch {
            print("❌ Transformer error: \(error)")
            return ProjectedCoordinate(x: 0, y: 0, system: projectionSystem)
        }
    }

    /// Batch transform coordinates using shared transformer
    internal func batchTransform(_ coordinates: [CLLocationCoordinate2D], using projectionSystem: ProjectionSystem = .nztm2000) throws -> [ProjectedCoordinate] {
        let transformer = try getTransformer(for: projectionSystem)
        return try transformer.batchTransform(coordinates)
    }

    /// Inverse transform using shared transformer
    internal func inverseTransform(_ projected: ProjectedCoordinate) -> CLLocationCoordinate2D {
        do {
            let transformer = try getTransformer(for: projected.system)
            return transformer.batchInverseTransform([projected]).first ?? CLLocationCoordinate2D()
        } catch {
            print("❌ Inverse transformer error: \(error)")
            return CLLocationCoordinate2D()
        }
    }

    /// Clear all cached transformers (for memory cleanup)
    public func clearCache() {
        queue.sync {
            print("🧹 Clearing CoordinateTransformer cache")
            transformers.removeAll()
        }
    }

    /// Get memory usage information
    public var cacheInfo: String {
        return queue.sync {
            "CoordinateTransformerManager: \(transformers.count) cached transformers"
        }
    }

    /// Release transformers not used recently (for memory pressure scenarios)
    public func releaseUnusedTransformers() {
        queue.sync {
            let initialCount = transformers.count
            transformers.removeAll()
            if initialCount > 0 {
                print("🗑️ Released \(initialCount) unused CoordinateTransformers")
            }
        }
    }

    /// Memory pressure handler - can be called by system notifications
    @objc public func handleMemoryPressure() {
        print("⚠️ Memory pressure detected - clearing transformer cache")
        releaseUnusedTransformers()
    }
}