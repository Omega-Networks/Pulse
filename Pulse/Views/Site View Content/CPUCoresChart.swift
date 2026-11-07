//
//  CPUCoresChart.swift
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
import Charts

struct CPUCoresChart: View {
    let deviceId: Int64
    
    @State private var coreItems: [Item] = []
    @State private var historyData: [String: [Date: String]] = [:]
    @State private var isLoading = false
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
            } else {
                HStack(spacing: 4) {
                    let coresCount = coreItems.count
                    
                    if coresCount > 1 {
                        ForEach(0..<coresCount, id: \.self) { index in
                            let item = coreItems[index]
                            let utilization = getUtilization(for: item)
                            let utilizationPercentage = getUtilizationPercentage(utilization)
                            VStack(spacing: 3) {
                                ForEach(0..<10) { rectIndex in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(9 - rectIndex < utilizationPercentage ? Color.blue : Color.cyan)
                                        .frame(height: 4)
                                }
                            }
                            .frame(minWidth: 10, idealWidth: 30, maxWidth: .infinity)
                        }
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .zabbixItemLoad(deviceId: deviceId) {
            coreItems = []
            historyData = [:]
        } load: {
            await loadCPUCoreItems()
        }
    }
    
    // MARK: - Data Loading
    
    private func loadCPUCoreItems() async {
        isLoading = true
        defer { isLoading = false }
        
        // Get all items for this device and filter for CPU core items
        let items = await ItemCache.shared.getItems(forDeviceId: deviceId)
        guard !Task.isCancelled else { return }
        let cpuItems = items.filter {
            $0.name.localizedStandardContains("Average Usage over 1min")
        }
        coreItems = cpuItems.sorted { $0.name < $1.name }
        await fetchHistoryData()
    }
    
    private func fetchHistoryData() async {
        for item in coreItems {
            guard !Task.isCancelled else { return }
            let fetchedData = await HistoryFetcher().getHistories(
                itemId: item.itemId,
                selectedPeriod: "3H",
                valueType: item.valueType
            )
            guard !Task.isCancelled else { return }
            historyData[item.itemId] = fetchedData
        }
    }
    
    // MARK: - Utility Functions
    
    private func getUtilization(for item: Item) -> Double {
        guard let itemHistory = historyData[item.itemId] else {
            return 0.0
        }
        
        let sortedHistory = itemHistory.sorted { $0.key > $1.key }
        guard let latestEntry = sortedHistory.first,
              let utilization = Double(latestEntry.value) else {
            return 0.0
        }
        
        return utilization
    }
    
    private func getUtilizationPercentage(_ utilization: Double) -> Int {
        let percentage = utilization / 100
        
        switch percentage {
        case ...0.1: return 1
        case ...0.2: return 2
        case ...0.3: return 3
        case ...0.4: return 4
        case ...0.5: return 5
        case ...0.6: return 6
        case ...0.7: return 7
        case ...0.8: return 8
        case ...0.9: return 9
        default: return 10
        }
    }

    func refresh() async {
        await loadCPUCoreItems()
    }
}

//#Preview {
//    CPUCoresChart()
//}
