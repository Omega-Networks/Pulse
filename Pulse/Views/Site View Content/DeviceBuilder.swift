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
    var prefill: DeviceGhost? = nil
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
    @State private var status: String? = "active"
    @State private var tenantID: Int64?
    @State private var face: String? = "front"
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
                ChoiceField(
                    title: "Role",
                    prompt: "Search roles",
                    selection: $roleID,
                    options: .list(roles.map { ($0.id, $0.name ?? "role \($0.id)") })
                )
                ChoiceField(
                    title: "Type",
                    prompt: "Search types",
                    selection: $typeID,
                    options: .list(deviceTypes.map { ($0.id, $0.model ?? "type \($0.id)") })
                )
                ChoiceField(
                    title: "Status",
                    prompt: "Select",
                    selection: $status,
                    options: .list([("active", "Active"), ("planned", "Planned"), ("offline", "Offline")])
                )
                ChoiceField(
                    title: "Tenant",
                    prompt: "None",
                    selection: $tenantID,
                    options: .list(tenants.map { ($0.id, $0.name) })
                )
                if mount != nil {
                    ChoiceField(title: "Face", prompt: "Select", selection: $face, options: .faces)
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
                    guard !isWriting else { return }
                    isWriting = true
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
            if let prefill {
                name = prefill.name
                roleID = prefill.roleID
                typeID = prefill.typeID
                status = prefill.status ?? "active"
                tenantID = prefill.tenantID
                if let face = prefill.face {
                    self.face = face
                }
            } else {
                if tenantID == nil {
                    tenantID = defaultTenantID
                }
                if let mount {
                    face = mount.face
                }
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
            && name.nonBlank != nil
            && roleID != nil
            && typeID != nil
            && status != nil
            && (mount == nil || face != nil)
    }

    private func uHeight(for typeID: Int64) -> Float {
        let raw = deviceTypes.first { $0.id == typeID }?.uHeight ?? 1
        return raw < 0.5 ? 0.5 : raw
    }

    private func create() async {
        defer { isWriting = false }
        guard let engine = netBoxSyncEngine, let roleID, let typeID, let status,
              let trimmed = name.nonBlank else { return }
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
        let intent = DeviceCreateIntent(
            body: NetBoxWriteBody.DeviceCreate(
                name: trimmed,
                deviceType: typeID,
                role: roleID,
                site: siteId,
                status: status,
                rack: mount?.rackID,
                position: mount?.position,
                face: mount == nil ? nil : face,
                tenant: tenantID
            ),
            uHeight: uHeight(for: typeID),
            roleName: roles.first { $0.id == roleID }?.name ?? "",
            typeModel: deviceTypes.first { $0.id == typeID }?.model ?? ""
        )
        _ = await engine.submit([intent])
        if let prefill {
            await engine.discard(prefill.token)
        }
        onDismiss()
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
    @State private var face: String?
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

            Form {
                ChoiceField(title: "Face", prompt: "Select", selection: $face, options: .faces)

                if candidates.isEmpty {
                    Text("No unracked devices at this site.")
                        .foregroundStyle(.secondary)
                } else {
                    ChoiceField(
                        title: "Device",
                        prompt: "Search unracked devices",
                        selection: $selectedID,
                        options: .list(candidates.map { ($0.id, $0.name ?? "device \($0.id)") })
                    )
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
                    .disabled(selectedID == nil || face == nil)
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
        guard let selectedID, let face,
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
    @State private var status: String? = "active"
    @State private var tenantID: Int64?
    @State private var locationID: Int64?
    @State private var rackRoleID: Int64?
    @State private var uHeight = 42
    @State private var startingUnit = 1
    @State private var formFactor: String? = "4-post-cabinet"
    @State private var width: Int? = 19
    @State private var descUnits = false
    @State private var mountingDepth = "500"
    @State private var outerWidth = "600"
    @State private var outerHeight = ""
    @State private var outerDepth = "600"
    @State private var outerUnit: String? = "mm"
    @State private var airflow: String? = "front-to-rear"
    @State private var serial = ""
    @State private var rackDescription = ""
    @State private var weight = ""
    @State private var maxWeight = ""
    @State private var weightUnit: String? = "kg"
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
                    ChoiceField(
                        title: "Status",
                        prompt: "Select",
                        selection: $status,
                        options: .list([
                            ("active", "Active"), ("planned", "Planned"),
                            ("reserved", "Reserved"), ("deprecated", "Deprecated"),
                        ])
                    )
                    ChoiceField(
                        title: "Tenant",
                        prompt: "None",
                        selection: $tenantID,
                        options: .list(tenants.map { ($0.id, $0.name) })
                    )
                    ChoiceField(
                        title: "Location",
                        prompt: "None",
                        selection: $locationID,
                        options: .list(siteLocations.map { ($0.id, $0.name) })
                    )
                    ChoiceField(
                        title: "Role",
                        prompt: "None",
                        selection: $rackRoleID,
                        options: .list(rackRoles.map { ($0.id, $0.name) })
                    )
                    TextField("Serial", text: $serial)
                    TextField("Description", text: $rackDescription)
                }

                Section("Elevation") {
                    TextField("Height (U)", value: $uHeight, format: .number)
                    TextField("Starting unit", value: $startingUnit, format: .number)
                    ChoiceField(
                        title: "Form factor",
                        prompt: "Select",
                        selection: $formFactor,
                        options: .list([
                            ("2-post-frame", "2-post frame"),
                            ("4-post-frame", "4-post frame"),
                            ("4-post-cabinet", "4-post cabinet"),
                            ("wall-frame", "Wall-mounted frame"),
                            ("wall-frame-vertical", "Wall-mounted frame (vertical)"),
                            ("wall-cabinet", "Wall-mounted cabinet"),
                            ("wall-cabinet-vertical", "Wall-mounted cabinet (vertical)"),
                        ])
                    )
                    ChoiceField(
                        title: "Width",
                        prompt: "Select",
                        selection: $width,
                        options: .list([(10, "10 inches"), (19, "19 inches"), (21, "21 inches"), (23, "23 inches")])
                    )
                    Toggle("Descending units", isOn: $descUnits)
                }

                Section("Physical") {
                    TextField("Mounting depth (mm)", text: $mountingDepth)
                    TextField("Outer width", text: $outerWidth)
                    TextField("Outer height", text: $outerHeight)
                    TextField("Outer depth", text: $outerDepth)
                    ChoiceField(
                        title: "Outer unit",
                        prompt: "Select",
                        selection: $outerUnit,
                        options: .list([("mm", "Millimeters"), ("in", "Inches")])
                    )
                    ChoiceField(
                        title: "Airflow",
                        prompt: "Select",
                        selection: $airflow,
                        options: .list([("front-to-rear", "Front to rear"), ("rear-to-front", "Rear to front")])
                    )
                    TextField("Weight", text: $weight)
                    TextField("Max weight", text: $maxWeight)
                    ChoiceField(
                        title: "Weight unit",
                        prompt: "Select",
                        selection: $weightUnit,
                        options: .list([("kg", "Kilograms"), ("g", "Grams"), ("lb", "Pounds"), ("oz", "Ounces")])
                    )
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
            && name.nonBlank != nil
            && uHeight >= 1
            && startingUnit >= 1
            && status != nil
            && formFactor != nil
            && width != nil
            && airflow != nil
            && (!hasOuterDimensions || outerUnit != nil)
            && (!hasWeights || weightUnit != nil)
    }

    private func create() async {
        guard let engine = netBoxSyncEngine, let status, let formFactor, let width, let airflow,
              let trimmed = name.nonBlank else { return }
        isWriting = true
        defer { isWriting = false }
        let weightValue = Double(weight.trimmed)
        let maxWeightValue = Int(maxWeight.trimmed)
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
                    mountingDepth: Int(mountingDepth.trimmed),
                    outerWidth: Int(outerWidth.trimmed),
                    outerHeight: Int(outerHeight.trimmed),
                    outerDepth: Int(outerDepth.trimmed),
                    outerUnit: hasOuterDimensions ? outerUnit : nil,
                    airflow: airflow,
                    facilityId: facilityId.nonBlank,
                    serial: serial.nonBlank,
                    description: rackDescription.nonBlank,
                    descUnits: descUnits ? true : nil,
                    tenant: tenantID,
                    location: locationID,
                    role: rackRoleID,
                    weight: weightValue,
                    maxWeight: maxWeightValue,
                    weightUnit: hasWeights ? weightUnit : nil
                )
            )
            onDismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }

    private var hasOuterDimensions: Bool {
        [outerWidth, outerHeight, outerDepth].contains { Int($0.trimmed) != nil }
    }

    private var hasWeights: Bool {
        Double(weight.trimmed) != nil || Int(maxWeight.trimmed) != nil
    }
}

