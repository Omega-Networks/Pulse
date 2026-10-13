//
//  LicenseSeatEvaluator.swift
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

/// What one seat pass changed. A full mirror sets `replaceSeated` /
/// `replaceUnbilled` and the UI replaces its sets. A delta only lists
/// the ids that moved, so an idle pass does not read the device table.
struct SyncSeatUpdate: Sendable, Equatable {
    var granted: Set<Int64> = []
    var revoked: Set<Int64> = []
    var unbilled: Set<Int64> = []
    var removed: Set<Int64> = []
    var replaceSeated: Set<Int64>?
    var replaceUnbilled: Set<Int64>?

    static let empty = SyncSeatUpdate()

    var isEmpty: Bool {
        granted.isEmpty && revoked.isEmpty && unbilled.isEmpty
            && removed.isEmpty && replaceSeated == nil
    }

    var replacesMemory: Bool { replaceSeated != nil }
}

/// Actor-safe seat checks. `requireAdmit` / `requireLink` /
/// `requireSeated` are write gates. Sync does not call them. It calls
/// `grantArrivals` or `grantMirroredStore` after the rows are saved.
enum LicenseSeatEvaluator {
    static func presentation(defaults: UserDefaults = .standard) -> RolePresentation {
        RolePresentationStorage.load(from: defaults)
    }

    @discardableResult
    static func reconcile(
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        tier: SubscriptionTier,
        now: Date = Date()
    ) throws -> SeatReconcileResult {
        let devices = try context.fetch(FetchDescriptor<Device>())
        let result = LicenseSeatReconciler.reconcile(
            devices: devices.map { $0.seatSnapshot() },
            presentation: presentation(defaults: defaults),
            cap: tier.maxSeats,
            now: now
        )
        for device in devices {
            if let boxed = result.grants[device.id] {
                device.seatGrantedAt = boxed
            }
        }
        try context.save()
        return result
    }

    static func requireSeated(
        deviceID: Int64,
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        tier: SubscriptionTier
    ) throws {
        let presentation = presentation(defaults: defaults)
        if let roleID = try deviceRoleID(deviceID, in: context),
           !presentation.countsTowardLicense(roleID: roleID) {
            return
        }
        // Unlimited: every eligible device may write. Do not fetch the
        // whole device table on each PATCH.
        guard let cap = tier.maxSeats else { return }
        let effective = try effectiveGrantedIDs(
            in: context, presentation: presentation, cap: cap
        )
        if effective.contains(deviceID) { return }
        let result = try reconcile(in: context, defaults: defaults, tier: tier)
        guard result.effectiveIDs.contains(deviceID) else {
            throw BillingError.deviceNotSeated
        }
    }

    static func deviceRoleID(_ deviceID: Int64, in context: ModelContext) throws -> Int64? {
        let descriptor = FetchDescriptor<Device>(
            predicate: #Predicate<Device> { $0.id == deviceID }
        )
        return try context.fetch(descriptor).first?.deviceRole?.id
    }

    static func requireLink(
        a: Int64,
        b: Int64,
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        tier: SubscriptionTier
    ) throws {
        let presentation = presentation(defaults: defaults)
        let aCounts = presentation.countsTowardLicense(roleID: try deviceRoleID(a, in: context))
        let bCounts = presentation.countsTowardLicense(roleID: try deviceRoleID(b, in: context))
        if !aCounts && !bCounts { return }
        if !aCounts {
            try requireSeated(deviceID: b, in: context, defaults: defaults, tier: tier)
            return
        }
        if !bCounts {
            try requireSeated(deviceID: a, in: context, defaults: defaults, tier: tier)
            return
        }
        guard let cap = tier.maxSeats else { return }
        let effective = try effectiveGrantedIDs(
            in: context, presentation: presentation, cap: cap
        )
        if effective.contains(a) && effective.contains(b) { return }
        let result = try reconcile(in: context, defaults: defaults, tier: tier)
        guard result.effectiveIDs.contains(a), result.effectiveIDs.contains(b) else {
            throw BillingError.linkRequiresBothSeats
        }
    }

    static func requireAdmit(
        roleID: Int64?,
        additional: Int = 1,
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        tier: SubscriptionTier
    ) throws {
        let presentation = presentation(defaults: defaults)
        guard presentation.countsTowardLicense(roleID: roleID) else { return }
        guard let cap = tier.maxSeats else { return }
        let effective = try effectiveGrantedIDs(
            in: context, presentation: presentation, cap: cap
        )
        guard effective.count + additional <= cap else {
            throw BillingError.tierCapReached(tier)
        }
    }

