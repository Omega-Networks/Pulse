//
//  View+Extensions.swift
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

import SwiftUI

extension View {
    /// Dims a posting or committed ask and badges a failed one.
    /// `showsFailureDetail` stays true on the graph and the rack. The
    /// problems table does not use this: inserting it replaces the cell,
    /// so the row cannot ease into the ask and back out.
    func ghosted(
        state: WriteState,
        showsEdit: Bool = true,
        showsFailureDetail: Bool = true,
        onEdit: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) -> some View {
        modifier(
            GhostedModifier(
                state: state,
                showsEdit: showsEdit,
                showsFailureDetail: showsFailureDetail,
                onEdit: onEdit,
                onDiscard: onDiscard
            )
        )
    }

    /// Pointing hand over a control that acts on click. macOS 15 draws
    /// this as `PointerStyle.link`. iOS has no pointer.
    @ViewBuilder
    func pointingHand(when enabled: Bool = true) -> some View {
        #if os(macOS)
        self.pointerStyle(enabled ? .link : .default)
        #else
        self
        #endif
    }

    /// One load for this host. `reset` runs before the first await, so the
    /// previous host's series is gone immediately. The task waits for that
    /// host's items and is cancelled when `deviceId` changes, which drops a
    /// reply that belongs to the host the operator has left.
    func zabbixItemLoad(
        deviceId: Int64,
        reset: @escaping @MainActor () -> Void,
        load: @escaping @MainActor () async -> Void
    ) -> some View {
        task(id: deviceId) {
            reset()
            await load()
            guard deviceId != 0 else { return }
            for await note in NotificationCenter.default.notifications(named: .itemsCached) {
                guard note.itemsCachedDeviceId == deviceId else { continue }
                await load()
            }
        }
    }
}
