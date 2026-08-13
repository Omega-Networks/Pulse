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
import UniformTypeIdentifiers

//TODO: Update documentation for InterfacesTable
/**
 A view representing a table of network interfaces for a specific device.
 
 The `InterfacesTable` view displays a sortable and editable table of network interface objects associated with a given device. It supports drag-and-drop operations for reordering interfaces and allows for editing properties such as the interface's label and description.
 
 - Properties:
 - `device`: The `Device` object whose interfaces are being displayed.
 - `sortedInterfaces`: An array of `Interface` objects sorted by their IDs.
 - `selection`: Tracks the selected interfaces in the table.
 - `interfaces`: An array of `Interface` objects fetched from the database, filtered by the device ID.
 - `isEditing`: A Boolean value indicating whether the table is in editing mode.
 - `editedInterfaces`: A dictionary holding the interfaces being edited, keyed by their IDs.
 - `droppedInterface`: The interface on which another interface is dropped.
 
 - Initialization:
 Initializes the view with a given device, setting up the necessary state and queries.
 
 - View body:
 The main view consists of a `Table` displaying the sorted interfaces, with columns for various attributes like name, label, description, and status. It supports drag-and-drop functionality and includes a drop destination for interfaces.
 */
struct InterfacesTable: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.netBoxSyncEngine) private var netBoxSyncEngine
    @State var device: Device
    
    @State var selection = Set<Int64>()
    @State private var interfaces: [InterfaceVO] = []
    @State private var isWriting = false
    @State private var writeError: String?
    @State private var connectFrom: InterfaceVO?
    @State private var siteCandidates: [InterfaceVO] = []
    
    @State var sortOrder: [KeyPathComparator<InterfaceVO>] = [
        .init(\.id, order: SortOrder.forward)
    ]
    
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
    }
    
    // Properties for editing Interface objects
    @State private var isEditing = false
    @State private var editedInterfaces: [Int64: InterfaceVO] = [:]
    
    // Property for tracking the dragged interface
    @State private var targetedInterface: InterfaceVO?
    @State private var interfaceToDelete: InterfaceVO?
    @State private var showDeleteConfirmation = false
    
    //New array for storing new Interfaces
    @State private var newInterfaces: [InterfaceVO]  = []
    
    //    @State private var dataLoaded = false
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
            }
            ///Main table view
            tableView
                .onDrag {
                    let selectedRows = selection.map { Int($0) }
                    do {
                        let data = try JSONEncoder().encode(selectedRows)
                        let itemProvider = NSItemProvider()
                        itemProvider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
                            completion(data, nil)
                            return nil
                        }
                        return itemProvider
                    } catch {
                        print("Failed to encode selected rows: \(error)")
                        return NSItemProvider()
                    }
                }
        }
        .task {
            loadInterfaces()
        }
        .onReceive(NotificationCenter.default.publisher(for: .netBoxStoreDidApply)) { _ in
            loadInterfaces()
        }
        .sheet(item: $connectFrom) { source in
            ConnectInterfaceSheet(
                source: source,
                candidates: siteCandidates.filter {
                    $0.id != source.id && $0.cableId == nil && $0.connectedEndpointId == nil
                },
                onCancel: { connectFrom = nil },
                onConnect: { target in
                    Task { await connect(source, to: target) }
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
        .alert(
            "Disconnect cable?",
            isPresented: Binding(
                get: { interfaceToDelete != nil },
                set: { if !$0 { interfaceToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { interfaceToDelete = nil }
            Button("Disconnect", role: .destructive) {
                if let interface = interfaceToDelete {
                    interfaceToDelete = nil
                    Task { await disconnect(interface) }
                }
            }
        } message: {
            Text(disconnectMessage(for: interfaceToDelete))
        }
    }
    
    private func loadInterfaces() {
        let deviceId = device.id
        interfaces = (try? SiteTopologyEdges.fetchVOs(deviceId: deviceId, in: modelContext)) ?? []
    }

    private func beginConnect(_ interface: InterfaceVO) {
        let siteId = interface.siteId ?? device.site?.id
        if let siteId {
            siteCandidates = (try? SiteTopologyEdges.fetchVOs(siteId: siteId, in: modelContext)) ?? []
        } else {
            siteCandidates = []
        }
        connectFrom = interface
    }

    private func saveDescription(_ interface: InterfaceVO, _ value: String) async {
        let committed = interface.interfaceDescription ?? ""
        guard value != committed else {
            editedInterfaces.removeValue(forKey: interface.id)
            return
        }
        let succeeded = await performWrite {
            try await engine.patchInterface(id: interface.id, description: value)
        }
        editedInterfaces.removeValue(forKey: interface.id)
        if !succeeded {
            loadInterfaces()
        }
    }

    private func setEnabled(_ interface: InterfaceVO, _ enabled: Bool) async {
        guard enabled != interface.enabled else { return }
        await performWrite {
            try await engine.patchInterface(id: interface.id, enabled: enabled)
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
            writeError = "This interface has no cable."
            return
        }
        interfaceToDelete = interface
    }

    private func disconnectMessage(for interface: InterfaceVO?) -> String {
        guard let interface else { return "" }
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
    private func performWrite(_ work: () async throws -> Void) async -> Bool {
        guard !isWriting else { return false }
        isWriting = true
        defer { isWriting = false }
        do {
            try await work()
            loadInterfaces()
            return true
        } catch {
            writeError = error.localizedDescription
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
            TableColumn("Name") { (interface: InterfaceVO) in
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

            TableColumn("Description") { (interface: InterfaceVO) in
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
                .disabled(isWriting)
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
                .disabled(isWriting || netBoxSyncEngine == nil)
                .frame(maxWidth: .infinity)
            }
            .width(min: 64, ideal: 72, max: 88)

            TableColumn("Cable") { (interface: InterfaceVO) in
                if interface.cableId != nil || interface.connectedEndpointId != nil {
                    HStack {
                        Text(interface.connectedEndpointName ?? "—")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Disconnect") {
                            requestDisconnect(interface)
                        }
                        .disabled(isWriting || netBoxSyncEngine == nil)
                        .help("Delete the cable in NetBox after confirmation")
                    }
                } else {
                    Button("Connect…") {
                        beginConnect(interface)
                    }
                    .disabled(isWriting || netBoxSyncEngine == nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .width(min: 120, ideal: 200)

            TableColumn("Type") { (interface: InterfaceVO) in
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
                            .disabled(isWriting || netBoxSyncEngine == nil)
                        } else {
                            Button("Connect…") {
                                beginConnect(interface)
                            }
                            .disabled(isWriting || netBoxSyncEngine == nil)
                        }
                    }
            }
        }
    }
    
    private func deleteButtonInTable(for interface: InterfaceVO) -> some View {
        Button(action: {
            self.interfaceToDelete = interface
            self.showDeleteConfirmation = true
        }) {
            Image(systemName: "trash")
                .foregroundColor(.red)
        }
    }
    
    private var cancelButton: some View {
        Button("Cancel") {
            editedInterfaces.removeAll()
            isEditing = false
        }
        .keyboardShortcut(.cancelAction)
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
    let candidates: [InterfaceVO]
    var onCancel: () -> Void
    var onConnect: (InterfaceVO) -> Void
    @State private var selected: Int64?
    @State private var filter = ""

    private var grouped: [(device: String, rows: [InterfaceVO])] {
        let visible = candidates.filter { vo in
            guard !filter.isEmpty else { return true }
            let haystack = "\(vo.deviceName ?? "") \(vo.name) \(vo.interfaceDescription ?? "")"
            return haystack.localizedCaseInsensitiveContains(filter)
        }
        let byDevice = Dictionary(grouping: visible) { $0.deviceName ?? "Unknown device" }
        return byDevice.keys.sorted().map { name in
            let rows = (byDevice[name] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return (name, rows)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(source.deviceName.map { "\($0) " } ?? "")\(source.name)")
                .font(.headline)
            Text("Creates a cable in NetBox to the free interface you pick.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No free interfaces at this site.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                TextField("Filter device or interface", text: $filter)
                    .textFieldStyle(.roundedBorder)
                List(selection: $selected) {
                    ForEach(grouped, id: \.device) { group in
                        Section(group.device) {
                            ForEach(group.rows) { vo in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vo.name)
                                    if let description = vo.interfaceDescription, !description.isEmpty {
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
}
