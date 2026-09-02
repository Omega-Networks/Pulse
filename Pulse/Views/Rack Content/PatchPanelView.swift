//
//  PatchPanelView.swift
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
import Foundation

struct PatchPanelView: View {
    let device: Device
    let unitHeight: CGFloat
    let rackWidth: CGFloat
    @Environment(\.modelContext) private var modelContext
    @State private var ports: [FrontPort] = []
    @State private var selectedPort: FrontPort?

    private let portsPerRow: Int64 = 24
    private let portsPerGroup: Int64 = 6
    private let groupSpacing: CGFloat = 6
    private let portSpacing: CGFloat = 1

    /// Fillers are drawn at 19 in panel width, including the 0.625 in
    /// mounting ears. Jacks live in the 17.75 in chassis between them.
    private var earInset: CGFloat {
        rackWidth * EIA310.earInches / EIA310.panelWidthInches
    }

    private var chassisWidth: CGFloat {
        max(0, rackWidth - 2 * earInset)
    }

    private var portCellWidth: CGFloat {
        let groups = CGFloat(groupsPerRow)
        let groupGaps = max(0, groups - 1) * groupSpacing
        let intra = groups * CGFloat(portsPerGroup - 1) * portSpacing
        let available = chassisWidth - groupGaps - intra
        return max(6, available / CGFloat(portsPerRow))
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: earInset)

            VStack(alignment: .center, spacing: 1) {
                ForEach(0..<Int(rowCount), id: \.self) { rowIndex in
                    HStack(spacing: 0) {
                        ForEach(0..<Int(groupsPerRow), id: \.self) { groupIndex in
                            HStack(spacing: portSpacing) {
                                ForEach(portOrdinals(row: Int64(rowIndex), group: Int64(groupIndex)), id: \.self) { ordinal in
                                    portCell(ordinal: ordinal)
                                }
                            }
                            if groupIndex < Int(groupsPerRow) - 1 {
                                Spacer().frame(width: groupSpacing)
                            }
                        }
                    }
                }
            }
            .frame(width: chassisWidth)

            Color.clear
                .frame(width: earInset)
        }
        .frame(width: rackWidth, height: unitHeight)
        .background(Color.gray.opacity(0.2))
        .overlay(
            RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                .stroke(Color.gray, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: rackUnitCornerRadius))
        .task(id: device.id) { reloadPorts() }
        .onChange(of: selectedPort?.cableId) { reloadPorts() }
    }

    private func portOrdinals(row: Int64, group: Int64) -> [Int64] {
        let count = portsInGroup(row: row, group: group)
        let start = row * portsPerRow + group * portsPerGroup
        return (0..<count).map { start + $0 }
    }

    @ViewBuilder
    private func portCell(ordinal: Int64) -> some View {
        if ordinal < ports.count {
            let port = ports[Int(ordinal)]
            PortView(label: portLabel(port, ordinal: ordinal), occupied: port.isCabled, cellWidth: portCellWidth)
                .onTapGesture { selectedPort = port }
                #if os(macOS)
                .popover(
                    isPresented: Binding(
                        get: { selectedPort?.id == port.id },
                        set: { if !$0 { selectedPort = nil } }
                    ),
                    arrowEdge: .bottom
                ) {
                    FrontPortConnectSheet(port: port, siteId: device.resolvedSiteId) {
                        selectedPort = nil
                        reloadPorts()
                    }
                }
                #endif
        } else {
            PortView(label: "\(ordinal + 1)", occupied: false, cellWidth: portCellWidth)
        }
    }

    private func portLabel(_ port: FrontPort, ordinal: Int64) -> String {
        PortNameOrder.faceplateLabel(port.name, fallback: ordinal + 1)
    }

    private var portCount: Int64 {
        max(device.frontPortCount, Int64(ports.count))
    }

    private var rowCount: Int64 {
        max(1, (portCount + portsPerRow - 1) / portsPerRow)
    }

    private var groupsPerRow: Int64 {
        portsPerRow / portsPerGroup
    }

    private func portsInGroup(row: Int64, group: Int64) -> Int64 {
        let startPort = row * portsPerRow + group * portsPerGroup
        let remainingPorts = portCount - startPort
        return min(portsPerGroup, remainingPorts)
    }

    private func reloadPorts() {
        let deviceId = device.id
        let descriptor = FetchDescriptor<FrontPort>(
            predicate: #Predicate<FrontPort> { $0.deviceId == deviceId }
        )
        ports = ((try? modelContext.fetch(descriptor)) ?? []).sorted { lhs, rhs in
            PortNameOrder.lessThan(lhs.name, id: lhs.id, rhs.name, id: rhs.id)
        }
    }
}

