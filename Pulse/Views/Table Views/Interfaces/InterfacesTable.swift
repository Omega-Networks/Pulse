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
    @State var device: Device
    
    @State var selection = Set<Int64>()
    @State private var interfaces: [Interface] = []
    
    @State var sortOrder: [KeyPathComparator<Interface>] = [
        .init(\.id, order: SortOrder.forward)
    ]
    
    //Computed property for displaying Interfaces that do not belong in a lag, bridge or parent
    var filteredInterfaces: [Interface] {
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
    @State private var editedInterfaces: [Int64: Interface] = [:]
    
    // Property for tracking the dragged interface
    @State private var targetedInterface: Interface?
    @State private var interfaceToDelete: Interface?
    @State private var showDeleteConfirmation = false
    
    //New array for storing new Interfaces
    @State private var newInterfaces: [Interface]  = []
    
    //    @State private var dataLoaded = false
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
            }
            ///Main table view
            tableView
                .onChange(of: selection) {
                    print("selection: \(selection)")
                }
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
            await loadInterfaces()
        }
    }
    
    private func loadInterfaces() async {
        interfaces = await InterfaceCache.shared.getInterfaces(forDeviceId: device.id)
    }
}


/**
 This extension contains a series of subviews and functions for the InterfacesTable.
 */
extension InterfacesTable {
    
    //MARK: Subviews for the InterfacesTable
    private var tableView: some View {
        Table(selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name") { (interface: Interface) in
                HStack {
                    if let symbolName = poeSymbolName(for: interface.poeMode, type: interface.type) {
                        Image(systemName: symbolName)
                            .foregroundColor(interface.enabled == false ? Color.red : Color.green)
                            .font(.system(size: 15))
                    }
                    
                    Text(interface.name)
                }
            }
            
            
            TableColumn("Description") { (interface: Interface) in
                EditableText(text: Binding(
                    get: { editedInterfaces[interface.id]?.interfaceDescription ?? interface.interfaceDescription ?? "" },
                    set: { editedInterfaces[interface.id, default: interface].interfaceDescription = $0.isEmpty ? nil : $0 }
                ))
            }
            
            TableColumn("Type") { (interface: Interface) in
                Text(interface.type ?? "")
            }
            
            TableColumn("Member") { (interface: Interface) in
                if ["lag", "bridge"].contains(interface.type) || !filteredInterfaces.isEmpty {
                    MemberCell(parentInterface: interface, allInterfaces: interfaces)
                }
            }
        } rows: {
            ForEach(filteredInterfaces) { interface in
                TableRow(interface)
            }
        }
    }
    
    private func deleteButtonInTable(for interface: Interface) -> some View {
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
    
    @State private var temporaryText: String
    @FocusState private var isFocused: Bool
    
    init(text: Binding<String>) {
        self._text = text
        self.temporaryText = text.wrappedValue
    }
    
    var body: some View {
        TextField("", text: $temporaryText, onCommit: { text = temporaryText })
            .focused($isFocused, equals: true)
            .onTapGesture { isFocused = true }
#if os (macOS)
            .onExitCommand { temporaryText = text; isFocused = false }
#endif
    }
}
