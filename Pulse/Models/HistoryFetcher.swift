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
import SwiftData

actor HistoryFetcher {
    var modelContainer: ModelContainer
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }
    
    func getHistories(deviceId: Int64, itemId: String, selectedPeriod: String, valueType: String) async -> ([Date: String], Bool) {
        // Set timeFrom and timeTill based on the selected period
        let (desiredTimeFrom, timeTill) = getTimeRange(for: selectedPeriod)
        
        // Check if history data already exists in the cache for the specific period
        if let cachedHistory = await HistoryCache.shared.getHistory(for: itemId, from: desiredTimeFrom, to: timeTill) {
            // Calculate the percentage of cached data within the desired period
            let totalDuration = timeTill.timeIntervalSince(desiredTimeFrom)
            
            if let cachedMaxDate = cachedHistory.keys.max(), let cachedMinDate = cachedHistory.keys.min() {
                let cachedDuration = cachedMaxDate.timeIntervalSince(cachedMinDate)
                let cachedPercentage = cachedDuration / totalDuration
                
                print("Cached percentage: \(cachedPercentage * 100)%")
                
                // If the cached data covers 90% or more of the desired period, return the cached data and fetch the remaining data
                if cachedPercentage >= 0.9 {
                    print("Cached percentage is 90% or more. Returning cached data and fetching missing data.")
                    // Fetch the remaining data asynchronously
                    Task {
                        let missingStartDate = cachedMaxDate.addingTimeInterval(1)
                        do {
                            let missingData = try await fetchHistoryData(itemId: itemId, timeFrom: missingStartDate, timeTill: timeTill, valueType: valueType)
                            // Update the cache with the missing data
                            await HistoryCache.shared.appendHistory(missingData, for: itemId)
                        } catch {
                            print("Failed to fetch missing histories. Error: \(error)")
                        }
                    }
                    
                    return (cachedHistory, true)
                }
            } else {
                print("Cached history data is incomplete or missing. Fetching the entire history data.")
            }
        }
        
        // Fetch the entire history data from the server
        do {
            let historyValues = try await fetchHistoryData(itemId: itemId, timeFrom: desiredTimeFrom, timeTill: timeTill, valueType: valueType)
            // Update the cache with the fetched history data
            await HistoryCache.shared.setHistory(historyValues, for: itemId)
            print("Completed getHistories function")
            return (historyValues, false)
        } catch {
            print("Failed. Error: \(error)")
            return ([:], false)
        }
    }

    //TODO: Refactor to accomodate to Swift 6 data race safety
    private func fetchHistoryData(itemId: String, timeFrom: Date, timeTill: Date, valueType: String) async throws -> [Date: String] {
        do {
            let historyPropertiesList = try await fetchHistories(itemId: itemId, timeFrom: timeFrom, timeTill: timeTill, valueType: Int(valueType) ?? 0)

            let batchSize = determineBatchSize(for: historyPropertiesList.count)
            let batches = historyPropertiesList.chunked(into: batchSize)

            let merger = ResultsMerger()

            await withThrowingTaskGroup(of: Void.self) { group in
                for batch in batches {
                    group.addTask {
                        let batchResult = try await self.processHistoryBatch(batch: batch)
                        await merger.merge(batchResult)
                    }
                }
            }

            return await merger.getResults()
        } catch {
            print("Failed to fetch history data. Error: \(error)")
            throw error
        }
    }
    
    private func processHistoryBatch(batch: [HistoryProperties]) async throws -> [Date: String] {
        var results: [Date: String] = [:]
        for historyProperty in batch {
            if let clockDouble = Double(historyProperty.clock) {
                let date = Date(timeIntervalSince1970: clockDouble)
                results[date] = historyProperty.value
            }
        }
        return results
    }
    
    private func determineBatchSize(for count: Int) -> Int {
        // You can adjust these values based on performance testing
        switch count {
        case 1...10:
            return 2
        case 11...100:
            return 10
        case 101...500:
            return 25
        case 501...1000:
            return 50
        case 1001...10000:
            return 500
        case 10001...50000:
            return 2500
        case 50001...100000:
            return 1000
        default:
            return 2000
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


//MARK: New Actor for merging results of fetched History data
actor ResultsMerger {
    private var mergedResults: [Date: String] = [:]
    
    func merge(_ result: [Date: String]) {
        mergedResults.merge(result, uniquingKeysWith: { (_, new) in new })
    }
    
    func getResults() -> [Date: String] {
        return mergedResults
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
