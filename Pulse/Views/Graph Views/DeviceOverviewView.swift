//
//  DeviceGraphsView.swift
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

//#if os(macOS)
struct DeviceOverviewView: View {
    @Environment(\.modelContext) private var modelContext
    let deviceId: Int64
    
    // State for the two items
    @State private var icmpPingItem: Item?
    @State private var icmpResponseTimeItem: Item?
    
    @State private var defaultPeriod: (Date, Date) = (Calendar.current.date(byAdding: .hour, value: -3, to: Date())!, Date())
    @State private var icmpPingHistoryData: [Date: String] = [:]
    @State private var icmpResponseTimeHistoryData: [Date: String] = [:]
    
#if os(iOS)
    private let chartSize: CGFloat = 150
    private let innerChartSize: CGFloat = 100
    private let fontSize: CGFloat = 24
    private let lineWidth: CGFloat = 1
#else
    private let chartSize: CGFloat = 69
    private let innerChartSize: CGFloat = 32
    private let fontSize: CGFloat = 15
    private let lineWidth: CGFloat = 0.69
#endif
    
    var icmpPingData: [(startDate: Date, endDate: Date, value: String, duration: TimeInterval)] {
        let sortedHistory = icmpPingFilteredHistory.sorted { $0.key > $1.key }
        var result: [(startDate: Date, endDate: Date, value: String, duration: TimeInterval)] = []
        var currentValue: String = ""
        var currentStartDate: Date = Date.distantPast
        
        for (index, item) in sortedHistory.enumerated() {
            if currentValue.isEmpty {
                currentValue = item.value
                currentStartDate = item.key
            }
            
            if item.value != currentValue || index == sortedHistory.count - 1 {
                let endDate = item.key
                let duration = endDate.timeIntervalSince(currentStartDate)
                result.append((startDate: currentStartDate, endDate: endDate, value: currentValue, duration: duration))
                currentValue = item.value
                currentStartDate = item.key
            }
        }
        
        return result
    }
    
    var icmpPingFilteredHistory: [Date: String] {
        let (startDate, _) = defaultPeriod
        return icmpPingHistoryData.filter { $0.key >= startDate }
    }
    
    var icmpResponseTimeFilteredHistory: [Date: String] {
        let (startDate, _) = defaultPeriod
        return icmpResponseTimeHistoryData.filter { $0.key >= startDate }
    }
    
    var totalDuration: TimeInterval {
        icmpPingData.reduce(0) { total, dataItem in
            total + dataItem.duration
        }
    }
    
    var icmpResponseTimeLast: String? {
        guard let lastValue = icmpResponseTimeFilteredHistory.values.compactMap(Double.init).last else {
            return "N/A"
        }
        let milliseconds = Int(lastValue * 1000)
        return String(milliseconds)
    }
    
    var icmpResponseTimeLastInt: Double? {
        guard let value = Double(icmpResponseTimeLast ?? "0") else {
            return 0
        }
        return value
    }
    
    // Add this data structure
    private struct PingDataPoint {
        let startDate: Date
        let endDate: Date
        let value: String
        let duration: TimeInterval
    }
    
    var body: some View {
        VStack {
            HStack {
                ZStack {
                    Chart {
                        // Update ForEach to use icmpPingData
                        ForEach(icmpPingData, id: \.startDate) { dataItem in
                            SectorMark(
                                angle: .value("Duration", dataItem.duration / totalDuration * 360),
                                innerRadius: .ratio(0.7777)
                            )
                            .foregroundStyle(dataItem.value == "0" ? Color.red : Color.green)
                        }
                    }
                    .chartPlotStyle { plotContent in
                        plotContent
                            .frame(height: chartSize)
                    }
                    VStack {
                        Text(icmpResponseTimeLast ?? "Err")
                            .font(.system(size: fontSize, weight: .bold))
                            .padding(.bottom, 1)
                        
                        Chart {
                            let historyArray = icmpResponseTimeFilteredHistory.sorted(by: { $0.key < $1.key })
                            ForEach(historyArray, id: \.key) { (date, value) in
                                LineMark(
                                    x: .value("Date", date),
                                    y: .value("Value", Double(value) ?? 0)
                                )
                                .foregroundStyle(.green)
                                .lineStyle(StrokeStyle(lineWidth: lineWidth))
                            }
                        }
                        .chartYScale(range: .plotDimension(padding: 1))
                        .chartPlotStyle { plotContent in
                            plotContent
#if os(iOS)
                                .frame(width: innerChartSize, height: innerChartSize / 2)
#else
                                .frame(width: innerChartSize, height: 15)
#endif
                                .padding(.top, 0)
                                .padding(.bottom, 5)
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                    }
#if os(iOS)
                    .frame(height: innerChartSize)
#else
                    .frame(height: 20)
#endif
                }
            }
        }
        .padding(10)
#if os(iOS)
        .frame(width: chartSize * 1.5, height: chartSize * 1.5)
#endif
        .task {
            await loadItems()
        }
    }
    
    // MARK: - Data Loading
    
    private func loadItems() async {
        let items = await ItemCache.shared.getItems(forDeviceId: deviceId)
        
        // Find our specific items
        await MainActor.run {
            self.icmpPingItem = items.first(where: { $0.name == "ICMP ping" })
            self.icmpResponseTimeItem = items.first(where: { $0.name == "ICMP response time" })
        }
        
        // Fetch history data for both items
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await fetchIcmpPingHistoryData()
            }
            group.addTask {
                await fetchIcmpResponseTimeHistoryData()
            }
        }
    }
    
    private func fetchIcmpPingHistoryData() async {
        guard let item = icmpPingItem else { return }
        print("Fetching ICMP Ping data")
        
        let historyFetcher = HistoryFetcher(modelContainer: modelContext.container)
        let (fetchedData, isPartialData) = await historyFetcher.getHistories(
            deviceId: deviceId,
            itemId: item.itemId,
            selectedPeriod: "3H",
            valueType: item.valueType
        )
        
        await MainActor.run {
            icmpPingHistoryData = fetchedData
        }
        
        if isPartialData {
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
                    self.icmpPingHistoryData = completeData
                }
            }
        }
    }
    
    private func fetchIcmpResponseTimeHistoryData() async {
        guard let item = icmpResponseTimeItem else { return }
        print("Fetching ICMP Response Time data")
        
        let historyFetcher = HistoryFetcher(modelContainer: modelContext.container)
        let (fetchedData, isPartialData) = await historyFetcher.getHistories(
            deviceId: deviceId,
            itemId: item.itemId,
            selectedPeriod: "3H",
            valueType: item.valueType
        )
        
        await MainActor.run {
            icmpResponseTimeHistoryData = fetchedData
        }
        
        if isPartialData {
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
                    self.icmpResponseTimeHistoryData = completeData
                }
            }
        }
    }
}
//#endif
