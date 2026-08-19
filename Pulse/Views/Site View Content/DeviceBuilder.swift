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
    var mount: RackMountTarget? = nil
    var defaultTenantID: Int64? = nil
    var onDismiss: () -> Void

    @Environment(\.netBoxSyncEngine) private var netBoxSyncEngine
    @Environment(\.modelContext) private var modelContext
    @Environment(RolePresentationStore.self) private var rolePresentation
    @Environment(LicenseSeatStore.self) private var seats
    @Environment(EntitlementStore.self) private var entitlements
    @Query(sort: \DeviceRole.name) private var roles: [DeviceRole]
    @Query(sort: \DeviceType.model) private var deviceTypes: [DeviceType]
    @Query(sort: \Tenant.name) private var tenants: [Tenant]

    @State private var name = ""
    @State private var roleID: Int64?
    @State private var typeID: Int64?
    @State private var status = "active"
    @State private var tenantID: Int64?
    @State private var face = "front"
    @State private var isWriting = false
    @State private var writeError: String?
    @State private var showingPaywall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(newDeviceTitle)
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
                Picker("Tenant", selection: $tenantID) {
                    Text("None").tag(Optional<Int64>.none)
                    ForEach(tenants) { tenant in
                        Text(tenant.name).tag(Optional(tenant.id))
                    }
                }
                if mount != nil {
                    Picker("Face", selection: $face) {
                        Text("Front").tag("front")
                        Text("Rear").tag("rear")
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
        .modifier(SubscriptionPaywallSheet(isPresented: $showingPaywall))
        .onAppear {
            if tenantID == nil {
                tenantID = defaultTenantID
            }
            if let mount {
                face = mount.face
            }
        }
    }

    private var newDeviceTitle: String {
        if let mount {
            return "New device at U \(RackEditActions.formatU(mount.position))"
        }
        return "New device"
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
        if rolePresentation.presentation.countsTowardLicense(roleID: roleID) {
            let allowed = (try? seats.canAdmitEligible(
                additional: 1,
                in: modelContext,
                presentation: rolePresentation.presentation,
                tier: entitlements.tier
            )) ?? false
            if !allowed {
                writeError = entitlements.tier.capReachedMessage()
                showingPaywall = true
                return
            }
        }
        isWriting = true
        defer { isWriting = false }
        do {
            try await engine.createDevice(
                NetBoxWriteBody.DeviceCreate(
                    name: trimmed,
                    deviceType: typeID,
                    role: roleID,
                    site: siteId,
                    status: status,
                    rack: mount?.rackID,
                    position: mount?.position,
                    face: mount == nil ? nil : face,
                    tenant: tenantID
                )
            )
            onDismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }
}

struct AddToRackSheet: View {
    let site: Site
    let target: RackMountTarget
    var onDismiss: () -> Void

    @Environment(RackEditSession.self) private var rackEdit
    @Environment(RolePresentationStore.self) private var rolePresentation
    @Environment(LicenseSeatStore.self) private var seats
    var onCreateNew: () -> Void
    @State private var selectedID: Int64?
    @State private var face: String
    @State private var placeError: String?

    init(
        site: Site,
        target: RackMountTarget,
        onDismiss: @escaping () -> Void,
        onCreateNew: @escaping () -> Void
    ) {
        self.site = site
        self.target = target
        self.onDismiss = onDismiss
        self.onCreateNew = onCreateNew
        _face = State(initialValue: target.face)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add at U \(RackEditActions.formatU(target.position))")
                .font(.title2)
                .fontWeight(.bold)

            Picker("Face", selection: $face) {
                Text("Front").tag("front")
                Text("Rear").tag("rear")
            }

            if candidates.isEmpty {
                Text("No unracked devices at this site.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: $selectedID) {
                    Text("Select…").tag(Optional<Int64>.none)
                    ForEach(candidates, id: \.id) { device in
                        Text(device.name ?? "device \(device.id)").tag(Optional(device.id))
                    }
                }
            }

            if let placeError {
                Text(placeError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Create new…", action: onCreateNew)
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Place") { placeExisting() }
                    .disabled(selectedID == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 220)
    }

    private var candidates: [Device] {
        let presentation = rolePresentation.presentation
        return (site.devices ?? []).filter { device in
            let current = rackEdit.draft.placements[device.id]?.rackID
                ?? device.rack?.id
                ?? RackOccupancy.unrackedID
            guard current == RackOccupancy.unrackedID else { return false }
            guard seats.allowsRackEdit(
                deviceID: device.id,
                roleID: device.deviceRole?.id,
                presentation: presentation
            ) else { return false }
            return presentation.policy(for: device.deviceRole?.id).showInRack
        }
        .sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    private func placeExisting() {
        guard let selectedID,
              let device = site.devices?.first(where: { $0.id == selectedID }),
              let rack = site.racks?.first(where: { $0.id == target.rackID }) else {
            return
        }
        let placed = RackEditActions.place(
            device: device,
            on: rack,
            at: target.position,
            site: site,
            session: rackEdit,
            seats: seats,
            presentation: rolePresentation.presentation,
            face: face
        )
        if placed {
            onDismiss()
        } else {
            placeError = rackEdit.status
        }
    }
}

struct NewRackSheet: View {
    let siteId: Int64
    var onDismiss: () -> Void

    @Environment(\.netBoxSyncEngine) private var netBoxSyncEngine
    @Query(sort: \Tenant.name) private var tenants: [Tenant]
    @Query(sort: \SiteLocation.name) private var locations: [SiteLocation]
    @Query(sort: \RackRole.name) private var rackRoles: [RackRole]

    @State private var name = ""
    @State private var facilityId = ""
    @State private var status = "active"
    @State private var tenantID: Int64?
    @State private var locationID: Int64?
    @State private var rackRoleID: Int64?
    @State private var uHeight = 42
    @State private var startingUnit = 1
    @State private var formFactor = "4-post-cabinet"
    @State private var width = 19
    @State private var descUnits = false
    @State private var mountingDepth = "500"
    @State private var outerWidth = "600"
    @State private var outerHeight = ""
    @State private var outerDepth = "600"
    @State private var outerUnit = "mm"
    @State private var airflow = "front-to-rear"
    @State private var serial = ""
    @State private var rackDescription = ""
    @State private var weight = ""
    @State private var maxWeight = ""
    @State private var weightUnit = "kg"
    @State private var isWriting = false
    @State private var writeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New rack")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Facility ID", text: $facilityId)
                    Picker("Status", selection: $status) {
                        Text("Active").tag("active")
                        Text("Planned").tag("planned")
                        Text("Reserved").tag("reserved")
                        Text("Deprecated").tag("deprecated")
                    }
                    Picker("Tenant", selection: $tenantID) {
                        Text("None").tag(Optional<Int64>.none)
                        ForEach(tenants) { tenant in
                            Text(tenant.name).tag(Optional(tenant.id))
                        }
                    }
                    Picker("Location", selection: $locationID) {
                        Text("None").tag(Optional<Int64>.none)
                        ForEach(siteLocations) { location in
                            Text(location.name).tag(Optional(location.id))
                        }
                    }
                    Picker("Role", selection: $rackRoleID) {
                        Text("None").tag(Optional<Int64>.none)
                        ForEach(rackRoles) { role in
                            Text(role.name).tag(Optional(role.id))
                        }
                    }
                    TextField("Serial", text: $serial)
                    TextField("Description", text: $rackDescription)
                }

                Section("Elevation") {
                    TextField("Height (U)", value: $uHeight, format: .number)
                    TextField("Starting unit", value: $startingUnit, format: .number)
                    Picker("Form factor", selection: $formFactor) {
                        Text("2-post frame").tag("2-post-frame")
                        Text("4-post frame").tag("4-post-frame")
                        Text("4-post cabinet").tag("4-post-cabinet")
                        Text("Wall-mounted frame").tag("wall-frame")
                        Text("Wall-mounted frame (vertical)").tag("wall-frame-vertical")
                        Text("Wall-mounted cabinet").tag("wall-cabinet")
                        Text("Wall-mounted cabinet (vertical)").tag("wall-cabinet-vertical")
                    }
                    Picker("Width", selection: $width) {
                        Text("10 inches").tag(10)
                        Text("19 inches").tag(19)
                        Text("21 inches").tag(21)
                        Text("23 inches").tag(23)
                    }
                    Toggle("Descending units", isOn: $descUnits)
                }

                Section("Physical") {
                    TextField("Mounting depth (mm)", text: $mountingDepth)
                    TextField("Outer width", text: $outerWidth)
                    TextField("Outer height", text: $outerHeight)
                    TextField("Outer depth", text: $outerDepth)
                    Picker("Outer unit", selection: $outerUnit) {
                        Text("Millimeters").tag("mm")
                        Text("Inches").tag("in")
                    }
                    Picker("Airflow", selection: $airflow) {
                        Text("Front to rear").tag("front-to-rear")
                        Text("Rear to front").tag("rear-to-front")
                    }
                    TextField("Weight", text: $weight)
                    TextField("Max weight", text: $maxWeight)
                    Picker("Weight unit", selection: $weightUnit) {
                        Text("Kilograms").tag("kg")
                        Text("Grams").tag("g")
                        Text("Pounds").tag("lb")
                        Text("Ounces").tag("oz")
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
        .frame(minWidth: 560, minHeight: 560)
    }

    private var siteLocations: [SiteLocation] {
        locations.filter { $0.siteId == siteId || $0.siteId == 0 }
    }

    private var canCreate: Bool {
        !isWriting
            && netBoxSyncEngine != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && uHeight >= 1
            && startingUnit >= 1
    }

    private func create() async {
        guard let engine = netBoxSyncEngine else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            try await engine.createRack(
                NetBoxWriteBody.RackCreate(
                    name: trimmed,
                    site: siteId,
                    status: status,
                    uHeight: Int64(uHeight),
                    startingUnit: Int64(startingUnit),
                    formFactor: formFactor,
                    width: width,
                    mountingDepth: intValue(mountingDepth),
                    outerWidth: intValue(outerWidth),
                    outerHeight: intValue(outerHeight),
                    outerDepth: intValue(outerDepth),
                    outerUnit: hasOuterDimensions ? outerUnit : nil,
                    airflow: airflow,
                    facilityId: optionalText(facilityId),
                    serial: optionalText(serial),
                    description: optionalText(rackDescription),
                    descUnits: descUnits ? true : nil,
                    tenant: tenantID,
                    location: locationID,
                    role: rackRoleID,
                    weight: doubleValue(weight),
                    maxWeight: intValue(maxWeight),
                    weightUnit: (doubleValue(weight) != nil || intValue(maxWeight) != nil) ? weightUnit : nil
                )
            )
            onDismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }

    private var hasOuterDimensions: Bool {
        intValue(outerWidth) != nil || intValue(outerHeight) != nil || intValue(outerDepth) != nil
    }

    private func optionalText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func intValue(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func doubleValue(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
#endif
