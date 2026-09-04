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

/// Reconciles seats when the cap, Roles checkboxes, or NetBox apply change.
struct SeatReconcilerHost: View {
    var entitlements: EntitlementStore
    var seats: LicenseSeatStore
    var roles: RolePresentationStore
    let container: ModelContainer

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: entitlements.tier) { _, _ in reconcile() }
            .onChange(of: roles.presentation) { _, _ in reconcile() }
            .onReceive(NotificationCenter.default.publisher(for: .netBoxStoreDidApply)) { _ in
                reconcile()
            }
            .task { reconcile() }
    }

    private func reconcile() {
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
