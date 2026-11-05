//
//  HistoryFetcherActor.swift
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
import OSLog

struct HistoryFetcher {
    private let logger = Logger(subsystem: "zabbix", category: "history")
    /// Trend buckets are one hour. A shorter window stays on history.get.
    private let hourlyTrendMinimum: TimeInterval = 30 * 60

    func getHistories(itemId: String, selectedPeriod: String, valueType: String) async -> [Date: String] {
        guard let historyType = Int(valueType) else {
            logger.error("Item \(itemId, privacy: .public) has no history table (value type \(valueType, privacy: .public))")
            return [:]
        }
        let (desiredTimeFrom, timeTill) = chartTimeWindow(for: selectedPeriod)
        do {
            let historyValues = try await fetchHistoryData(itemId: itemId, timeFrom: desiredTimeFrom, timeTill: timeTill, historyType: historyType)
            let series: [Date: String]
            if historyValues.isEmpty, fallsBackToHourlyTrends(historyType: historyType, from: desiredTimeFrom, until: timeTill) {
                series = try await fetchTrendData(itemId: itemId, timeFrom: desiredTimeFrom, timeTill: timeTill)
                logger.debug("History empty for item \(itemId, privacy: .public); trend points=\(series.count, privacy: .public)")
            } else {
                series = historyValues
            }
            logger.debug("Completed getHistories for item \(itemId, privacy: .public) points=\(series.count, privacy: .public)")
            return series
        } catch {
            logger.error("Failed to fetch histories for item \(itemId, privacy: .public). Error: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Numeric items (float and unsigned) keep an hourly average when raw history is empty.
    private func fallsBackToHourlyTrends(historyType: Int, from start: Date, until end: Date) -> Bool {
        (historyType == 0 || historyType == 3) && end.timeIntervalSince(start) >= hourlyTrendMinimum
    }

    private func fetchHistoryData(itemId: String, timeFrom: Date, timeTill: Date, historyType: Int) async throws -> [Date: String] {
        let rows = try await fetchHistories(itemId: itemId, timeFrom: timeFrom, timeTill: timeTill, valueType: historyType)
        return datedValues(from: rows)
    }

    private func fetchTrendData(itemId: String, timeFrom: Date, timeTill: Date) async throws -> [Date: String] {
        let trends = try await fetchTrends(itemId: itemId, timeFrom: timeFrom, timeTill: timeTill)
        let rows = trends.map {
            HistoryProperties(itemId: $0.itemId, clock: $0.clock, value: $0.valueAvg)
        }
        return datedValues(from: rows)
    }

    private func datedValues(from rows: [HistoryProperties]) -> [Date: String] {
        var results: [Date: String] = [:]
        results.reserveCapacity(rows.count)
        for row in rows {
            guard let clock = Double(row.clock) else { continue }
            results[Date(timeIntervalSince1970: clock)] = row.value
        }
        return results
    }
}

/// The selected period, measured back from now. An unknown period is a single instant.
func chartTimeWindow(for period: String) -> (start: Date, end: Date) {
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