struct PortView: View {
    let label: String
    var occupied: Bool = false
    var cellWidth: CGFloat = 10

    private var jackSize: CGFloat { min(8, max(5, cellWidth - 2)) }

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: min(6, cellWidth * 0.55), weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: cellWidth)
            ZStack {
                Rectangle()
                    .fill(occupied ? Color.green.opacity(0.7) : Color(red: 99/255, green: 99/255, blue: 99/255))
                Rectangle()
                    .stroke(Color.black, lineWidth: 0.5)
            }
            .frame(width: jackSize, height: jackSize)
        }
        .frame(width: cellWidth)
    }
}

#if os(macOS)
struct FrontPortConnectSheet: View {
    let port: FrontPort
    let siteId: Int64
    var onDone: () -> Void

    @Environment(\.netBoxSyncEngine) private var netBoxSyncEngine
    @Environment(\.modelContext) private var modelContext
    @Environment(LicenseSeatStore.self) private var seats
    @State private var targetKind = TargetKind.interface
    @State private var targetID: Int64?
    @State private var writeError: String?
    @State private var isWriting = false
    @State private var confirmDisconnect = false

    enum TargetKind: String {
        case interface
        case frontPort
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(port.name)
                .font(.headline)
            if let peer = port.connectedEndpointName {
                Text("Cabled to \(peer)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if port.isCabled {
                Button("Disconnect", role: .destructive) {
                    confirmDisconnect = true
                }
                .disabled(isWriting || !owningDeviceSeated)
            } else {
                Picker("To", selection: $targetKind) {
                    Text("Interface").tag(TargetKind.interface)
                    Text("Front port").tag(TargetKind.frontPort)
                }
                .pickerStyle(.segmented)
                Picker("Target", selection: $targetID) {
                    Text("Select…").tag(Optional<Int64>.none)
                    ForEach(targets, id: \.id) { row in
                        Text(row.label).tag(Optional(row.id))
                    }
                }
                Button(owningDeviceSeated ? "Connect" : "Subscribe to resume") {
                    Task { await connect() }
                }
                .disabled(targetID == nil || isWriting || !owningDeviceSeated)
            }

            if !owningDeviceSeated {
                SubscribeToResumeLabel()
            }

            if let writeError {
                Text(writeError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Close", action: onDone)
            }
        }
        .padding(16)
        .frame(minWidth: 320)
        .alert("Disconnect cable?", isPresented: $confirmDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                Task { await disconnect() }
            }
        } message: {
            Text("This deletes the cable in NetBox. That cannot be undone from here.")
        }
    }

    private var owningDeviceSeated: Bool {
        seats.allowsActions(deviceID: port.deviceId)
    }

    private var targets: [(id: Int64, label: String)] {
        if targetKind == .interface {
            let rows = (try? SiteTopologyEdges.fetchVOs(siteId: siteId, in: modelContext)) ?? []
            return rows
                .filter { $0.cableId == nil && $0.connectedEndpointId == nil }
                .sorted { ($0.deviceName ?? "") < ($1.deviceName ?? "") }
                .map { ($0.id, "\($0.deviceName ?? "device") \($0.name)") }
        }
        let descriptor = FetchDescriptor<FrontPort>()
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows
            .filter { $0.siteId == siteId && $0.id != port.id && !$0.isCabled }
            .sorted { PortNameOrder.lessThan($0.name, id: $0.id, $1.name, id: $1.id) }
            .map { ($0.id, "\($0.deviceName ?? "device") \($0.name)") }
    }

    private func connect() async {
        guard let engine = netBoxSyncEngine, let targetID else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            if targetKind == .interface {
                try await engine.createCable(fromFrontPort: port.id, toInterface: targetID)
            } else {
                try await engine.createCable(fromFrontPort: port.id, toFrontPort: targetID)
            }
            onDone()
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func disconnect() async {
        guard let engine = netBoxSyncEngine else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            try await engine.disconnectFrontPort(id: port.id, knownCableId: port.cableId)
            onDone()
        } catch {
            writeError = error.localizedDescription
        }
    }
}
#endif
