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

struct ItemChart: View {
    @State private var item: Item?
    @State private var historyData: [Date: String] = [:]
    
    let deviceId: Int64
    let itemName: String
    
    init(deviceId: Int64, item: String) {
        self.deviceId = deviceId
        self.itemName = item
    }
    
    var body: some View {
        VStack {
            if !historyData.isEmpty {
                Text(itemName.replacingOccurrences(of: "usage", with: ""))
                    .font(.headline)
            }
            
            Chart {
                let historyArray = historyData.sorted(by: { $0.key < $1.key })
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
        .zabbixItemLoad(deviceId: deviceId) {
            historyData = [:]
            item = nil
        } load: {
            await loadItem()
        }
    }

    private func loadItem() async {
        let cached = await ItemCache.shared.getItem(forDeviceId: deviceId, named: itemName)
        guard !Task.isCancelled else { return }
        item = cached
        guard let cached else {
            historyData = [:]
            return
        }
        await fetchHistoryData(for: cached)
    }

    private func fetchHistoryData(for item: Item) async {
        let fetchedData = await HistoryFetcher().getHistories(
            itemId: item.itemId,
            selectedPeriod: "3H",
            valueType: item.valueType
        )
        guard !Task.isCancelled else { return }
        historyData = fetchedData
    }
}
