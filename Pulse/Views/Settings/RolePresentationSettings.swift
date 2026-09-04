//
//  RolePresentationSettings.swift
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

/// Per-role surface toggles. These do not change the NetBox pull.
struct RolePresentationSettings: View {
    @Environment(RolePresentationStore.self) private var store
    @Environment(LicenseSeatStore.self) private var seats
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DeviceRole.name) private var roles: [DeviceRole]
    @State private var roleCapMessage: String?
    @State private var showingPaywall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pulse stores every device from NetBox. These toggles only change this app: where a role appears and whether it is monitored.")
                .foregroundStyle(.secondary)
                .font(.callout)

            if roles.isEmpty {
                ContentUnavailableView(
                    "No device roles",
                    systemImage: "server.rack",
                    description: Text("Run a Full Resync first.")
                )
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Role")
                                .font(.subheadline.weight(.semibold))
                            header("Site graph", tip: "Show this role as a node on the site topology. Patch panels and blanks are usually off.")
                            header("Device list", tip: "Show this role in the site device list.")
                            header("In rack", tip: "Draw this role in the rack elevation at its U position. Off leaves that space empty.")
                            header("As hardware", tip: "Draw it as rack hardware (panel, blank, shelf) instead of a named device with severity colour.")
                            header("No monitoring", tip: "Do not pull Zabbix items for this role. Use this when the role has no telemetry.")
                        }
                        Divider()
                            .gridCellUnsizedAxes(.horizontal)
                            .gridCellColumns(6)
                        ForEach(roles) { role in
                            let policy = store.policy(for: role.id)
                            GridRow {
                                Text(title(for: role))
                                    .lineLimit(1)
                                    .frame(minWidth: 140, alignment: .leading)
                                cell(role.id, policy, \.hideFromGraph, inverted: true)
                                cell(role.id, policy, \.hideFromDeviceList, inverted: true)
                                cell(role.id, policy, \.showInRack, inverted: false)
                                cell(role.id, policy, \.treatAsFiller, inverted: false)
                                cell(role.id, policy, \.skipMonitoring, inverted: false)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(12)
        .navigationTitle("Device Roles")
        .alert("Subscribe to resume", isPresented: Binding(
            get: { roleCapMessage != nil },
            set: { if !$0 { roleCapMessage = nil } }
        )) {
            Button("Subscribe") {
                roleCapMessage = nil
                showingPaywall = true
            }
            Button("OK", role: .cancel) { roleCapMessage = nil }
        } message: {
            Text(roleCapMessage ?? "")
        }
        .modifier(SubscriptionPaywallSheet(isPresented: $showingPaywall))
    }

    private func title(for role: DeviceRole) -> String {
        if let name = role.name, !name.isEmpty { return name }
        return "Role \(role.id)"
    }

    private func header(_ title: String, tip: String) -> some View {
        ColumnHeader(title: title, tip: tip)
            .frame(minWidth: 88, alignment: .center)
    }

    private func cell(
        _ roleID: Int64,
        _ policy: RolePolicy,
        _ keyPath: WritableKeyPath<RolePolicy, Bool>,
        inverted: Bool
    ) -> some View {
        Toggle("", isOn: flag(roleID, policy, keyPath, inverted: inverted))
            .labelsHidden()
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .frame(maxWidth: .infinity)
    }

    private func applyPolicy(_ next: RolePolicy, for roleID: Int64, previous: RolePolicy) {
        if !previous.countsTowardLicense && next.countsTowardLicense {
            let adding = deviceCount(for: roleID)
            if adding > 0 {
                let allowed = (try? seats.canAdmitEligible(
                    additional: adding,
                    in: modelContext,
                    presentation: store.presentation,
                    tier: entitlements.tier
                )) ?? false
                if !allowed {
                    roleCapMessage = entitlements.tier.capReachedMessage()
                    return
                }
            }
        }
        store.setPolicy(next, for: roleID)
    }

    private func deviceCount(for roleID: Int64) -> Int {
        let matchingRoleID = roleID
        let descriptor = FetchDescriptor<Device>(
            predicate: #Predicate<Device> { $0.deviceRole?.id == matchingRoleID }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func flag(
        _ roleID: Int64,
        _ policy: RolePolicy,
        _ keyPath: WritableKeyPath<RolePolicy, Bool>,
        inverted: Bool
    ) -> Binding<Bool> {
        Binding(
            get: {
                let stored = policy[keyPath: keyPath]
                return inverted ? !stored : stored
            },
            set: { newValue in
                var next = policy
                next[keyPath: keyPath] = inverted ? !newValue : newValue
                applyPolicy(next, for: roleID, previous: policy)
            }
        )
    }
}

private struct ColumnHeader: View {
    let title: String
    let tip: String
    @State private var showing = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Button {
                showing.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(tip)
            .accessibilityLabel(tip)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Text(tip)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 260, alignment: .leading)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}
