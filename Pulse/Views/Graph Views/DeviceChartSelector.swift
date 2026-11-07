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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var devices: [Device]
    
    @State private var items: [Item] = []
    @State private var itemTags: [String: Set<String>] = [:]
    @State private var selectedItemTagKey: String = ""
    @State private var selectedItemTagValue: String = ""
    @State private var selectedItemId: String = ""
    @State private var selectedPeriod: String = "1H"
    
    init(deviceId: Int64) {
        self.deviceId = deviceId
        _devices = Query(filter: #Predicate<Device> { device in
            device.id == deviceId
        })
    }
    
    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { filters }
                    .animation(filterAnimation, value: filterMotion)
                VStack(spacing: 10) { filters }
                    .animation(filterAnimation, value: filterMotion)
            }

            if !selectedItemId.isEmpty {
                SelectedChart(
                    itemId: selectedItemId,
                    selectedPeriod: $selectedPeriod
                )
            }
        }
        .frame(minWidth: 200, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .zabbixItemLoad(deviceId: devices.first?.zabbixId ?? 0) {
            items = []
            itemTags = [:]
            selectedItemId = ""
            selectedItemTagKey = ""
            selectedItemTagValue = ""
        } load: {
            await loadItems()
        }
    }
    
    // MARK: - Data Loading
    
    private func loadItems() async {
        let cachedItems = await ItemCache.shared.getItems(forDeviceId: devices.first?.zabbixId ?? 0)
        guard !Task.isCancelled else { return }

        var tags: [String: Set<String>] = [:]
        for item in cachedItems {
            for (key, values) in item.tags {
                if tags[key] == nil {
                    tags[key] = []
                }
                tags[key]?.formUnion(values)
            }
        }
        items = cachedItems
        itemTags = tags
    }
    
    // MARK: - Computed Properties
    
    private var selectedItemName: String {
        items.first { $0.itemId == selectedItemId }?.name ?? ""
    }

    /// Drives the filter-row spring. The chart is not part of it.
    private var filterMotion: String {
        "\(tagKeys.isEmpty)|\(selectedItemTagKey)|\(selectedItemTagValue)|\(selectedItemId)"
    }

    private var filterAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.22)
    }

    private var tagKeys: [String] {
        itemTags.keys.filter { !$0.isEmpty }.sorted()
    }

    private var tagValues: [String] {
        (itemTags[selectedItemTagKey] ?? []).filter { !$0.isEmpty }.sorted()
    }

    /// Every item on the host. A tag name limits that to items carrying the tag, and a value limits it further.
    private var filteredItems: [Item] {
        let matched = items.filter { item in
            guard !selectedItemTagKey.isEmpty else { return true }
            guard let values = item.tags[selectedItemTagKey] else { return false }
            guard !selectedItemTagValue.isEmpty else { return true }
            return values.contains(selectedItemTagValue)
        }
        return matched.sorted { $0.name < $1.name }
    }

    @ViewBuilder
    private var filters: some View {
        if !tagKeys.isEmpty {
            Menu {
                Button("All") {
                    selectedItemTagKey = ""
                    selectedItemTagValue = ""
                }
                ForEach(tagKeys, id: \.self) { key in
                    Button(key) {
                        selectedItemTagKey = key
                        selectedItemTagValue = ""
                        clearItemUnlessVisible()
                    }
                }
            } label: {
                Text(selectedItemTagKey.isEmpty ? "Tag" : selectedItemTagKey)
                    .contentTransition(.interpolate)
            }
            .transition(filterTransition)
        }

        if !selectedItemTagKey.isEmpty {
            Menu {
                Button("Any") {
                    selectedItemTagValue = ""
                }
                ForEach(tagValues, id: \.self) { value in
                    Button(value) {
                        selectedItemTagValue = value
                        clearItemUnlessVisible()
                    }
                }
            } label: {
                Text(selectedItemTagValue.isEmpty ? "Value" : selectedItemTagValue)
                    .contentTransition(.interpolate)
            }
            .transition(filterTransition)
        }

        Menu {
            ForEach(filteredItems, id: \.itemId) { item in
                Button(item.name) {
                    selectedItemId = item.itemId
                }
            }
        } label: {
            Text(selectedItemName.isEmpty ? "Item" : selectedItemName)
                .contentTransition(.interpolate)
        }
    }

    private var filterTransition: AnyTransition {
        .scale(scale: 0.86, anchor: .leading).combined(with: .opacity)
    }

    private func clearItemUnlessVisible() {
        guard !selectedItemId.isEmpty else { return }
        if !filteredItems.contains(where: { $0.itemId == selectedItemId }) {
            selectedItemId = ""
        }
    }
}

// MARK: - Preview
#Preview {
    DeviceChartSelector(deviceId: 1)
}
