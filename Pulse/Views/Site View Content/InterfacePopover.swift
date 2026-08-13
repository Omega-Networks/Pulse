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
    @State private var operatorAlert: OperatorAlert?
    @State private var connectFrom: InterfaceVO?
    @State private var siteCandidates: [InterfaceVO] = []
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
                candidates: siteCandidates.filter { $0.id != source.id },
                onCancel: { connectFrom = nil },
                onConnect: { target in
                    Task { await connect(to: target) }
                }
            )
        }
        .alert(item: $operatorAlert) { alert in
            switch alert {
            case .failed(let message):
                return Alert(
                    title: Text("NetBox write failed"),
                    message: Text(message),
                    dismissButton: .cancel(Text("OK"))
                )
            case .confirmDisconnect(let target):
                return Alert(
                    title: Text("Disconnect cable?"),
                    message: Text("This deletes the cable in NetBox between \(target.name) and \(target.connectedEndpointName ?? "the other end"). That cannot be undone from here."),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Disconnect")) {
                        Task {
                            await Task.yield()
                            await disconnect()
                        }
                    }
                )
            }
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
            operatorAlert = .failed("This interface has no cable.")
            return
        }
        operatorAlert = .confirmDisconnect(interface)
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
            operatorAlert = .failed(error.localizedDescription)
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