/// One value a form can pick, with the name the operator reads. A name
/// that repeats carries its value, so a completion resolves to one record.
private struct ChoiceOption<Value: Hashable>: Identifiable {
    let id: Value
    let name: String
}

extension [ChoiceOption<String>] {
    fileprivate static var faces: Self { .list([("front", "Front"), ("rear", "Rear")]) }
}

extension Array {
    fileprivate static func list<Value>(_ entries: [(id: Value, name: String)]) -> Self
    where Element == ChoiceOption<Value> {
        let counts = Dictionary(entries.map { ($0.name.lowercased(), 1) }, uniquingKeysWith: +)
        return entries.map { entry in
            let repeated = counts[entry.name.lowercased(), default: 0] > 1
            return ChoiceOption(id: entry.id, name: repeated ? "\(entry.name) (\(entry.id))" : entry.name)
        }
    }
}

/// Picks one value by typing or from the list. It is a text field, so Tab
/// reaches it. The list shows every match and scrolls; macOS holds it to
/// the height of the window the field is in.
private struct ChoiceField<Value: Hashable>: View {
    let title: String
    let prompt: String
    @Binding var selection: Value?
    let options: [ChoiceOption<Value>]

    @State private var text = ""

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .textInputSuggestions {
                ForEach(suggestions) { option in
                    Text(option.name)
                        .textInputCompletion(option.name)
                }
            }
            .onChange(of: text) {
                selection = option(named: text)?.id
            }
            .onChange(of: selection, initial: true) {
                guard let selected = options.first(where: { $0.id == selection }),
                      option(named: text)?.id != selected.id else { return }
                text = selected.name
            }
    }

    /// Every option while the field is empty or holds a complete choice,
    /// so the list works as a menu. Otherwise the options that match.
    private var suggestions: [ChoiceOption<Value>] {
        guard let query = text.nonBlank, option(named: query) == nil else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func option(named name: String) -> ChoiceOption<Value>? {
        options.first { $0.name.equalsIgnoringCase(name.trimmed) }
    }
}
#endif
