//
//  DeviceBuilder.swift
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
import SwiftData

#if os(macOS)
struct NewDeviceSheet: View {
    let siteId: Int64
    var onDismiss: () -> Void

    @Environment(\.netBoxSyncEngine) private var netBoxSyncEngine
    @Query(sort: \DeviceRole.name) private var roles: [DeviceRole]
    @Query(sort: \DeviceType.model) private var deviceTypes: [DeviceType]

    @State private var name = ""
    @State private var roleID: Int64?
    @State private var typeID: Int64?
    @State private var status = "active"
    @State private var isWriting = false
    @State private var writeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New device")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                TextField("Name", text: $name)
                Picker("Role", selection: $roleID) {
                    Text("Select…").tag(Optional<Int64>.none)
                    ForEach(roles) { role in
                        Text(role.name ?? "role \(role.id)").tag(Optional(role.id))
                    }
                }
                Picker("Type", selection: $typeID) {
                    Text("Select…").tag(Optional<Int64>.none)
                    ForEach(deviceTypes) { type in
                        Text(type.model ?? "type \(type.id)").tag(Optional(type.id))
                    }
                }
                Picker("Status", selection: $status) {
                    Text("Active").tag("active")
                    Text("Planned").tag("planned")
                    Text("Offline").tag("offline")
                }
            }

            if let writeError {
                Text(writeError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button(isWriting ? "Creating…" : "Create") {
                    Task { await create() }
                }
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    private var canCreate: Bool {
        !isWriting
            && netBoxSyncEngine != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && roleID != nil
            && typeID != nil
    }

    private func create() async {
        guard let engine = netBoxSyncEngine, let roleID, let typeID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            try await engine.createDevice(
                NetBoxWriteBody.DeviceCreate(
                    name: trimmed,
                    deviceType: typeID,
                    role: roleID,
                    site: siteId,
                    status: status
                )
            )
            onDismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }
}
#endif
