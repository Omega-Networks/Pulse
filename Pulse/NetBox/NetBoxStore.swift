//
//  NetBoxStore.swift
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
import OSLog
import SwiftData

/// Unified upsert + stale-delete for NetBox types.
///
/// Insert lives in the same path as update. Delete runs only when the caller
/// marks the fetch complete **and** no records were skipped on any page.
enum NetBoxStore {
    private static let logger = Logger(subsystem: "netbox", category: "store")

    struct ApplyResult: Equatable, Sendable {
        var upserted: Int
        var deleted: Int
        var didDelete: Bool
    }

    static func shouldDelete(fetchComplete: Bool, skipped: Int) -> Bool {
        fetchComplete && skipped == 0
    }

    // MARK: - Tenant groups

    static func applyTenantGroups(
        _ records: [NetBoxRecord.TenantGroup],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        try upsert(records, in: context) { record, model in
            model.name = record.name
            model.created = record.created
            model.lastUpdated = record.lastUpdated
        } create: {
            TenantGroup(id: $0.id)
        }
        let deleted = try deleteStale(
            TenantGroup.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Tenants

    static func applyTenants(
        _ records: [NetBoxRecord.Tenant],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        let groups = try fetchByIDs(TenantGroup.self, ids: records.compactMap(\.groupID), in: context)
        try upsert(records, in: context) { record, model in
            model.name = record.name
            model.created = record.created
            model.lastUpdated = record.lastUpdated
            if let groupID = record.groupID {
                if let group = groups[groupID] {
                    model.group = group
                } else {
                    logger.error("Tenant \(record.id) group \(groupID) missing; leaving nil")
                    model.group = nil
                }
            } else {
                model.group = nil
            }
        } create: {
            Tenant(id: $0.id)
        }
        let deleted = try deleteStale(
            Tenant.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Regions

    static func applyRegions(
        _ records: [NetBoxRecord.Region],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        try upsert(records, in: context) { record, model in
            model.name = record.name
            model.created = record.created
            model.lastUpdated = record.lastUpdated
            model.siteCount = record.siteCount
        } create: {
            Region(id: $0.id)
        }
        let byID = try fetchByIDs(Region.self, ids: records.map(\.id), in: context)
        for record in records {
            guard let model = byID[record.id] else { continue }
            if let parentID = record.parentID {
                model.parent = byID[parentID]
                if model.parent == nil {
                    logger.error("Region \(record.id) parent \(parentID) missing; leaving nil")
                }
            } else {
                model.parent = nil
            }
        }
        let deleted = try deleteStale(
            Region.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Device roles

    static func applyDeviceRoles(
        _ records: [NetBoxRecord.DeviceRole],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        try upsert(records, in: context) { record, model in
            model.name = record.name
            model.created = record.created
            model.lastUpdated = record.lastUpdated
            model.colour = record.colour
        } create: {
            DeviceRole(id: $0.id)
        }
        let deleted = try deleteStale(
            DeviceRole.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Device types

    static func applyDeviceTypes(
        _ records: [NetBoxRecord.DeviceType],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        try upsert(records, in: context) { record, model in
            model.model = record.model
            model.created = record.created
            model.lastUpdated = record.lastUpdated
            model.uHeight = record.uHeight
        } create: {
            DeviceType(id: $0.id)
        }
        let deleted = try deleteStale(
            DeviceType.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Site groups

    static func applySiteGroups(
        _ records: [NetBoxRecord.SiteGroup],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        try upsert(records, in: context) { record, model in
            model.name = record.name
            model.created = record.created
            model.lastUpdated = record.lastUpdated
        } create: {
            SiteGroup(id: $0.id)
        }
        let byID = try fetchByIDs(SiteGroup.self, ids: records.map(\.id), in: context)
        for record in records {
            guard let model = byID[record.id] else { continue }
            if let parentID = record.parentID {
                model.parent = byID[parentID]
                if model.parent == nil {
                    logger.error("SiteGroup \(record.id) parent \(parentID) missing; leaving nil")
                }
            } else {
                model.parent = nil
            }
        }
        let deleted = try deleteStale(
            SiteGroup.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Sites

    static func applySites(
        _ records: [NetBoxRecord.Site],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        let regions = try fetchByIDs(Region.self, ids: records.compactMap(\.regionID), in: context)
        let groups = try fetchByIDs(SiteGroup.self, ids: records.compactMap(\.groupID), in: context)
        let tenants = try fetchByIDs(Tenant.self, ids: records.compactMap(\.tenantID), in: context)
        try upsert(records, in: context) { record, model in
            model.name = record.name
            model.display = record.display
            model.url = record.url
            model.created = record.created
            model.lastUpdated = record.lastUpdated
            model.latitude = record.latitude
            model.longitude = record.longitude
            model.physicalAddress = record.physicalAddress
            model.shippingAddress = record.shippingAddress
            model.status = record.status
            model.deviceCount = record.deviceCount
            if let regionID = record.regionID {
                if let region = regions[regionID] {
                    model.region = region
                } else {
                    logger.error("Site \(record.id) region \(regionID) missing; leaving nil")
                    model.region = nil
                }
            } else {
                model.region = nil
            }
            if let groupID = record.groupID {
                if let group = groups[groupID] {
                    model.group = group
                } else {
                    logger.error("Site \(record.id) group \(groupID) missing; leaving nil")
                    model.group = nil
                }
            } else {
                model.group = nil
            }
            if let tenantID = record.tenantID {
                if let tenant = tenants[tenantID] {
                    model.tenant = tenant
                } else {
                    logger.error("Site \(record.id) tenant \(tenantID) missing; leaving nil")
                    model.tenant = nil
                }
            } else {
                model.tenant = nil
            }
        } create: {
            Site(id: $0.id)
        }
        let deleted = try deleteStale(
            Site.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Racks

    static func applyRacks(
        _ records: [NetBoxRecord.Rack],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        let sites = try fetchByIDs(Site.self, ids: records.compactMap(\.siteID), in: context)
        try upsert(records, in: context) { record, model in
            model.name = record.name
            model.display = record.display
            model.url = record.url
            model.created = record.created
            model.lastUpdated = record.lastUpdated
            model.uHeight = record.uHeight
            model.startingUnit = record.startingUnit
            model.deviceCount = record.deviceCount
            model.status = record.status
            model.formFactor = record.formFactor
            if let siteID = record.siteID {
                if let site = sites[siteID] {
                    model.site = site
                } else {
                    logger.error("Rack \(record.id) site \(siteID) missing; leaving nil")
                    model.site = nil
                }
            } else {
                model.site = nil
            }
        } create: {
            Rack(id: $0.id)
        }
        let deleted = try deleteStale(
            Rack.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Devices

    static func applyDevices(
        _ records: [NetBoxRecord.Device],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        let sites = try fetchByIDs(Site.self, ids: records.map(\.siteID), in: context)
        let roles = try fetchByIDs(DeviceRole.self, ids: records.map(\.roleID), in: context)
        let types = try fetchByIDs(DeviceType.self, ids: records.map(\.typeID), in: context)
        let racks = try fetchByIDs(Rack.self, ids: records.compactMap(\.rackID), in: context)
        try upsert(records, in: context) { record, model in
            model.name = record.name
            model.display = record.display
            model.url = record.url
            model.created = record.created
            model.lastUpdated = record.lastUpdated
            model.serial = record.serial
            model.primaryIP = record.primaryIP
            model.status = record.status
            model.rackPosition = record.rackPosition
            model.x = record.x
            model.y = record.y
            model.zabbixId = record.zabbixID
            model.zabbixInstance = record.zabbixInstance
            if let site = sites[record.siteID] {
                model.site = site
            } else {
                logger.error("Device \(record.id) site \(record.siteID) missing; leaving nil")
                model.site = nil
            }
            if let role = roles[record.roleID] {
                model.deviceRole = role
            } else {
                logger.error("Device \(record.id) role \(record.roleID) missing; leaving nil")
                model.deviceRole = nil
            }
            if let type = types[record.typeID] {
                model.deviceType = type
            } else {
                logger.error("Device \(record.id) type \(record.typeID) missing; leaving nil")
                model.deviceType = nil
            }
            if let rackID = record.rackID {
                if let rack = racks[rackID] {
                    model.rack = rack
                } else {
                    logger.error("Device \(record.id) rack \(rackID) missing; leaving nil")
                    model.rack = nil
                }
            } else {
                model.rack = nil
            }
        } create: {
            Device(id: $0.id)
        }
        let deleted = try deleteStale(
            Device.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Services

    static func applyServices(
        _ records: [NetBoxRecord.Service],
        fetchComplete: Bool,
        skipped: Int,
        in context: ModelContext
    ) throws -> ApplyResult {
        let deviceIDs = records
            .filter { $0.parentObjectType == "dcim.device" }
            .map(\.parentObjectID)
        let devices = try fetchByIDs(Device.self, ids: deviceIDs, in: context)
        try upsert(records, in: context) { record, model in
            model.name = record.name
            model.display = record.display
            model.url = record.url
            model.serviceDescription = record.serviceDescription
            model.protocolValue = record.protocolValue
            model.protocolLabel = record.protocolLabel
            model.ports = record.ports
            model.ipAddresses = record.ipAddresses
            model.parentObjectType = record.parentObjectType
            model.parentObjectId = record.parentObjectID
            model.parentName = record.parentName
            if record.parentObjectType == "dcim.device" {
                model.device = devices[record.parentObjectID]
            } else {
                model.device = nil
            }
        } create: {
            Service(id: $0.id)
        }
        let deleted = try deleteStale(
            Service.self,
            keeping: Set(records.map(\.id)),
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return ApplyResult(
            upserted: records.count,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped)
        )
    }

    // MARK: - Interfaces

    struct InterfaceApplyResult: Equatable, Sendable {
        var upserted: Int
        var outOfScope: Int
        var deleted: Int
        var didDelete: Bool
        var acceptedIDs: Set<Int64>
    }

    /// Upsert a page of interfaces. Unresolved device or a device with no
    /// site is out of scope (logged, not stored, not counted as `skipped`).
    ///
    /// Delete runs only when `fetchComplete && skipped == 0`. Pass the
    /// union of every accepted id from the walk in `keeping`; passing only
    /// the last page's ids would delete earlier pages.
    static func applyInterfaces(
        _ records: [NetBoxRecord.Interface],
        fetchComplete: Bool,
        skipped: Int,
        keeping: Set<Int64>,
        in context: ModelContext
    ) throws -> InterfaceApplyResult {
        let deviceIDs = records.compactMap(\.deviceID)
        let devices = try fetchByIDs(Device.self, ids: deviceIDs, in: context)

        var accepted: [NetBoxRecord.Interface] = []
        var acceptedIDs = Set<Int64>()
        var siteByDevice: [Int64: Int64] = [:]
        var missingDeviceIDs = Set<Int64>()
        var outOfScope = 0
        for record in records {
            guard let deviceID = record.deviceID, let device = devices[deviceID] else {
                if let deviceID = record.deviceID {
                    missingDeviceIDs.insert(deviceID)
                }
                outOfScope += 1
                continue
            }
            accepted.append(record)
            acceptedIDs.insert(record.id)
            siteByDevice[deviceID] = device.site?.id ?? 0
        }
        if !missingDeviceIDs.isEmpty {
            let sample = missingDeviceIDs.sorted().prefix(5).map(String.init).joined(separator: ", ")
            logger.error(
                "Dropped \(outOfScope) interfaces whose device is not in the store (\(missingDeviceIDs.count) devices, e.g. \(sample)). Filtered or not yet synced."
            )
        }

        try upsert(accepted, in: context) { record, model in
            let deviceID = record.deviceID!
            model.name = record.name
            model.display = record.display
            model.url = record.url
            model.created = record.created
            model.lastUpdated = record.lastUpdated
            model.type = record.type
            model.label = record.label
            model.enabled = record.enabled
            model.mtu = record.mtu
            model.speed = record.speed
            model.interfaceDescription = record.interfaceDescription
            model.poeMode = record.poeMode
            model.duplex = record.duplex
            model.occupied = record.occupied
            model.deviceId = deviceID
            model.siteId = siteByDevice[deviceID]!
            model.deviceName = record.deviceName
            model.connectedEndpointId = record.connectedEndpointID
            model.connectedEndpointName = record.connectedEndpointName
            model.connectedEndpointDeviceId = record.connectedEndpointDeviceID
            model.lagId = record.lagID
            model.lagName = record.lagName
            model.bridgeId = record.bridgeID
            model.bridgeName = record.bridgeName
            model.parentId = record.parentID
            model.parentName = record.parentName
            model.device = devices[deviceID]
        } create: {
            Interface(id: $0.id)
        }

        let deleted = try deleteStale(
            Interface.self,
            keeping: keeping,
            allowed: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            in: context
        )
        try context.save()
        return InterfaceApplyResult(
            upserted: accepted.count,
            outOfScope: outOfScope,
            deleted: max(0, deleted),
            didDelete: shouldDelete(fetchComplete: fetchComplete, skipped: skipped),
            acceptedIDs: acceptedIDs
        )
    }

    // MARK: - Internals

    private static func upsert<Record, Model>(
        _ records: [Record],
        in context: ModelContext,
        apply: (Record, Model) -> Void,
        create: (Record) -> Model
    ) throws where Record: NetBoxRecordID, Model: PersistentModel & NetBoxIdentified {
        var existing = try fetchByIDs(Model.self, ids: records.map(\.id), in: context)
        for record in records {
            if let model = existing[record.id] {
                apply(record, model)
            } else {
                let model = create(record)
                apply(record, model)
                context.insert(model)
                existing[record.id] = model
            }
        }
    }

    private static func fetchByIDs<T: PersistentModel & NetBoxIdentified>(
        _ type: T.Type,
        ids: [Int64],
        in context: ModelContext
    ) throws -> [Int64: T] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<T>(
            predicate: #Predicate<T> { unique.contains($0.id) }
        )
        let rows = try withUserInitiatedQoS {
            try context.fetch(descriptor)
        }
        var map: [Int64: T] = [:]
        map.reserveCapacity(rows.count)
        for row in rows {
            map[row.id] = row
        }
        return map
    }

    /// Returns the number of rows deleted, or `-1` if the pass was not allowed.
    @discardableResult
    private static func deleteStale<T: PersistentModel & NetBoxIdentified>(
        _ type: T.Type,
        keeping ids: Set<Int64>,
        allowed: Bool,
        in context: ModelContext
    ) throws -> Int {
        guard allowed else { return -1 }
        // Full-type scan for the delete pass. Promote QoS so SwiftData's
        // internal queue cannot sit at Background while a User-initiated
        // caller waits (Instruments hang risk).
        let existing = try withUserInitiatedQoS {
            try context.fetch(FetchDescriptor<T>())
        }
        var deleted = 0
        for row in existing where !ids.contains(row.id) {
            context.delete(row)
            deleted += 1
        }
        return deleted
    }

    private static func withUserInitiatedQoS<T>(_ work: () throws -> T) rethrows -> T {
        let previous = Thread.current.qualityOfService
        if previous.rawValue < QualityOfService.userInitiated.rawValue {
            Thread.current.qualityOfService = .userInitiated
        }
        defer { Thread.current.qualityOfService = previous }
        return try work()
    }
}

private protocol NetBoxRecordID {
    var id: Int64 { get }
}

extension NetBoxRecord.TenantGroup: NetBoxRecordID {}
extension NetBoxRecord.Tenant: NetBoxRecordID {}
extension NetBoxRecord.Region: NetBoxRecordID {}
extension NetBoxRecord.DeviceRole: NetBoxRecordID {}
extension NetBoxRecord.DeviceType: NetBoxRecordID {}
extension NetBoxRecord.SiteGroup: NetBoxRecordID {}
extension NetBoxRecord.Site: NetBoxRecordID {}
extension NetBoxRecord.Rack: NetBoxRecordID {}
extension NetBoxRecord.Device: NetBoxRecordID {}
extension NetBoxRecord.Service: NetBoxRecordID {}
extension NetBoxRecord.Interface: NetBoxRecordID {}

private protocol NetBoxIdentified: AnyObject {
    var id: Int64 { get }
}

extension TenantGroup: NetBoxIdentified {}
extension Tenant: NetBoxIdentified {}
extension Region: NetBoxIdentified {}
extension DeviceRole: NetBoxIdentified {}
extension DeviceType: NetBoxIdentified {}
extension SiteGroup: NetBoxIdentified {}
extension Site: NetBoxIdentified {}
extension Rack: NetBoxIdentified {}
extension Device: NetBoxIdentified {}
extension Service: NetBoxIdentified {}
extension Interface: NetBoxIdentified {}
