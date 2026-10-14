//
//  PulseBillingEnvironment.swift
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

import SwiftData
import SwiftUI

struct PulseBillingEnvironment: ViewModifier {
    var entitlements: EntitlementStore
    var seats: LicenseSeatStore
    var roles: RolePresentationStore

    func body(content: Content) -> some View {
        content
            .environment(entitlements)
            .environment(seats)
            .environment(roles)
    }
}

/// Reconciles seats when the cap or Roles checkboxes change. Sync and
/// writes already persisted grants; this view only updates the in-memory
/// sets, and reads the store once at launch.
struct SeatReconcilerHost: View {
    var entitlements: EntitlementStore
    var seats: LicenseSeatStore
    var roles: RolePresentationStore
    let container: ModelContainer

    /// A full replace (mirror, tier, roles) wins over an in-flight launch read.
    @State private var replacedSeats = false
    /// Ids a delta removed after the launch read started.
    @State private var suppressedSeatIDs: Set<Int64> = []

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: entitlements.tier) { _, _ in reconcile() }
            .onChange(of: roles.presentation) { _, _ in reconcile() }
            .onReceive(NotificationCenter.default.publisher(for: .netBoxStoreDidApply)) { note in
                applyNotice(note)
            }
            .task { await loadSeats() }
    }

    private func reconcile() {
        replacedSeats = true
        suppressedSeatIDs = []
        do {
            try seats.reconcile(
                in: ModelContext(container),
                presentation: roles.presentation,
                tier: entitlements.tier
            )
        } catch {
            // Keep the last effective set. The next apply retries.
        }
    }

    private func applyNotice(_ note: Notification) {
        guard let info = note.userInfo?[NetBoxApplyInfo.userInfoKey] as? NetBoxApplyInfo else {
            return
        }
        guard !info.seatUpdate.isEmpty else { return }
        if info.seatUpdate.replacesMemory {
            replacedSeats = true
            suppressedSeatIDs = []
            seats.apply(info.seatUpdate)
            return
        }
        suppressedSeatIDs.formUnion(info.seatUpdate.removed)
        suppressedSeatIDs.formUnion(info.seatUpdate.revoked)
        suppressedSeatIDs.subtract(info.seatUpdate.granted)
        seats.apply(info.seatUpdate)
    }

    /// One read of grants and hardware roles. Does not grant. A mirror
    /// that finished while this was in flight already replaced the sets.
    private func loadSeats() async {
        let presentation = roles.presentation
        let tier = entitlements.tier
        let container = container
        let loaded = await Task.detached(priority: .userInitiated) {
            () -> (Set<Int64>, Set<Int64>)? in
            do {
                return try LicenseSeatStore.readEffectiveSets(
                    in: ModelContext(container),
                    presentation: presentation,
                    tier: tier
                )
            } catch {
                return nil
            }
        }.value
        guard let loaded, !replacedSeats else { return }
        seats.mergeLoaded(
            seated: loaded.0.subtracting(suppressedSeatIDs),
            unbilled: loaded.1.subtracting(suppressedSeatIDs)
        )
    }
}

extension View {
    func pulseBilling(
        entitlements: EntitlementStore,
        seats: LicenseSeatStore,
        roles: RolePresentationStore
    ) -> some View {
        modifier(
            PulseBillingEnvironment(
                entitlements: entitlements,
                seats: seats,
                roles: roles
            )
        )
    }
}
