//
//  DeviceFaceplate.swift
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

struct DeviceFaceplate: View {
    // MARK: - Properties
    @Environment(\.modelContext) private var modelContext
    @Query private var device: [Device]
    private var deviceId: Int64 = 0
    
    @State private var interfaces: [Interface] = []
    @State private var hoveredInterfaceId: Int64?
    
    private let squareSize: CGFloat = 25
    
    // MARK: - Initialization
    init(deviceId: Int64) {
        self.deviceId = deviceId
        _device = Query(filter: #Predicate<Device> {
            $0.id == deviceId
        })
    }
    
    // MARK: - Interface Grouping
    private var interfaceRows: (odd: [Interface], even: [Interface]) {
        let filteredInterfaces = interfaces.filter { $0.type != "virtual" }
        
        // For interfaces just named "eth", put them in the odd row
        let ethOnlyInterfaces = filteredInterfaces.filter { $0.name.lowercased() == "eth" }
        let otherInterfaces = filteredInterfaces.filter { $0.name.lowercased() != "eth" }
        
        return (
            odd: ethOnlyInterfaces + otherInterfaces.filter { interface in
                if let portNumber = getPortNumber(from: interface.name) {
                    return portNumber % 2 != 0  // Odd numbers
                }
                return false
            }.sorted { getPortNumber(from: $0.name) ?? 0 < getPortNumber(from: $1.name) ?? 0 },
            
            even: otherInterfaces.filter { interface in
                if let portNumber = getPortNumber(from: interface.name) {
                    return portNumber % 2 == 0  // Even numbers
                }
                return false
            }.sorted { getPortNumber(from: $0.name) ?? 0 < getPortNumber(from: $1.name) ?? 0 }
        )
    }
    
    // MARK: - View Components
    private func interfaceLabel(_ name: String) -> some View {
        Text(formattedInterfaceName(name))
            .font(.caption)
    }
    
    private func interfaceCell(_ interface: Interface, row: Int, rowCount: Int) -> some View {
        VStack {
            if row == 0 {
                interfaceLabel(interface.name)
            }
            
            InterfacePortView(interface: interface, squareSize: squareSize)
            
            if rowCount == 2 && row == 1 {
                interfaceLabel(interface.name)
            }
        }
    }
    
    private func interfaceGrid(_ interfaces: [Interface]) -> some View {
        let rows = interfaceRows
        
        return VStack(spacing: 4) {
            // Top row (odd numbers)
            HStack(spacing: 8) {
                ForEach(rows.odd) { interface in
                    VStack(spacing: 2) {
                        interfaceLabel(interface.name)
                        InterfacePortView(interface: interface, squareSize: squareSize)
                    }
                }
            }
            
            // Bottom row (even numbers)
            HStack(spacing: 8) {
                ForEach(rows.even) { interface in
                    VStack(spacing: 2) {
                        InterfacePortView(interface: interface, squareSize: squareSize)
                        interfaceLabel(interface.name)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var deviceDetailsSection: some View {
        Group {
            #if os(macOS)
            if let device = device.first {
                DeviceDetails(device: device)
            }
            #endif
        }
    }
    
    private func getPortNumber(from name: String) -> Int? {
        // Handle GigabitEthernet interfaces specially
        if name.starts(with: "GigabitEthernet") {
            let components = name.components(separatedBy: "/")
            if let lastComponent = components.last {
                return Int(lastComponent)
            }
        }
        
        // Handle Eth interfaces
        if name.lowercased().starts(with: "eth") {
            return Int(name.dropFirst(3)) // Drop "eth" and convert remaining to number
        }
        
        // For other interfaces, extract numeric portion
        let numbers = name.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        
        return Int(numbers)
    }
    
    // MARK: - Main View
    var body: some View {
        HStack {
            deviceDetailsSection
            if !interfaces.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    interfaceGrid(interfaces)
                        .padding()
                }
            }
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white, lineWidth: 1)
        )
        .frame(height: 80)
        .task {
            await loadInterfaces()
        }
        .onChange(of: deviceId) {
            Task.detached(priority: .background) {
                await loadInterfaces()
            }
        }
    }
    
    // MARK: - Helper Methods
    private func loadInterfaces() async {
        interfaces = await InterfaceCache.shared.getInterfaces(forDeviceId: deviceId)
    }
    
    private func formattedInterfaceName(_ name: String) -> String {
        if name.starts(with: "GigabitEthernet") {
            let components = name.components(separatedBy: "/")
            if let lastComponent = components.last {
                return lastComponent
            }
        }
        
        // Handle Eth interfaces - keep the full name
        if name.lowercased().starts(with: "eth") {
            return name
        }
        
        // For other interfaces, extract numeric portion
        let numbers = name.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        return numbers
    }
    
    private func interfacePopoverBinding(for interfaceId: Int64) -> Binding<Bool> {
        Binding(
            get: { hoveredInterfaceId == interfaceId },
            set: { _ in hoveredInterfaceId = nil }
        )
    }
    
    private var frameWidth: CGFloat {
        let rows = interfaceRows
        let maxPorts = max(rows.odd.count, rows.even.count)
        
        // Calculate total width based on:
        // - Number of ports
        // - Square size
        // - Spacing between ports (8)
        // - Padding (16 for left and right)
        let width = (CGFloat(maxPorts) * squareSize) + (CGFloat(maxPorts - 1) * 8) + 32

        #if os(iOS)
        return width
        #else
        // On macOS, allow the view to grow but not shrink below the calculated width
        return max(width, .infinity)
        #endif
    }
}

extension DeviceFaceplate {
//    private func updateInterfacesOperationalStatus() {
//        Task.detached(priority: .background) {
//            await fetchInterfacesOperationalStatus()
//        }
//    }
//    
//    private func fetchInterfacesOperationalStatus() async {
//        let context = ModelContext(modelContext.container)
//        
//        
//        guard let device = device.first else { return }
//        
//        for interface in device.interfaces ?? [] {
//            let operationalStatusItem = device.items?.first(where: { item in
//                item.name.contains("Interface \(interface.name ?? "Error")(): Operational status")
//            })
//            
//            guard let item = operationalStatusItem else { continue }
//            
//            let (fetchedData, _) = await device.getHistories(for: item.itemId, selectedPeriod: "1H", valueType: item.valueType)
//            
//            // Get the latest status value from the fetched data
//            if let latestStatus = fetchedData.sorted(by: { $0.key > $1.key }).first?.value,
//               let intStatus = Int64(latestStatus) {
//                // Update the Interface model's operationalStatus property
//                interface.operationalStatus = intStatus
//            }
//        }
//        
//        // Save the updated Interface models
//        do {
//            try context.save()
//        } catch {
//            print("Error: \(error.localizedDescription)")
//        }
//    }
}

//MARK: - Separate view for interface port
private struct InterfacePortView: View {
    let interface: Interface
    let squareSize: CGFloat
    @State private var isHovered = false
    
    var body: some View {
        Image(systemName: "square")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: squareSize, height: squareSize)
            .foregroundColor(interface.enabled ? .green : .red)
            .onHover { isHovered = $0 }
            .popover(isPresented: $isHovered, arrowEdge: .bottom) {
                InterfacePopover(interface: interface)
            }
    }
}

//MARK: - Preview provider
#Preview {
    DeviceFaceplate(deviceId: 0)
}
