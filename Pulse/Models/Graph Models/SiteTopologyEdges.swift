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
///
/// The graph draws from interface link pairs
/// (`connectedEndpointId`). `Cable` rows persist tenant, length,
/// colour, and the DELETE target; they do not own this join.
enum SiteTopologyEdges {
    static func fetchVOs(siteId: Int64, in context: ModelContext) throws -> [InterfaceVO] {
        guard siteId != 0 else { return [] }
        let stamped = try context.fetch(
            FetchDescriptor<Interface>(
                predicate: #Predicate<Interface> { $0.siteId == siteId }
            )
        )
        // Always walk devices at the site. Pre-Cable rows (and any
        // apply that saw a nil `device.site`) keep siteId 0, so a
        // stamped-only fetch can return just the source device.
        var byID: [Int64: Interface] = [:]
        byID.reserveCapacity(stamped.count)
        for row in stamped {
            byID[row.id] = row
        }
        for device in try devices(at: siteId, in: context) {
            let deviceId = device.id
            let owned = try context.fetch(
                FetchDescriptor<Interface>(
                    predicate: #Predicate<Interface> { $0.deviceId == deviceId }
                )
            )
            for row in owned {
                byID[row.id] = row
            }
        }
        return byID.values
            .map(InterfaceVO.init(model:))
            .sorted { $0.id < $1.id }
    }

    /// Devices at `siteId`. Walks `Site.devices` (same path as the site
    /// graph). `#Predicate { $0.site?.id == siteId }` does not match in
    /// the live store, and `Device.siteId` is 0 until the next apply.
    static func devices(at siteId: Int64, in context: ModelContext) throws -> [Device] {
        guard siteId != 0 else { return [] }
        var byID: [Int64: Device] = [:]
        let match = siteId
        if let site = try context.fetch(
            FetchDescriptor<Site>(predicate: #Predicate<Site> { $0.id == match })
        ).first {
            for device in site.devices ?? [] {
                byID[device.id] = device
            }
        }
        for device in try context.fetch(
            FetchDescriptor<Device>(predicate: #Predicate<Device> { $0.siteId == match })
        ) {
            byID[device.id] = device
        }
        return Array(byID.values)
    }

    /// Ports Connect can offer. Always includes the source device's
    /// other interfaces (that fetch already works for the table), then
    /// every device on the same site.
    static func connectCandidates(
        from source: InterfaceVO,
        device: Device? = nil,
        in context: ModelContext
    ) throws -> [InterfaceVO] {
        var deviceIDs = Set<Int64>()
        if let id = source.deviceId, id != 0 {
            deviceIDs.insert(id)
        }
        if let device {
            deviceIDs.insert(device.id)
            for peer in device.site?.devices ?? [] {
                deviceIDs.insert(peer.id)
            }
        }
        if let siteId = resolvedSiteId(interface: source, device: device, in: context) {
            for peer in try devices(at: siteId, in: context) {
                deviceIDs.insert(peer.id)
            }
        }
        var byID: [Int64: InterfaceVO] = [:]
        if let device {
            for port in device.interfaces ?? [] {
                byID[port.id] = InterfaceVO(model: port)
            }
        }
        for deviceId in deviceIDs {
            for vo in try fetchVOs(deviceId: deviceId, in: context) {
                byID[vo.id] = vo
            }
        }
        byID.removeValue(forKey: source.id)
        return byID.values.sorted {
            let left = "\($0.deviceName ?? "") \($0.name)"
            let right = "\($1.deviceName ?? "") \($1.name)"
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    /// Site for Connect. `0` on the VO is missing, not a real site.
    static func resolvedSiteId(
        interface: InterfaceVO,
        device: Device? = nil,
        in context: ModelContext
    ) -> Int64? {
        if let siteId = interface.siteId, siteId != 0 {
            return siteId
        }
        if let device {
            let id = device.resolvedSiteId
            return id == 0 ? nil : id
        }
        guard let deviceId = interface.deviceId, deviceId != 0 else {
            return nil
        }
        let rows = try? context.fetch(
            FetchDescriptor<Device>(
                predicate: #Predicate<Device> { $0.id == deviceId }
            )
        )
        guard let owner = rows?.first else { return nil }
        let id = owner.resolvedSiteId
        return id == 0 ? nil : id
    }

    static func fetchVOs(deviceId: Int64, in context: ModelContext) throws -> [InterfaceVO] {
        let descriptor = FetchDescriptor<Interface>(
            predicate: #Predicate<Interface> { $0.deviceId == deviceId }
        )
        return try context.fetch(descriptor).map(InterfaceVO.init(model:))
    }

    static func fetchCables(siteId: Int64, in context: ModelContext) throws -> [CableVO] {
        let descriptor = FetchDescriptor<Cable>(
            predicate: #Predicate<Cable> { $0.siteId == siteId }
        )
        return try context.fetch(descriptor).map(CableVO.init(model:))
    }

    /// Undirected, deduped. A link stored on both ends becomes one
    /// edge. Missing other end is dropped (no edge).
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
