//
//  DeviceChartSelector.swift
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

struct DeviceChartSelector: View {
    let deviceId: Int64
    
    @Query private var devices: [Device]
    
    @State private var items: [Item] = []
    @State private var itemTags: [String: Set<String>] = [:]
    @State private var selectedItemTagKey: String = "Application"
    @State private var selectedItemTagValue: String = ""
    @State private var selectedItem: String = ""
    @State private var refreshChart: Bool = false
    @State private var isLoading = false
    
    @AppStorage("selectedPeriod") private var selectedPeriod: String = "1H"
    let periods = ["1H", "3H", "6H", "12H", "1D", "2D", "1W"]
    
    init(deviceId: Int64) {
        self.deviceId = deviceId
        _devices = Query(filter: #Predicate<Device> { device in
            device.id == deviceId
        })
    }
    
    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            if isLoading {
                ProgressView()
            } else {
                // Item Tag Value Menu
                Menu {
                    ForEach(itemTags[selectedItemTagKey]?.sorted() ?? [], id: \.self) { value in
                        Button(value) {
                            selectedItemTagValue = value
                            selectedItem = "" // Reset selected item when tag value changes
                        }
                    }
                } label: {
                    Label(selectedItemTagValue.isEmpty ? "Select Item Tag Value" : selectedItemTagValue,
                          systemImage: "chevron.down")
                }
                .cornerRadius(8)
                
                // Item Selection Menu
                if !selectedItemTagValue.isEmpty {
                    Menu {
                        ForEach(filteredItems, id: \.self) { item in
                            Button(item) {
                                selectedItem = item
                            }
                        }
                    } label: {
                        Label(selectedItem.isEmpty ? "Select Item" : selectedItem,
                              systemImage: "chevron.down")
                    }
                    .cornerRadius(8)
                }
                
                // Selected Chart
                if let selectedItemObject = items.first(where: { $0.name == selectedItem }) {
                    SelectedChart(
                        deviceId: deviceId,
                        itemId: selectedItemObject.itemId,
                        selectedPeriod: $selectedPeriod
                    )
                    .id(refreshChart)
                }
            }
        }
        .frame(minWidth: 200, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await loadItems()
        }
    }
    
    // MARK: - Data Loading
    
    private func loadItems() async {
        isLoading = true
        defer { isLoading = false }
        
        // Load items from cache
        let cachedItems = await ItemCache.shared.getItems(forDeviceId: devices.first?.zabbixId ?? 0)
        
        // Build tags dictionary
        var tags: [String: Set<String>] = [:]
        for item in cachedItems {
            for (key, values) in item.tags {
                if tags[key] == nil {
                    tags[key] = []
                }
                tags[key]?.formUnion(values)
            }
        }
        
        await MainActor.run {
            self.items = cachedItems
            self.itemTags = tags
        }
    }
    
    // MARK: - Computed Properties
    
    private var filteredItems: [String] {
        items.filter { item in
            if let applicationTags = item.tags[selectedItemTagKey] {
                return applicationTags.contains(selectedItemTagValue)
            }
            return false
        }
        .sorted(by: { $0.name < $1.name })
        .map { $0.name }
    }
}

// MARK: - Preview
#Preview {
    DeviceChartSelector(deviceId: 1)
}
