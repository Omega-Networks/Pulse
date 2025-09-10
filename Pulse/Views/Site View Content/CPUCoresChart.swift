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
import SwiftData

struct CPUCoresChart: View {
    @Environment(\.modelContext) private var modelContext
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
        .task(id: deviceId) {
            await loadCPUCoreItems()
        }
    }
    
    // MARK: - Data Loading
    
    private func loadCPUCoreItems() async {
        isLoading = true
        defer { isLoading = false }
        
        // Get all items for this device and filter for CPU core items
        let items = await ItemCache.shared.getItems(forDeviceId: deviceId)
        let cpuItems = items.filter {
            $0.name.localizedStandardContains("Average Usage over 1min")
        }
        
        // Sort the items to ensure consistent ordering
        self.coreItems = cpuItems.sorted { $0.name < $1.name }
        
        // Once we have the items, fetch their history data
        await fetchHistoryData()
    }
    
    private func fetchHistoryData() async {
        for item in coreItems {
            let historyFetcher = HistoryFetcher(modelContainer: modelContext.container)
            let (fetchedData, isPartialData) = await historyFetcher.getHistories(
                deviceId: deviceId,
                itemId: item.itemId,
                selectedPeriod: "3H",
                valueType: item.valueType
            )
            
            await MainActor.run {
                historyData[item.itemId] = fetchedData
            }
            
            if isPartialData {
                // Handle partial data with background fetch
                let itemId = item.itemId
                let valueType = item.valueType
                
                Task.detached(priority: .background) {
                    let (completeData, _) = await historyFetcher.getHistories(
                        deviceId: deviceId,
                        itemId: itemId,
                        selectedPeriod: "3H",
                        valueType: valueType
                    )
                    await MainActor.run {
                        self.historyData[itemId] = completeData
                    }
                }
            }
        }
    }
    
    // MARK: - Utility Functions
    
    private func getUtilization(for item: Item) -> Double {
        guard let itemHistory = historyData[item.itemId] else {
            return 0.0
        }
        
        let sortedHistory = itemHistory.sorted { $0.key > $1.key }
        guard let latestEntry = sortedHistory.last,
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
}

// MARK: - Refresh Extension
extension CPUCoresChart {
    func refresh() async {
        await loadCPUCoreItems()
    }
}

//// MARK: - Time Range Extension
//extension CPUCoresChart {
//    private func getTimeRange(for period: String) -> (Date, Date) {
//        let now = Date()
//        
//        switch period {
//        case "1H":
//            return (Calendar.current.date(byAdding: .hour, value: -1, to: now)!, now)
//        case "3H":
//            return (Calendar.current.date(byAdding: .hour, value: -3, to: now)!, now)
//        case "6H":
//            return (Calendar.current.date(byAdding: .hour, value: -6, to: now)!, now)
//        case "12H":
//            return (Calendar.current.date(byAdding: .hour, value: -12, to: now)!, now)
//        case "1D":
//            return (Calendar.current.date(byAdding: .day, value: -1, to: now)!, now)
//        case "2D":
//            return (Calendar.current.date(byAdding: .day, value: -2, to: now)!, now)
//        case "1W":
//            return (Calendar.current.date(byAdding: .weekOfYear, value: -1, to: now)!, now)
//        default:
//            return (now, now)
//        }
//    }
//}

//#Preview {
//    CPUCoresChart()
//}
