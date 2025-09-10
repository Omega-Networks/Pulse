//
//  ItemChart.swift
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

struct ItemChart: View {
    @Environment(\.modelContext) private var modelContext
    @State private var item: Item?
    @State private var historyData: [Date: String] = [:]
    
    let deviceId: Int64
    let itemName: String
    
    init(deviceId: Int64, item: String) {
        self.deviceId = deviceId
        self.itemName = item
    }
    
    var filteredHistory: [Date: String] {
        let (startDate, _) = getTimeRange(for: "3H")
        return historyData.filter { $0.key >= startDate }
    }
    
    
    var body: some View {
        //TODO: Instead of displaying every single data piece, take a sample from the last 3 hours
        
        VStack {
            if !filteredHistory.isEmpty {
                Text(itemName.replacingOccurrences(of: "usage", with: ""))
                    .font(.headline)
            }
            
            Chart {
                let historyArray = filteredHistory.sorted(by: { $0.key < $1.key })
                ForEach(historyArray, id: \.key) { (date, value) in
                    let value = Double(value) ?? 0
                    
                    LineMark(
                        x: .value("Date", date),
                        y: .value("Value", value)
                    )
                    .foregroundStyle(.green)
                    
                    AreaMark(
                        x: .value("Date", date),
                        y: .value("Value", value)
                    )
                    .foregroundStyle(LinearGradient(
                        gradient: Gradient(colors: [
                            .green,
                            .clear]),
                        startPoint: .top, endPoint: .bottom)
                    )
                }
            }
            .chartPlotStyle { plotStyle in
                plotStyle
                    .frame(minWidth: 100, idealWidth: 200, maxWidth: .infinity, maxHeight: 80)
            }
            .chartYScale(domain: [0, 100])
            .chartYAxis {
                switch item?.units ?? "" {
                case "%":
                    AxisMarks(
                        format: Decimal.FormatStyle.Percent.percent.scale(1)
                    )
                default:
                    AxisMarks(
                        format: Decimal.FormatStyle()
                    )
                }
            }
        }
        .drawingGroup()
        .task(id: deviceId) {
            // Load the specific item from cache
            self.item = await ItemCache.shared.getItem(forDeviceId: deviceId, named: itemName)
            
            // Then fetch history data if item exists
            if let item = self.item {
                await fetchHistoryData(for: item)
            }
        }
    }
}

extension ItemChart {
    private func fetchHistoryData(for item: Item) async {
        let historyFetcher = HistoryFetcher(modelContainer: modelContext.container)
        let (fetchedData, isPartialData) = await historyFetcher.getHistories(
            deviceId: deviceId,
            itemId: item.itemId,
            selectedPeriod: "3H",
            valueType: item.valueType
        )
        
        await MainActor.run {
            historyData = fetchedData
        }
        
        if isPartialData {
            // If partial data was returned, the cache has been updated with new data
            // We can schedule a background task to fetch the rest if needed
            let itemId = item.itemId
            let valueType = item.valueType
            
            Task.detached(priority: .background) {
                let (completeData, _) = await historyFetcher.getHistories(deviceId: deviceId, itemId: itemId, selectedPeriod: "3H", valueType: valueType)
                await MainActor.run {
                    self.historyData = completeData
                }
            }
        }
    }
    
    private func getTimeRange(for period: String) -> (Date, Date) {
        let now = Date()
        
        switch period {
        case "1H":
            return (Calendar.current.date(byAdding: .hour, value: -1, to: now)!, now)
        case "3H":
            return (Calendar.current.date(byAdding: .hour, value: -3, to: now)!, now)
        case "6H":
            return (Calendar.current.date(byAdding: .hour, value: -6, to: now)!, now)
        case "12H":
            return (Calendar.current.date(byAdding: .hour, value: -12, to: now)!, now)
        case "1D":
            return (Calendar.current.date(byAdding: .day, value: -1, to: now)!, now)
        case "2D":
            return (Calendar.current.date(byAdding: .day, value: -2, to: now)!, now)
        case "1W":
            return (Calendar.current.date(byAdding: .weekOfYear, value: -1, to: now)!, now)
        default:
            return (now, now)
        }
    }
}

//MARK: - New class for managing chart data
@ModelActor
actor ChartDataActor {
    private var historyData: [String: [Date: String]] = [:] // itemId -> history data
    private var items: [Item] = []
    private var lastFetchTime: [String: Date] = [:] // itemType -> last fetch time
    private let refreshInterval: TimeInterval = 60
    
    enum ChartType {
        case icmpPing
        case cpuCores
        case itemUsage(String) // for CPU/Memory usage
    }
    
    func getData(for chartType: ChartType) async -> (items: [Item], historyData: [String: [Date: String]]) {
        switch chartType {
        case .icmpPing:
            let relevantItems = items.filter { $0.name.localizedStandardContains("ICMP ping") }
            return filterHistoryData(for: relevantItems)
        case .cpuCores:
            let relevantItems = items.filter { $0.name.localizedStandardContains("Average Usage over 1min") }
            return filterHistoryData(for: relevantItems)
        case .itemUsage(let itemName):
            let relevantItems = items.filter { $0.name.localizedStandardContains(itemName) }
            return filterHistoryData(for: relevantItems)
        }
    }
    
    func updateData(deviceId: Int64, chartType: ChartType, container: ModelContainer) async {
        guard needsRefresh(for: chartType) else { return }
        
        // Fetch all items if we haven't already
        if items.isEmpty {
            items = await ItemCache.shared.getItems(forDeviceId: deviceId)
        }
        
        let relevantItems: [Item]
        switch chartType {
        case .icmpPing:
            relevantItems = items.filter { $0.name.localizedStandardContains("ICMP ping") }
        case .cpuCores:
            relevantItems = items.filter { $0.name.localizedStandardContains("Average Usage over 1min") }
        case .itemUsage(let itemName):
            relevantItems = items.filter { $0.name.localizedStandardContains(itemName) }
        }
        
        let historyFetcher = HistoryFetcher(modelContainer: container)
        
        for item in relevantItems {
            let (fetchedData, isPartialData) = await historyFetcher.getHistories(
                deviceId: deviceId,
                itemId: item.itemId,
                selectedPeriod: "3H",
                valueType: item.valueType
            )
            
            historyData[item.itemId] = fetchedData
            
            if isPartialData {
                await fetchRemainingData(
                    using: historyFetcher,
                    deviceId: deviceId,
                    item: item
                )
            }
        }
        
        lastFetchTime[String(describing: chartType)] = .now
    }
    
    private func filterHistoryData(for items: [Item]) -> (items: [Item], historyData: [String: [Date: String]]) {
        let relevantHistoryData = historyData.filter { historyEntry in
            items.contains { $0.itemId == historyEntry.key }
        }
        return (items, relevantHistoryData)
    }
    
    private func needsRefresh(for chartType: ChartType) -> Bool {
        let key = String(describing: chartType)
        guard let lastFetch = lastFetchTime[key] else { return true }
        return Date.now.timeIntervalSince(lastFetch) > refreshInterval
    }
    
    private func fetchRemainingData(using fetcher: HistoryFetcher, deviceId: Int64, item: Item) async {
        let (completeData, _) = await fetcher.getHistories(
            deviceId: deviceId,
            itemId: item.itemId,
            selectedPeriod: "3H",
            valueType: item.valueType
        )
        historyData[item.itemId] = completeData
    }
}
