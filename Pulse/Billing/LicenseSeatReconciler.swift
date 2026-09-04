//
//  LicenseSeatReconciler.swift
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

/// Pure seating. Durable facts are the cap and NetBox `created`/`id`.
/// `seatGrantedAt` is rank while the row survives.
struct SeatSnapshot: Equatable, Sendable {
    var id: Int64
    var roleID: Int64?
    var created: Date?
    var seatGrantedAt: Date?
}

struct SeatReconcileResult: Equatable, Sendable {
    /// id → new `seatGrantedAt` (nil = clear).
    var grants: [Int64: Date?]
    var effectiveIDs: Set<Int64>

    func grant(for id: Int64) -> Date? {
        if let boxed = grants[id] { return boxed }
        return nil
    }
}

enum LicenseSeatReconciler {
    static func reconcile(
        devices: [SeatSnapshot],
        presentation: RolePresentation,
        cap: Int?,
        now: Date
    ) -> SeatReconcileResult {
        var grants: [Int64: Date?] = [:]
        var eligible: [SeatSnapshot] = []
        eligible.reserveCapacity(devices.count)
        for device in devices {
            if presentation.countsTowardLicense(roleID: device.roleID) {
                eligible.append(device)
            } else {
                grants[device.id] = nil
            }
        }

        if cap == nil {
            var effective = Set<Int64>()
            for device in eligible {
                if let existing = device.seatGrantedAt {
                    grants[device.id] = existing
                } else {
                    grants[device.id] = now
                }
                effective.insert(device.id)
            }
            return SeatReconcileResult(grants: grants, effectiveIDs: effective)
        }

        let limit = cap!
        var withGrant = eligible.filter { $0.seatGrantedAt != nil }
        withGrant.sort { lhs, rhs in
            let a = lhs.seatGrantedAt ?? .distantFuture
            let b = rhs.seatGrantedAt ?? .distantFuture
            if a != b { return a < b }
            return lhs.id < rhs.id
        }
        for device in withGrant {
            grants[device.id] = device.seatGrantedAt
        }
        let effectiveGranted = Array(withGrant.prefix(limit))
        var effective = Set(effectiveGranted.map(\.id))

        let remaining = limit - effective.count
        if remaining > 0 {
            var waiting = eligible.filter { $0.seatGrantedAt == nil }
            waiting.sort { lhs, rhs in
                let a = lhs.created ?? .distantFuture
                let b = rhs.created ?? .distantFuture
                if a != b { return a < b }
                return lhs.id < rhs.id
            }
            for device in waiting.prefix(remaining) {
                grants[device.id] = now
                effective.insert(device.id)
            }
        }
        return SeatReconcileResult(grants: grants, effectiveIDs: effective)
    }

    /// Current effective set. Does not fill empty slots.
    static func effectiveIDs(
        devices: [SeatSnapshot],
        presentation: RolePresentation,
        cap: Int?
    ) -> Set<Int64> {
        let eligible = devices.filter { presentation.countsTowardLicense(roleID: $0.roleID) }
        var granted = eligible.filter { $0.seatGrantedAt != nil }
        granted.sort { lhs, rhs in
            let a = lhs.seatGrantedAt ?? .distantFuture
            let b = rhs.seatGrantedAt ?? .distantFuture
            if a != b { return a < b }
            return lhs.id < rhs.id
        }
        if let cap {
            return Set(granted.prefix(cap).map(\.id))
        }
        return Set(granted.map(\.id))
    }

    static func allowsActions(
        deviceID: Int64,
        devices: [SeatSnapshot],
        presentation: RolePresentation,
        cap: Int?
    ) -> Bool {
        if let device = devices.first(where: { $0.id == deviceID }),
           !presentation.countsTowardLicense(roleID: device.roleID) {
            return true
        }
        return effectiveIDs(devices: devices, presentation: presentation, cap: cap).contains(deviceID)
    }

    static func allowsRackEdit(
        deviceID: Int64,
        roleID: Int64?,
        devices: [SeatSnapshot],
        presentation: RolePresentation,
        cap: Int?
    ) -> Bool {
        if !presentation.countsTowardLicense(roleID: roleID) { return true }
        return allowsActions(
            deviceID: deviceID,
            devices: devices,
            presentation: presentation,
            cap: cap
        )
    }

    static func allowsLink(
        a: Int64,
        b: Int64,
        devices: [SeatSnapshot],
        presentation: RolePresentation,
        cap: Int?
    ) -> Bool {
        allowsActions(deviceID: a, devices: devices, presentation: presentation, cap: cap)
            && allowsActions(deviceID: b, devices: devices, presentation: presentation, cap: cap)
    }

    static func canAdmitEligible(
        additional: Int,
        devices: [SeatSnapshot],
        presentation: RolePresentation,
        cap: Int?
    ) -> Bool {
        guard additional > 0 else { return true }
        guard let cap else { return true }
        return effectiveIDs(devices: devices, presentation: presentation, cap: cap).count + additional <= cap
    }
}

extension Device {
    func seatSnapshot() -> SeatSnapshot {
        SeatSnapshot(
            id: id,
            roleID: deviceRole?.id,
            created: created,
            seatGrantedAt: seatGrantedAt
        )
    }
}
