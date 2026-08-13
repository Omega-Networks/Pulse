//
//  InterfacePopover.swift
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

struct InterfacePopover: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.netBoxSyncEngine) private var netBoxSyncEngine
    @State var interface: InterfaceVO
    @State private var isWriting = false
    @State private var writeError: String?
    @State private var connectFrom: InterfaceVO?
    @State private var siteCandidates: [InterfaceVO] = []
    @State private var confirmDisconnect = false
    private var squareSize: CGFloat = 15
    private var verticalPadding: CGFloat = 5
    
    public init(interface: InterfaceVO) {
        self._interface = State(initialValue: interface)
    }
    
    var body: some View {
        VStack {
            Form {
                HStack {
                    Text("Interface")
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    Label {
                        Text(interface.name)
                    } icon: {
                        Image(systemName: "square")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: squareSize, height: squareSize)
                            .foregroundColor(interface.enabled ? .green : .red)
                        
                    }
                }
                .padding(.vertical, verticalPadding)
            
                HStack {
                    Text("Port Speed")
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    Text(interface.speedLabel)
                }
                .padding(.vertical, verticalPadding)

                HStack {
                    Text("Enabled")
                        .foregroundColor(.gray)
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { interface.enabled },
                            set: { newValue in
                                Task { await setEnabled(newValue) }
                            }
                        )
                    )
                    .labelsHidden()
                    .disabled(isWriting || netBoxSyncEngine == nil)
                }
                .padding(.vertical, verticalPadding)
                
                HStack {
                    Text("Connected Endpoint")
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    Text(interface.connectedEndpointName ?? "—")
                }
                .padding(.vertical, verticalPadding)

                HStack {
                    Spacer()
                    if interface.cableId != nil || interface.connectedEndpointId != nil {
                        Button("Disconnect") {
                            requestDisconnect()
                        }
                        .disabled(isWriting || netBoxSyncEngine == nil)
                    } else {
                        Button("Connect…") {
                            beginConnect()
                        }
                        .disabled(isWriting || netBoxSyncEngine == nil)
                    }
                }
                .padding(.vertical, verticalPadding)
                
                HStack {
                    Text("Type")
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    Text(interface.type ?? interface.name)
                }
                .padding(.vertical, verticalPadding)
            }
        }
        .padding(20)
        .frame(width: 400, height: 280)
        .onReceive(NotificationCenter.default.publisher(for: .netBoxStoreDidApply)) { _ in
            reload()
        }
        .sheet(item: $connectFrom) { source in
            ConnectInterfaceSheet(
                source: source,
                candidates: siteCandidates.filter {
                    $0.id != source.id && $0.cableId == nil && $0.connectedEndpointId == nil
                },
                onCancel: { connectFrom = nil },
                onConnect: { target in
                    Task { await connect(to: target) }
                }
            )
        }
        .alert("NetBox write failed", isPresented: Binding(
            get: { writeError != nil },
            set: { if !$0 { writeError = nil } }
        )) {
            Button("OK", role: .cancel) { writeError = nil }
        } message: {
            Text(writeError ?? "")
        }
        .alert("Disconnect cable?", isPresented: $confirmDisconnect) {
            Button("Cancel", role: .cancel) { confirmDisconnect = false }
            Button("Disconnect", role: .destructive) {
                Task { await disconnect() }
            }
        } message: {
            Text("This deletes the cable in NetBox between \(interface.name) and \(interface.connectedEndpointName ?? "the other end"). That cannot be undone from here.")
        }
    }

    private func beginConnect() {
        if let siteId = interface.siteId {
            siteCandidates = (try? SiteTopologyEdges.fetchVOs(siteId: siteId, in: modelContext)) ?? []
        } else {
            siteCandidates = []
        }
        connectFrom = interface
    }

    private func setEnabled(_ enabled: Bool) async {
        guard enabled != interface.enabled else { return }
        await performWrite {
            try await engine.patchInterface(id: interface.id, enabled: enabled)
        }
    }

    private func connect(to target: InterfaceVO) async {
        connectFrom = nil
        await performWrite {
            try await engine.createCable(from: interface.id, to: target.id)
        }
    }

    private func requestDisconnect() {
        guard interface.cableId != nil || interface.connectedEndpointId != nil else {
            writeError = "This interface has no cable."
            return
        }
        confirmDisconnect = true
    }

    private func disconnect() async {
        let ends = [interface.id, interface.connectedEndpointId].compactMap { $0 }
        await performWrite {
            try await engine.disconnectInterface(
                id: interface.id,
                knownCableId: interface.cableId,
                refreshing: ends
            )
        }
    }

    private var engine: NetBoxSyncEngine {
        get throws {
            guard let netBoxSyncEngine else {
                throw NetBoxSyncError.writesDisabled("NetBox sync engine is not available")
            }
            return netBoxSyncEngine
        }
    }

    private func performWrite(_ work: () async throws -> Void) async {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            try await work()
            reload()
        } catch {
            writeError = error.localizedDescription
            reload()
        }
    }

    private func reload() {
        let id = interface.id
        if let deviceId = interface.deviceId,
           let fresh = try? SiteTopologyEdges.fetchVOs(deviceId: deviceId, in: modelContext)
            .first(where: { $0.id == id }) {
            interface = fresh
            return
        }
        if let siteId = interface.siteId,
           let fresh = try? SiteTopologyEdges.fetchVOs(siteId: siteId, in: modelContext)
            .first(where: { $0.id == id }) {
            interface = fresh
        }
    }
}

//#Preview {
//    InterfacePopover(interfaceId: 0)
//}
