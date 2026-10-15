//
//  GhostedModifier.swift
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

/// Posting and committed asks are dim and shimmer. A failed ask is solid,
/// shows NetBox's words, and offers Edit and Discard. Discard is not
/// offered while the POST is in flight.
struct GhostedModifier: ViewModifier {
    var state: WriteState
    var showsEdit: Bool
    var onEdit: () -> Void
    var onDiscard: () -> Void

    @State private var shimmer = false

    private var failedMessage: String? {
        if case .failed(let error) = state { return error.noticeMessage }
        return nil
    }

    func body(content: Content) -> some View {
        VStack(spacing: 6) {
            content
                .opacity(failedMessage == nil ? (shimmer ? 0.75 : 0.4) : 1)
            if let failedMessage {
                Text(failedMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                HStack(spacing: 8) {
                    if showsEdit {
                        Button("Edit", action: onEdit)
                    }
                    Button("Discard", action: onDiscard)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .allowsHitTesting(failedMessage != nil)
        .onAppear {
            guard failedMessage == nil else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
    }
}

/// Opens the existing new-device sheet with a failed ghost's fields.
/// The failed ask stays until that sheet creates. The default does
/// nothing, so a surface without that sheet still offers Discard.
struct DeviceGhostEditAction: Sendable {
    var isInstalled: Bool
    var open: @MainActor @Sendable (DeviceGhost) -> Void

    init(isInstalled: Bool = true, open: @escaping @MainActor @Sendable (DeviceGhost) -> Void) {
        self.isInstalled = isInstalled
        self.open = open
    }

    static let inactive = DeviceGhostEditAction(isInstalled: false) { _ in }
}

private struct DeviceGhostEditActionKey: EnvironmentKey {
    static let defaultValue = DeviceGhostEditAction.inactive
}

extension EnvironmentValues {
    var deviceGhostEdit: DeviceGhostEditAction {
        get { self[DeviceGhostEditActionKey.self] }
        set { self[DeviceGhostEditActionKey.self] = newValue }
    }
}

@MainActor
func discardDeviceGhost(_ ghost: DeviceGhost, engine: NetBoxSyncEngine?) {
    guard let engine else { return }
    Task { await engine.discard(ghost.token) }
}
