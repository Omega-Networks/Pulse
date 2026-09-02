//
//  InterfacesTable.swift
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

import Foundation
import SwiftUI
import SwiftData

/**
 Table of a device's interfaces. Description and enabled write through
 `NetBoxSyncEngine`; cable connect/disconnect does the same.
 */
struct InterfacesTable: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.netBoxSyncEngine) private var netBoxSyncEngine
    @Environment(LicenseSeatStore.self) private var seats
    @State var device: Device
    
    @State var selection = Set<Int64>()
    @State private var interfaces: [InterfaceVO] = []
    @State private var isWriting = false
    @State private var writingIDs: Set<Int64> = []
    @State private var operatorAlert: OperatorAlert?
    @State private var connectFrom: InterfaceVO?
    
    @State var sortOrder: [KeyPathComparator<InterfaceVO>] = [
        KeyPathComparator(\.name, comparator: .localizedStandard)
    ]

    private var owningDeviceSeated: Bool {
        seats.allowsActions(deviceID: device.id)
    }

    private func linkAllowed(for interface: InterfaceVO) -> Bool {
        guard owningDeviceSeated else { return false }
        if let peer = interface.connectedEndpointDeviceId {
            return seats.allowsLink(a: device.id, b: peer)
        }
        return owningDeviceSeated
    }
    
    //Computed property for displaying Interfaces that do not belong in a lag, bridge or parent
    var filteredInterfaces: [InterfaceVO] {
        interfaces.filter { interface in
            // An interface should be shown in the main table if it doesn't have:
            // - a LAG parent (not a member of a Link Aggregation Group)
            // - a bridge parent (not a member of a bridge interface)
            // - a direct parent (not a sub-interface)
            
            // All IDs are optional Int64, but the properties struct initializes them to 0 if nil
            // So we check if they are either nil or 0
            let hasNoLagParent = interface.lagId == nil || interface.lagId == 0
            let hasNoBridgeParent = interface.bridgeId == nil || interface.bridgeId == 0
            let hasNoDirectParent = interface.parentId == nil || interface.parentId == 0
            
            return hasNoLagParent && hasNoBridgeParent && hasNoDirectParent
        }
        .sorted(using: sortOrder)
    }
    
    @State private var editedInterfaces: [Int64: InterfaceVO] = [:]

    var body: some View {
        tableView
        .task {
            loadInterfaces()
        }
        .onReceive(NotificationCenter.default.publisher(for: .netBoxStoreDidApply)) { _ in
            loadInterfaces()
        }
        .sheet(item: $connectFrom) { source in
            ConnectInterfaceSheet(
                source: source,
                device: device,
                onCancel: { connectFrom = nil },
                onConnect: { target in
                    Task { await connect(source, to: target) }
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
            case .confirmDisconnect(let interface):
                return Alert(
                    title: Text("Disconnect cable?"),
                    message: Text(disconnectMessage(for: interface)),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Disconnect")) {
                        Task {
                            await Task.yield()
                            await disconnect(interface)
                        }
                    }
                )
            }
        }
    }
    
    private func loadInterfaces() {
        let deviceId = device.id
        let rows = (try? SiteTopologyEdges.fetchVOs(deviceId: deviceId, in: modelContext)) ?? []
        interfaces = enrichCables(rows)
    }

    /// Cable column prefers the live interface name. If that is empty
    /// but a `Cable` row exists, resolve the other end from the store.
    private func enrichCables(_ rows: [InterfaceVO]) -> [InterfaceVO] {
        guard let siteId = SiteTopologyEdges.resolvedSiteId(
            interface: rows.first ?? InterfaceVO(id: 0),
            device: device,
            in: modelContext
        ) else { return rows }
        let siteVOs = (try? SiteTopologyEdges.fetchVOs(siteId: siteId, in: modelContext)) ?? []
        var byID: [Int64: InterfaceVO] = [:]
        for vo in siteVOs { byID[vo.id] = vo }
        let cables = (try? SiteTopologyEdges.fetchCables(siteId: siteId, in: modelContext)) ?? []
        var cableByInterface: [Int64: CableVO] = [:]
        for cable in cables {
            if let a = cable.aInterfaceId { cableByInterface[a] = cable }
            if let b = cable.bInterfaceId { cableByInterface[b] = cable }
        }
        return rows.map { row in
            var next = row
            if next.cableId == nil, let cable = cableByInterface[row.id] {
                next.cableId = cable.id
            }
            if next.connectedEndpointName == nil || next.connectedEndpointName?.isEmpty == true {
                let otherID = next.connectedEndpointId
                    ?? cableByInterface[row.id].flatMap { cable in
                        cable.aInterfaceId == row.id ? cable.bInterfaceId : cable.aInterfaceId
                    }
                if let otherID, let other = byID[otherID] {
                    next.connectedEndpointId = otherID
                    next.connectedEndpointDeviceId = other.deviceId
                    next.connectedEndpointName = cableEndLabel(other)
                }
            }
            return next
        }
    }

    private func cableEndLabel(_ vo: InterfaceVO) -> String {
        if let device = vo.deviceName, !device.isEmpty {
            return "\(device) \(vo.name)"
        }
        return vo.name
    }

    private func beginConnect(_ interface: InterfaceVO) {
        connectFrom = interface
    }

    private func saveDescription(_ interface: InterfaceVO, _ value: String) async {
        let committed = interface.interfaceDescription ?? ""
        guard value != committed else {
            editedInterfaces.removeValue(forKey: interface.id)
            return
        }
        let succeeded = await performWrite(id: interface.id, lockTable: false) {
            try await engine.patchInterface(id: interface.id, description: value)
        }
        editedInterfaces.removeValue(forKey: interface.id)
        if !succeeded {
            loadInterfaces()
        }
    }

    private func saveLabel(_ interface: InterfaceVO, _ value: String) async {
        let committed = interface.label ?? ""
        guard value != committed else {
            editedInterfaces.removeValue(forKey: interface.id)
            return
        }
        let succeeded = await performWrite(id: interface.id, lockTable: false) {
            try await engine.patchInterface(id: interface.id, label: value)
        }
        editedInterfaces.removeValue(forKey: interface.id)
        if !succeeded {
            loadInterfaces()
        }
    }

    private func setEnabled(_ interface: InterfaceVO, _ enabled: Bool) async {
        guard enabled != interface.enabled else { return }
        if let index = interfaces.firstIndex(where: { $0.id == interface.id }) {
            interfaces[index].enabled = enabled
        }
        let succeeded = await performWrite(id: interface.id, lockTable: false) {
            try await engine.patchInterface(id: interface.id, enabled: enabled)
        }
        if !succeeded {
            loadInterfaces()
        }
    }

    private func connect(_ source: InterfaceVO, to target: InterfaceVO) async {
        connectFrom = nil
        await performWrite {
            try await engine.createCable(from: source.id, to: target.id)
        }
    }

    private func requestDisconnect(_ interface: InterfaceVO) {
        guard interface.cableId != nil || interface.connectedEndpointId != nil else {
            operatorAlert = .failed("This interface has no cable.")
            return
        }
        operatorAlert = .confirmDisconnect(interface)
    }

    private func disconnectMessage(for interface: InterfaceVO) -> String {
        let here = interface.name
        let there = interface.connectedEndpointName ?? "the other end"
        return "This deletes the cable in NetBox between \(here) and \(there). That cannot be undone from here."
    }

    private func disconnect(_ interface: InterfaceVO) async {
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

    @discardableResult
    private func performWrite(
        id: Int64? = nil,
        lockTable: Bool = true,
        _ work: () async throws -> Void
    ) async -> Bool {
        if lockTable {
            guard !isWriting else { return false }
            isWriting = true
        }
        if let id {
            writingIDs.insert(id)
        }
        defer {
            if lockTable { isWriting = false }
            if let id { writingIDs.remove(id) }
        }
        do {
            try await work()
            loadInterfaces()
            return true
        } catch {
            operatorAlert = .failed(error.localizedDescription)
            editedInterfaces.removeAll()
            loadInterfaces()
            return false
        }
    }
}


