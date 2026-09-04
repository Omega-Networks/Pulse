//
//  AddSiteWindow.swift
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
/// Create a NetBox site. Only fields the POST sends. NetBox is the
/// source of truth — a failed write leaves no local row.
struct AddSiteWindow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.netBoxSyncEngine) private var netBoxSyncEngine
    @Environment(SharedLocations.self) private var sharedLocations

    @Query(sort: \Region.name) private var regions: [Region]
    @Query(sort: \SiteGroup.name) private var siteGroups: [SiteGroup]
    @Query(sort: \Tenant.name) private var tenants: [Tenant]

    @State private var name = ""
    @State private var status = "active"
    @State private var regionID: Int64?
    @State private var groupID: Int64?
    @State private var tenantID: Int64?
    @State private var isWriting = false
    @State private var writeError: String?

    private var slug: String {
        NetBoxWriteBody.SiteCreate.slug(from: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New site")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                TextField("Name", text: $name)
                Text("Slug: \(slug.isEmpty ? "—" : slug)")
                    .foregroundStyle(.secondary)
                Picker("Status", selection: $status) {
                    Text("Active").tag("active")
                    Text("Planned").tag("planned")
                }
                Picker("Region", selection: $regionID) {
                    Text("—").tag(Optional<Int64>.none)
                    ForEach(regions) { region in
                        Text(region.name).tag(Optional(region.id))
                    }
                }
                Picker("Group", selection: $groupID) {
                    Text("—").tag(Optional<Int64>.none)
                    ForEach(siteGroups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                Picker("Tenant", selection: $tenantID) {
                    Text("—").tag(Optional<Int64>.none)
                    ForEach(tenants) { tenant in
                        Text(tenant.name).tag(Optional(tenant.id))
                    }
                }
                if let coordinate = sharedLocations.tapLocation {
                    LabeledContent("Map pin") {
                        Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                            .textSelection(.enabled)
                    }
                }
                if let address = sharedLocations.tapAddress, !address.isEmpty {
                    LabeledContent("Address") {
                        Text(address)
                            .textSelection(.enabled)
                    }
                }
            }

            if let writeError {
                Text(writeError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isWriting ? "Creating…" : "Create") {
                    Task { await create() }
                }
                .disabled(isWriting || slug.isEmpty || netBoxSyncEngine == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear {
            if regionID == nil, let address = sharedLocations.tapAddress {
                regionID = NetBoxGeo.suggestedRegionID(
                    regions: regions.map { ($0.id, $0.name) },
                    address: address
                )
            }
        }
    }

    private func create() async {
        guard let engine = netBoxSyncEngine else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !slug.isEmpty else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            try await engine.createSite(
                NetBoxWriteBody.SiteCreate(
                    name: trimmed,
                    slug: slug,
                    status: status,
                    physicalAddress: sharedLocations.tapAddress.flatMap {
                        $0.isEmpty ? nil : NetBoxGeo.physicalAddress($0)
                    },
                    latitude: sharedLocations.tapLocation.map { NetBoxGeo.latitude($0.latitude) },
                    longitude: sharedLocations.tapLocation.map { NetBoxGeo.longitude($0.longitude) },
                    region: regionID,
                    group: groupID,
                    tenant: tenantID
                )
            )
            dismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }
}
#endif
