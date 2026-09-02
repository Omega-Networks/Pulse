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

/// Actor-safe seat checks. Reconciles the store first so a free slot
/// is granted before the write runs. Sync never calls this.
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
        var grantedFetch = FetchDescriptor<Device>(
            predicate: #Predicate<Device> { $0.seatGrantedAt != nil }
        )
        let granted = try context.fetch(grantedFetch)
        let effective = LicenseSeatReconciler.effectiveIDs(
            devices: granted.map { $0.seatSnapshot() },
            presentation: presentation,
            cap: cap
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
        let result = try reconcile(in: context, defaults: defaults, tier: tier)
        guard let cap = tier.maxSeats else { return }
        guard result.effectiveIDs.count + additional <= cap else {
            throw BillingError.tierCapReached(tier)
        }
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
