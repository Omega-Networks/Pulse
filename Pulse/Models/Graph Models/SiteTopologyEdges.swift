//
//  SiteTopologyEdges.swift
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
import SwiftData

/// One indexed per-site fetch plus an in-memory undirected join.
/// Shared by `SiteGraphView` and `LayoutManager`. Models never leave
/// the caller's `ModelContext`.
enum SiteTopologyEdges {
    static func fetchVOs(siteId: Int64, in context: ModelContext) throws -> [InterfaceVO] {
        let descriptor = FetchDescriptor<Interface>(
            predicate: #Predicate<Interface> { $0.siteId == siteId }
        )
        return try context.fetch(descriptor).map(InterfaceVO.init(model:))
    }

    static func fetchVOs(deviceId: Int64, in context: ModelContext) throws -> [InterfaceVO] {
        let descriptor = FetchDescriptor<Interface>(
            predicate: #Predicate<Interface> { $0.deviceId == deviceId }
        )
        return try context.fetch(descriptor).map(InterfaceVO.init(model:))
    }

    /// Undirected, deduped. A cable currently stored on both ends becomes
    /// one edge. Missing other end is dropped (no edge).
    static func derive(from vos: [InterfaceVO]) -> [Edge] {
        var byID: [Int64: InterfaceVO] = [:]
        byID.reserveCapacity(vos.count)
        for vo in vos {
            byID[vo.id] = vo
        }
        var seen = Set<Pair>()
        var edges: [Edge] = []
        for vo in vos {
            guard let endID = vo.connectedEndpointId, let end = byID[endID] else {
                continue
            }
            let pair = Pair(vo.id, end.id)
            guard seen.insert(pair).inserted else { continue }
            edges.append(Edge(start: vo, end: end))
        }
        return edges
    }

    private struct Pair: Hashable {
        let low: Int64
        let high: Int64
        init(_ a: Int64, _ b: Int64) {
            if a < b {
                low = a
                high = b
            } else {
                low = b
                high = a
            }
        }
    }
}