/**
 This extension contains a series of subviews and functions for the InterfacesTable.
 */
extension InterfacesTable {
    
    //MARK: Subviews for the InterfacesTable
    private var tableView: some View {
        Table(selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { (interface: InterfaceVO) in
                HStack {
                    if let symbolName = poeSymbolName(for: interface.poeMode, type: interface.type) {
                        Image(systemName: symbolName)
                            .foregroundColor(interface.enabled == false ? Color.red : Color.green)
                            .font(.system(size: 15))
                    }
                    
                    Text(interface.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .width(min: 80, ideal: 160)

            TableColumn("Label", value: \.labelValue) { (interface: InterfaceVO) in
                EditableText(
                    text: Binding(
                        get: {
                            if let edited = editedInterfaces[interface.id] {
                                return edited.label ?? ""
                            }
                            return interface.label ?? ""
                        },
                        set: { editedInterfaces[interface.id, default: interface].label = $0 }
                    ),
                    onSubmitted: { value in
                        Task { await saveLabel(interface, value) }
                    }
                )
                .disabled(isWriting || writingIDs.contains(interface.id) || !owningDeviceSeated)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Description", value: \.descriptionValue) { (interface: InterfaceVO) in
                EditableText(
                    text: Binding(
                        get: {
                            if let edited = editedInterfaces[interface.id] {
                                return edited.interfaceDescription ?? ""
                            }
                            return interface.interfaceDescription ?? ""
                        },
                        set: { editedInterfaces[interface.id, default: interface].interfaceDescription = $0 }
                    ),
                    onSubmitted: { value in
                        Task { await saveDescription(interface, value) }
                    }
                )
                .disabled(isWriting || writingIDs.contains(interface.id) || !owningDeviceSeated)
            }
            .width(min: 140)

            TableColumn("Enabled") { (interface: InterfaceVO) in
                Toggle(
                    "",
                    isOn: Binding(
                        get: { interface.enabled },
                        set: { newValue in
                            Task { await setEnabled(interface, newValue) }
                        }
                    )
                )
                .labelsHidden()
                .id("\(interface.id)-enabled-\(interface.enabled)")
                .disabled(isWriting || writingIDs.contains(interface.id) || netBoxSyncEngine == nil || !owningDeviceSeated)
                .frame(maxWidth: .infinity)
            }
            .width(min: 64, ideal: 72, max: 88)

            TableColumn("Cable") { (interface: InterfaceVO) in
                if interface.cableId != nil || interface.connectedEndpointId != nil {
                    HStack {
                        Text(interface.connectedEndpointName ?? "-")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Disconnect") {
                            requestDisconnect(interface)
                        }
                        .disabled(isWriting || netBoxSyncEngine == nil || !linkAllowed(for: interface))
                        .help(linkAllowed(for: interface) ? "Delete the cable in NetBox after confirmation" : "Subscribe to resume")
                    }
                } else {
                    Button(owningDeviceSeated ? "Connect…" : "Subscribe to resume") {
                        beginConnect(interface)
                    }
                    .disabled(isWriting || netBoxSyncEngine == nil || !owningDeviceSeated)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .width(min: 120, ideal: 200)

            TableColumn("Type", value: \.typeValue) { (interface: InterfaceVO) in
                Text(interface.type ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Member") { (interface: InterfaceVO) in
                if ["lag", "bridge"].contains(interface.type) || !filteredInterfaces.isEmpty {
                    MemberCell(parentInterface: interface, allInterfaces: interfaces)
                }
            }
            .width(min: 80, ideal: 140)
        } rows: {
            ForEach(filteredInterfaces) { interface in
                TableRow(interface)
                    .contextMenu {
                        if interface.cableId != nil || interface.connectedEndpointId != nil {
                            Button("Disconnect cable…", role: .destructive) {
                                requestDisconnect(interface)
                            }
                            .disabled(isWriting || netBoxSyncEngine == nil || !linkAllowed(for: interface))
                        } else {
                            Button("Connect…") {
                                beginConnect(interface)
                            }
                            .disabled(isWriting || netBoxSyncEngine == nil || !owningDeviceSeated)
                        }
                    }
            }
        }
    }
    
    /**
     Returns the appropriate symbol name for the given Power over Ethernet (PoE) mode value.
     
     This function determines the symbol name to be used for displaying the PoE mode of an interface. If the interface can be powered by PoE, it returns a filled square symbol. Otherwise, it returns a default square symbol.
     
     - Parameter value: The PoE mode value of the interface.
     - Returns: The symbol name corresponding to the PoE mode value.
     */
    private func poeSymbolName(for value: String?, type: String?) -> String? {
        guard let value = value, let type = type else {
            return nil // Return nil for unknown values
        }
        
        let supportedInterfaceTypes = ["lag", "bridge", "virtual"]
        
        if supportedInterfaceTypes.contains(type) {
            return nil // Return nil for unsupported interface types
        } else {
            return value == "pd" ? "bolt.square.fill" : "bolt.square"
        }
    }
}

enum OperatorAlert: Identifiable {
    case failed(String)
    case confirmDisconnect(InterfaceVO)

    var id: String {
        switch self {
        case .failed: return "failed"
        case .confirmDisconnect(let interface): return "disconnect-\(interface.id)"
        }
    }
}

//MARK: Helper views for InterfacesTable

/**
 A simple view that creates a drag preview for an interface, showing its name in a styled manner.
 
 - Properties:
 - `interfaceName`: The name of the interface to display in the preview.
 
 - View body:
 The body consists of a `Text` view displaying the interface's name, styled with background and corner radius to be visually distinct during a drag operation.
 */
struct EditableText: View {
    @Binding var text: String
    var onSubmitted: ((String) -> Void)?
    
    @State private var temporaryText: String
    @FocusState private var isFocused: Bool
    
    init(text: Binding<String>, onSubmitted: ((String) -> Void)? = nil) {
        self._text = text
        self.onSubmitted = onSubmitted
        self.temporaryText = text.wrappedValue
    }
    
    var body: some View {
        TextField("", text: $temporaryText)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit(submit)
            .onChange(of: isFocused) { _, focused in
                if !focused { submit() }
            }
            .onChange(of: text) { _, newValue in
                if newValue != temporaryText {
                    temporaryText = newValue
                }
            }
#if os (macOS)
            .onExitCommand { temporaryText = text; isFocused = false }
#endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func submit() {
        guard temporaryText != text else { return }
        text = temporaryText
        onSubmitted?(temporaryText)
    }
}

struct ConnectInterfaceSheet: View {
    let source: InterfaceVO
    var device: Device? = nil
    var onCancel: () -> Void
    var onConnect: (InterfaceVO) -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var selected: Int64?
    @State private var filter = ""

    private var candidates: [InterfaceVO] {
        (try? SiteTopologyEdges.connectCandidates(
            from: source,
            device: device,
            in: modelContext
        )) ?? []
    }

    private var visible: [InterfaceVO] {
        candidates.filter { vo in
            guard !filter.isEmpty else { return true }
            let haystack = "\(vo.deviceName ?? "") \(vo.name) \(vo.interfaceDescription ?? "") \(vo.connectedEndpointName ?? "")"
            return haystack.localizedCaseInsensitiveContains(filter)
        }
    }

    private var free: [InterfaceVO] {
        visible.filter { $0.cableId == nil && $0.connectedEndpointId == nil }
    }

    private var occupied: [InterfaceVO] {
        visible.filter { $0.cableId != nil || $0.connectedEndpointId != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(source.deviceName.map { "\($0) " } ?? "")\(source.name)")
                .font(.headline)
            Text("Creates a cable in NetBox. Already-connected ports are listed so a duplicate can be rejected by the server.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No other interfaces at this site.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                TextField("Filter device or interface", text: $filter)
                    .textFieldStyle(.roundedBorder)
                List(selection: $selected) {
                    candidateSection("Free", rows: free)
                    candidateSection("Already connected", rows: occupied)
                }
                #if os(macOS)
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                #endif
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    if let id = selected, let target = candidates.first(where: { $0.id == id }) {
                        onConnect(target)
                    }
                }
                .disabled(selected == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 420)
    }

    @ViewBuilder
    private func candidateSection(_ title: String, rows: [InterfaceVO]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { vo in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(vo.deviceName ?? "device")  \(vo.name)")
                        if let other = vo.connectedEndpointName {
                            Text("Connected to \(other)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let description = vo.interfaceDescription, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(vo.id)
                }
            }
        }
    }
}
