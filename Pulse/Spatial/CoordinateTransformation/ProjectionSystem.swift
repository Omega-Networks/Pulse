//
//  ProjectionSystem.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Pulse
//  The Platform for Unified Leadership in Smart Environments.
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

    public static func == (lhs: ProjectedCoordinate, rhs: ProjectedCoordinate) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y && lhs.system.epsgCode == rhs.system.epsgCode
    }

    public var description: String {
        return "ProjectedCoordinate(x: \(x), y: \(y), system: \(system))"
    }
    
}
