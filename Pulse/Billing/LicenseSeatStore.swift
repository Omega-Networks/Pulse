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
    /// Devices whose role does not count toward the license (panels,
    /// blanks, shelves). They never hold a seat, but Connect / Disconnect
    /// and other operator actions still have to work.
    private(set) var unbilledIDs: Set<Int64> = []

    func allowsActions(deviceID: Int64) -> Bool {
        unbilledIDs.contains(deviceID) || seatedIDs.contains(deviceID)
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
        allowsActions(deviceID: a) && allowsActions(deviceID: b)
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
        seatedIDs = result.effectiveIDs
        unbilledIDs = Self.unbilledIDs(in: snapshots, presentation: presentation)
        return result
    }

    /// Replace or merge the in-memory sets from a sync notice. Does not
    /// fetch or save. The engine already wrote the grants.
    func apply(_ update: SyncSeatUpdate) {
        if let seated = update.replaceSeated, let unbilled = update.replaceUnbilled {
            seatedIDs = seated
            unbilledIDs = unbilled
            return
        }
        seatedIDs.subtract(update.removed)
        seatedIDs.subtract(update.revoked)
        seatedIDs.subtract(update.unbilled)
        unbilledIDs.subtract(update.removed)
        unbilledIDs.subtract(update.granted)
        unbilledIDs.formUnion(update.unbilled)
        seatedIDs.formUnion(update.granted)
    }

    /// Launch read finished. Keep ids a sync notice already added, and
    /// do not resurrect ids that notice removed.
    func mergeLoaded(seated: Set<Int64>, unbilled: Set<Int64>) {
        seatedIDs.formUnion(seated)
        unbilledIDs.formUnion(unbilled)
        seatedIDs.subtract(unbilled)
    }

    /// Seated and unbilled ids already stored. Does not grant and does
    /// not fetch devices that count toward the license and have no seat.
    static func readEffectiveSets(
        in context: ModelContext,
        presentation: RolePresentation,
        tier: SubscriptionTier
    ) throws -> (seated: Set<Int64>, unbilled: Set<Int64>) {
        let granted = try context.fetch(
            FetchDescriptor<Device>(
                predicate: #Predicate<Device> { $0.seatGrantedAt != nil }
            )
        )
        let seated = LicenseSeatReconciler.effectiveIDs(
            devices: granted.map { $0.seatSnapshot() },
            presentation: presentation,
            cap: tier.maxSeats
        )
        var unbilled: Set<Int64> = []
        let hardwareRoles = presentation.policies.compactMap { id, policy -> Int64? in
            policy.countsTowardLicense ? nil : id
        }
        for roleID in hardwareRoles {
            let match = roleID
            let rows = try context.fetch(
                FetchDescriptor<Device>(
                    predicate: #Predicate<Device> { $0.deviceRole?.id == match }
                )
            )
            for row in rows {
                unbilled.insert(row.id)
            }
        }
        return (seated, unbilled)
    }

    private static func unbilledIDs(
        in snapshots: [SeatSnapshot],
        presentation: RolePresentation
    ) -> Set<Int64> {
        Set(snapshots.filter { !presentation.countsTowardLicense(roleID: $0.roleID) }.map(\.id))
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
