//
//  LicenseSeatStore.swift
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
import Observation
import SwiftData

/// Applies seating to SwiftData and answers `allowsActions`.
@Observable
final class LicenseSeatStore: @unchecked Sendable {
    private(set) var seatedIDs: Set<Int64> = []

    func allowsActions(deviceID: Int64) -> Bool {
        seatedIDs.contains(deviceID)
    }

    /// Rack hardware (blanks, panels, shelves) is not billed, so it
    /// never holds a seat. Placement still has to work.
    func allowsRackEdit(
        deviceID: Int64,
        roleID: Int64?,
        presentation: RolePresentation
    ) -> Bool {
        if !presentation.countsTowardLicense(roleID: roleID) { return true }
        return allowsActions(deviceID: deviceID)
    }

    func allowsLink(a: Int64, b: Int64) -> Bool {
        seatedIDs.contains(a) && seatedIDs.contains(b)
    }

    @discardableResult
    func reconcile(
        in context: ModelContext,
        presentation: RolePresentation,
        tier: SubscriptionTier,
        now: Date = Date()
    ) throws -> SeatReconcileResult {
        let devices = try context.fetch(FetchDescriptor<Device>())
        let snapshots = devices.map { $0.seatSnapshot() }
        let result = LicenseSeatReconciler.reconcile(
            devices: snapshots,
            presentation: presentation,
            cap: tier.maxSeats,
            now: now
        )
        for device in devices {
            if let boxed = result.grants[device.id] {
                device.seatGrantedAt = boxed
            }
        }
        try context.save()
        seatedIDs = result.effectiveIDs
        return result
    }

    func refreshEffective(
        in context: ModelContext,
        presentation: RolePresentation,
        tier: SubscriptionTier
    ) throws {
        let devices = try context.fetch(FetchDescriptor<Device>())
        seatedIDs = LicenseSeatReconciler.effectiveIDs(
            devices: devices.map { $0.seatSnapshot() },
            presentation: presentation,
            cap: tier.maxSeats
        )
    }

    func canAdmitEligible(
        additional: Int,
        in context: ModelContext,
        presentation: RolePresentation,
        tier: SubscriptionTier
    ) throws -> Bool {
        let devices = try context.fetch(FetchDescriptor<Device>())
        return LicenseSeatReconciler.canAdmitEligible(
            additional: additional,
            devices: devices.map { $0.seatSnapshot() },
            presentation: presentation,
            cap: tier.maxSeats
        )
    }

    static func snapshots(in context: ModelContext) throws -> [SeatSnapshot] {
        try context.fetch(FetchDescriptor<Device>()).map { $0.seatSnapshot() }
    }
}
