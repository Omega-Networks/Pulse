//
//  DeviceUptimeChart.swift
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

struct DeviceUptimeChart: View {
    let deviceId: Int64

    @State private var icmpPingHistoryData: [Date: String] = [:]
    @State private var icmpPingItem: Item?
    
    var body: some View {
        VStack {
            Chart(icmpPingData, id: \.startDate) { dataItem in
                BarMark(
                    xStart: .value("Start", dataItem.startDate),
                    xEnd: .value("End", dataItem.endDate)
                )
                .foregroundStyle(dataItem.value == "0" ? Color.red : Color.green)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 1)) { date in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                }
            }
            .chartPlotStyle { plotContent in
                plotContent
                    .frame(minWidth: 100, idealWidth: 300, maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            }
            .presentationCornerRadius(20)
        }
        .drawingGroup()
        .zabbixItemLoad(deviceId: deviceId) {
            icmpPingHistoryData = [:]
            icmpPingItem = nil
        } load: {
            await loadICMPPingItem()
        }
    }
    
    var icmpPingData: [(startDate: Date, endDate: Date, value: String, duration: TimeInterval)] {
        let sortedHistory = icmpPingHistoryData.sorted { $0.key < $1.key }
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
    
    private func loadICMPPingItem() async {
        let items = await ItemCache.shared.getItems(forDeviceId: deviceId)
        guard !Task.isCancelled else { return }
        guard let icmpItem = items.first(where: { $0.name.localizedStandardContains("ICMP ping") }) else {
            icmpPingItem = nil
            icmpPingHistoryData = [:]
            return
        }
        icmpPingItem = icmpItem
        await fetchIcmpPingHistoryData(for: icmpItem)
    }
    
    private func fetchIcmpPingHistoryData(for item: Item) async {
        let fetchedData = await HistoryFetcher().getHistories(
            itemId: item.itemId,
            selectedPeriod: "3H",
            valueType: item.valueType
        )
        guard !Task.isCancelled else { return }
        icmpPingHistoryData = fetchedData
    }
}

//#Preview {
//    DeviceUptimeChart()
//}
