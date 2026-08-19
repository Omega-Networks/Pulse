//
//  DeviceDetailsPanel.swift
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
import AVKit

struct DeviceDetailsPanelView: View {
    @Environment(\.netBoxSyncEngine) private var netBoxSyncEngine
    @Environment(RackEditSession.self) private var rackEdit
    @Environment(LicenseSeatStore.self) private var seats
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(RolePresentationStore.self) private var rolePresentation
    @State var site: Site
    @Binding var selectedDevice: Device?
    @Binding var enableGestures: Bool

    @State private var showingCameraConfigSheet = false
    #if os(macOS)
    @State private var showingNewRackSheet = false
    #endif
    @State private var selectedTab = "Device Details"
    @State private var editAlert: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            ScrollView(.vertical, showsIndicators: true) {
                if let device = selectedDevice {
                    deviceInfoSection(device)

                } else {
                    Text("Select a device to view details")
                        .padding(.vertical, 10)
                }
            }
            .tabItem {
                Label("Device Details", systemImage: "info.circle")
            }
            .tag("Device Details")

            VStack(alignment: .leading, spacing: 8) {
                racksHeader
                RackView(site: site)
            }
            .padding(12)
            .tabItem {
                Label("Rack View", systemImage: "square.stack.3d.up")
            }
            .tag("Rack View")
        }
        #if os(macOS)
        .tabViewStyle(.grouped)
        #endif
        .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedTab, initial: true) { _, tab in
            setRackSurfaceOpen(tab == "Rack View")
        }
        .onDisappear { setRackSurfaceOpen(false) }
        .alert("Rack edit", isPresented: Binding(
            get: { editAlert != nil },
            set: { if !$0 { editAlert = nil } }
        )) {
            Button("OK", role: .cancel) { editAlert = nil }
        } message: {
            Text(editAlert ?? "")
        }
        #if os(macOS)
        .sheet(isPresented: $showingNewRackSheet) {
            NewRackSheet(siteId: site.id, onDismiss: { showingNewRackSheet = false })
                .environment(\.netBoxSyncEngine, netBoxSyncEngine)
        }
        .sheet(isPresented: Binding(
            get: { rackEdit.addTarget != nil },
            set: { if !$0 {
                rackEdit.addTarget = nil
                rackEdit.addCreatesDevice = false
            } }
        )) {
            if let target = rackEdit.addTarget {
                if rackEdit.addCreatesDevice {
                    NewDeviceSheet(
                        siteId: site.id,
                        mount: target,
                        defaultTenantID: site.tenant?.id,
                        onDismiss: {
                            rackEdit.addTarget = nil
                            rackEdit.addCreatesDevice = false
                        }
                    )
                    .environment(\.netBoxSyncEngine, netBoxSyncEngine)
                    .environment(entitlements)
                    .environment(seats)
                    .environment(rolePresentation)
                } else {
                    AddToRackSheet(
                        site: site,
                        target: target,
                        onDismiss: {
                            rackEdit.addTarget = nil
                            rackEdit.addCreatesDevice = false
                        },
                        onCreateNew: { rackEdit.addCreatesDevice = true }
                    )
                    .environment(\.netBoxSyncEngine, netBoxSyncEngine)
                    .environment(seats)
                    .environment(rolePresentation)
                }
            }
        }
        #endif
    }

    private var racksHeader: some View {
        HStack(spacing: 8) {
            Text("Racks")
                .font(.headline)

            if rackEdit.isEditing {
                Button("Undo") { rackEdit.undo() }
                    .disabled(!rackEdit.draft.canUndo || rackEdit.isSaving)
                Button("Cancel") { rackEdit.cancel() }
                    .disabled(rackEdit.isSaving)
                Button("Save") {
                    Task { await saveRackDraft() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!rackEdit.draft.isDirty || rackEdit.isSaving)
            }

            if let message = rackEdit.status {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                if rackEdit.isEditing {
                    rackEdit.cancel()
                } else {
                    if enableGestures {
                        enableGestures = false
                    }
                    rackEdit.begin()
                }
            } label: {
                Image(systemName: rackEdit.isEditing ? "pencil.circle.fill" : "pencil")
            }
            .buttonStyle(.plain)
            .help(rackEdit.isEditing ? "Leave rack edit mode" : "Edit racks: drag devices onto a U, between racks, or out to unrack")

            #if os(macOS)
            Button {
                showingNewRackSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New rack in NetBox")
            #endif
        }
    }

    private func setRackSurfaceOpen(_ open: Bool) {
        rackEdit.isOpen = open
        if open, enableGestures {
            enableGestures = false
        }
    }

    @MainActor
    private func saveRackDraft() async {
        guard let engine = netBoxSyncEngine else {
            editAlert = "NetBox sync engine is not available."
            return
        }
        rackEdit.isSaving = true
        defer { rackEdit.isSaving = false }
        let placements = rackEdit.draft.placements.values.sorted { $0.deviceID < $1.deviceID }
        let presentation = rolePresentation.presentation
        if let blocked = placements.first(where: { placement in
            let roleID = site.devices?.first(where: { $0.id == placement.deviceID })?.deviceRole?.id
            return !seats.allowsRackEdit(
                deviceID: placement.deviceID,
                roleID: roleID,
                presentation: presentation
            )
        }) {
            editAlert = BillingError.deviceNotSeated.localizedDescription
            rackEdit.status = "Subscribe to resume. Device \(blocked.deviceID) is not seated."
            return
        }
        for placement in placements {
            do {
                if placement.rackID == RackOccupancy.unrackedID {
                    try await engine.patchDevice(
                        id: placement.deviceID,
                        body: NetBoxWriteBody.DevicePatch(clearRack: true)
                    )
                } else {
                    try await engine.patchDevice(
                        id: placement.deviceID,
                        body: NetBoxWriteBody.DevicePatch(
                            rack: placement.rackID,
                            position: placement.position,
                            face: placement.face
                        )
                    )
                }
            } catch {
                editAlert = error.localizedDescription
                rackEdit.status = "Save stopped. Remaining moves were not sent."
                return
            }
        }
        rackEdit.draft.reset()
        rackEdit.status = "Saved \(placements.count) placement(s)."
    }
    
    // MARK: - Helper Views
    
    private func deviceInfoSection(_ device: Device) -> some View {
        VStack(alignment: .leading) {
            
            HStack(alignment: .center) {
                Text("\(device.name ?? "Error")")
                    .font(.title)
                    .fontWeight(.bold)
                
                Spacer()
                
                if device.supportsCameraStream {
                    Button {
                        showingCameraConfigSheet = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.borderless)
                    .font(.headline)
                    .help("Configure Camera Stream URL")
                }
            }
            .padding(.top, 20) // Apply padding to the entire HStack
            
            DeviceUptimeChart(deviceId: device.zabbixId)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .padding(.top, -15)
            
            DeviceFaceplate(deviceId: device.id)
                .padding(.vertical, 40)
            
            switch device.deviceRole?.id {
            case 3: // Security Router
                HStack(alignment: .top) {
                    VStack {
                        ItemChart(deviceId: device.zabbixId, item: "CPU usage")
                        CPUCoresChart(deviceId: device.zabbixId)
                    }
                    
                    ItemChart(deviceId: device.zabbixId, item: "Memory usage")
                }
                .padding(.vertical, 10)
                                
            default:
                Spacer()
            }
            
            #if os(macOS)
            TabView {
                InterfacesTable(device: device)
                    .id(device.id)
                    .tabItem {
                        Label("Interfaces", systemImage: "network")
                    }
                                                
                DeviceChartSelector(deviceId: device.id)
                    .padding()
                    .tabItem {
                        Label("Graphs", systemImage: "chart.line.uptrend.xyaxis")
                    }
            }
            .padding(.top, 10)
            .frame(minHeight: 400, alignment: .top)
            #endif
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
    
    private func cpuMemorySection(_ device: Device) -> some View {
        HStack(alignment: .top) {
            VStack {
                ItemChart(deviceId: device.zabbixId, item: "CPU usage")
                CPUCoresChart(deviceId: device.zabbixId)
            }
            .frame(maxWidth: .infinity)
            
            VStack {
                ItemChart(deviceId: device.zabbixId, item: "Memory usage")
            }
            .frame(maxWidth: .infinity)
        }
    }
}


//#Preview("Device Details Panel View") {
//    @Previewable @Query(filter: #Predicate<Site> { $0.id == 1 }) var sites: [Site]
//    @Previewable @Query(filter: #Predicate<Device> { $0.id == 1 }) var devices: [Device]
//    
//    DeviceDetailsPanelView(
//        site: sites.first ?? Site(id: 1),
//        selectedDevice: .constant(devices.first)
//    )
//    .frame(width: 600, height: 400)
//}