    /// Persist a grant on a just-created row. One-id fetch. The operator
    /// just passed `requireAdmit`, so this row gets the open slot rather
    /// than waiting behind an older ungranted device. Does not rewrite
    /// the table.
    @discardableResult
    static func grantNewDevice(
        id: Int64,
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        tier: SubscriptionTier,
        now: Date = Date()
    ) throws -> SyncSeatUpdate {
        let presentation = presentation(defaults: defaults)
        var descriptor = FetchDescriptor<Device>(
            predicate: #Predicate<Device> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let device = try context.fetch(descriptor).first else { return .empty }
        guard presentation.countsTowardLicense(roleID: device.deviceRole?.id) else {
            return SyncSeatUpdate(unbilled: [id])
        }
        if device.seatGrantedAt != nil {
            return SyncSeatUpdate(granted: [id])
        }
        if let cap = tier.maxSeats {
            let effective = try effectiveGrantedIDs(
                in: context, presentation: presentation, cap: cap
            )
            guard effective.count < cap else { return .empty }
        }
        device.seatGrantedAt = now
        try context.save()
        return SyncSeatUpdate(granted: [id])
    }

    /// Seat devices a delta created, updated, or deleted. Reads those
    /// rows, plus the granted set when a cap applies. Does not fetch
    /// the device table. Under a cap, an open slot goes to the oldest
    /// ungranted eligible device. Unlimited grants only `deviceIDs`.
    static func grantArrivals(
        deviceIDs: [Int64],
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        tier: SubscriptionTier,
        now: Date = Date()
    ) throws -> SyncSeatUpdate {
        let presentation = presentation(defaults: defaults)
        let unique = Array(Set(deviceIDs))
        guard !unique.isEmpty else { return .empty }
        let rows = try Device.fetchMatchingIDs(unique, in: context)
        var update = SyncSeatUpdate()
        let found = Set(rows.map(\.id))
        update.removed = Set(unique.filter { !found.contains($0) })
        var cleared = false
        for device in rows {
            let counts = presentation.countsTowardLicense(roleID: device.deviceRole?.id)
            if !counts {
                update.unbilled.insert(device.id)
                if device.seatGrantedAt != nil {
                    device.seatGrantedAt = nil
                    update.revoked.insert(device.id)
                    cleared = true
                }
            }
        }
        if cleared {
            try context.save()
        }
        if let cap = tier.maxSeats {
            let grantedRows = try context.fetch(
                FetchDescriptor<Device>(
                    predicate: #Predicate<Device> { $0.seatGrantedAt != nil }
                )
            )
            let effective = LicenseSeatReconciler.effectiveIDs(
                devices: grantedRows.map { $0.seatSnapshot() },
                presentation: presentation,
                cap: cap
            )
            let room = cap - effective.count
            if room > 0 {
                let winners = try oldestEligibleUngranted(
                    limit: room, presentation: presentation, in: context
                )
                if !winners.isEmpty {
                    for device in winners {
                        device.seatGrantedAt = now
                        update.granted.insert(device.id)
                    }
                    try context.save()
                }
            }
            for device in rows where effective.contains(device.id) {
                update.granted.insert(device.id)
            }
        } else {
            var changed = false
            for device in rows {
                guard presentation.countsTowardLicense(roleID: device.deviceRole?.id) else { continue }
                if device.seatGrantedAt == nil {
                    device.seatGrantedAt = now
                    changed = true
                }
                update.granted.insert(device.id)
            }
            if changed {
                try context.save()
            }
        }
        return update
    }

    /// Boot, Apply changes, Full Resync, and a failed boot. Seats every
    /// eligible device that lacks a grant and clears hardware grants.
    /// Rows that already hold the right stamp are not written back.
    static func grantMirroredStore(
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        tier: SubscriptionTier,
        now: Date = Date()
    ) throws -> SyncSeatUpdate {
        let presentation = presentation(defaults: defaults)
        let devices = try context.fetch(FetchDescriptor<Device>())
        let result = LicenseSeatReconciler.reconcile(
            devices: devices.map { $0.seatSnapshot() },
            presentation: presentation,
            cap: tier.maxSeats,
            now: now
        )
        var changed = false
        for device in devices {
            guard let stamped = result.grants[device.id] else { continue }
            if device.seatGrantedAt != stamped {
                device.seatGrantedAt = stamped
                changed = true
            }
        }
        if changed {
            try context.save()
        }
        let unbilled = Set(
            devices
                .filter { !presentation.countsTowardLicense(roleID: $0.deviceRole?.id) }
                .map(\.id)
        )
        return SyncSeatUpdate(
            replaceSeated: result.effectiveIDs,
            replaceUnbilled: unbilled
        )
    }

    /// Oldest eligible devices that do not yet hold a seat. Hardware
    /// roles are excluded in the predicate so a rack full of blanks
    /// does not crowd the fetch limit.
    private static func oldestEligibleUngranted(
        limit: Int,
        presentation: RolePresentation,
        in context: ModelContext
    ) throws -> [Device] {
        guard limit > 0 else { return [] }
        let hardware = presentation.policies.compactMap { id, policy -> Int64? in
            policy.countsTowardLicense ? nil : id
        }
        let sort = [
            SortDescriptor(\Device.created, order: .forward),
            SortDescriptor(\Device.id, order: .forward),
        ]
        var descriptor: FetchDescriptor<Device>
        if hardware.isEmpty {
            descriptor = FetchDescriptor<Device>(
                predicate: #Predicate<Device> { $0.seatGrantedAt == nil },
                sortBy: sort
            )
        } else {
            descriptor = FetchDescriptor<Device>(
                predicate: #Predicate<Device> { device in
                    device.seatGrantedAt == nil
                        && (device.deviceRole == nil || !hardware.contains(device.deviceRole!.id))
                },
                sortBy: sort
            )
        }
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    private static func effectiveGrantedIDs(
        in context: ModelContext,
        presentation: RolePresentation,
        cap: Int
    ) throws -> Set<Int64> {
        var grantedFetch = FetchDescriptor<Device>(
            predicate: #Predicate<Device> { $0.seatGrantedAt != nil }
        )
        let granted = try context.fetch(grantedFetch)
        return LicenseSeatReconciler.effectiveIDs(
            devices: granted.map { $0.seatSnapshot() },
            presentation: presentation,
            cap: cap
        )
    }

    static func deviceID(forInterface id: Int64, in context: ModelContext) throws -> Int64 {
        let descriptor = FetchDescriptor<Interface>(
            predicate: #Predicate<Interface> { $0.id == id }
        )
        guard let row = try context.fetch(descriptor).first else {
            throw BillingError.deviceNotSeated
        }
        if row.deviceId != 0 { return row.deviceId }
        if let owner = row.device?.id { return owner }
        throw BillingError.deviceNotSeated
    }

    static func deviceID(forFrontPort id: Int64, in context: ModelContext) throws -> Int64 {
        let descriptor = FetchDescriptor<FrontPort>(
            predicate: #Predicate<FrontPort> { $0.id == id }
        )
        guard let row = try context.fetch(descriptor).first else {
            throw BillingError.deviceNotSeated
        }
        if row.deviceId != 0 { return row.deviceId }
        if let owner = row.device?.id { return owner }
        throw BillingError.deviceNotSeated
    }

    static func peerDeviceID(forInterface id: Int64, in context: ModelContext) throws -> Int64 {
        let descriptor = FetchDescriptor<Interface>(
            predicate: #Predicate<Interface> { $0.id == id }
        )
        guard let row = try context.fetch(descriptor).first else {
            throw BillingError.linkRequiresBothSeats
        }
        if let peer = row.connectedEndpointDeviceId, peer != 0 {
            return peer
        }
        if let peerID = row.connectedEndpointId {
            if let asInterface = try? deviceID(forInterface: peerID, in: context) {
                return asInterface
            }
            if let asPort = try? deviceID(forFrontPort: peerID, in: context) {
                return asPort
            }
        }
        throw BillingError.linkRequiresBothSeats
    }

    static func requireLinkIfPeerKnown(
        deviceID: Int64,
        peer: Int64?,
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        tier: SubscriptionTier
    ) throws {
        if let peer {
            try requireLink(a: deviceID, b: peer, in: context, defaults: defaults, tier: tier)
        } else {
            try requireSeated(deviceID: deviceID, in: context, defaults: defaults, tier: tier)
        }
    }

    static func requireSeatedEnds(
        interfaceIDs: [Int64],
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        tier: SubscriptionTier
    ) throws {
        var deviceIDs: [Int64] = []
        for id in interfaceIDs {
            if let deviceID = try? deviceID(forInterface: id, in: context) {
                deviceIDs.append(deviceID)
            } else if let deviceID = try? deviceID(forFrontPort: id, in: context) {
                deviceIDs.append(deviceID)
            } else {
                throw BillingError.linkRequiresBothSeats
            }
        }
        let unique = Array(Set(deviceIDs))
        if unique.count >= 2 {
            try requireLink(a: unique[0], b: unique[1], in: context, defaults: defaults, tier: tier)
        } else if let only = unique.first {
            try requireSeated(deviceID: only, in: context, defaults: defaults, tier: tier)
        } else {
            throw BillingError.linkRequiresBothSeats
        }
    }

    static func peerDeviceID(forFrontPort id: Int64, in context: ModelContext) throws -> Int64 {
        let descriptor = FetchDescriptor<FrontPort>(
            predicate: #Predicate<FrontPort> { $0.id == id }
        )
        guard let row = try context.fetch(descriptor).first else {
            throw BillingError.linkRequiresBothSeats
        }
        guard let peerID = row.connectedEndpointId else {
            throw BillingError.linkRequiresBothSeats
        }
        if row.connectedEndpointType == "dcim.interface" {
            return try deviceID(forInterface: peerID, in: context)
        }
        if row.connectedEndpointType == "dcim.frontport" {
            return try deviceID(forFrontPort: peerID, in: context)
        }
        if let asInterface = try? deviceID(forInterface: peerID, in: context) {
            return asInterface
        }
        if let asPort = try? deviceID(forFrontPort: peerID, in: context) {
            return asPort
        }
        throw BillingError.linkRequiresBothSeats
    }
}
