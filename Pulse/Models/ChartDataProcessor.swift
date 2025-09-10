//
//  ChartDataProcessor.swift
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
import SwiftUI

/**
 * ChartDataProcessor is responsible for efficiently processing and caching chart data.
 * It selectively applies the LTTB (Largest-Triangle-Three-Buckets) algorithm
 * for weekly data views only, while maintaining full data resolution for shorter periods.
 *
 * The processor ensures optimal performance by:
 * - Applying LTTB data reduction only to weekly views
 * - Maintaining full data granularity for network metrics in shorter time periods
 * - Caching processed data to prevent unnecessary reprocessing
 * - Only reprocessing when data or time period changes
 */
@Observable
class ChartDataProcessor {
    private var cachedFilteredData: [Date: String] = [:]
    private var lastPeriod: String = ""
    private var lastHistoryData: [Date: String] = [:]
    private let weeklyTargetPoints = 168  // One point per hour for a week
    
    /**
     * Processes time series data for chart display, using selective data reduction.
     *
     * For weekly views, applies LTTB algorithm to reduce data points while maintaining
     * visual fidelity. For all other time periods (1H-2D), maintains full data resolution
     * to preserve network metric granularity for debugging purposes.
     *
     * @param historyData Dictionary of date-value pairs representing the raw time series data
     * @param period String representing the time period to display (e.g., "1H", "1W")
     * @return Dictionary of processed date-value pairs, either reduced (weekly) or full resolution
     */
    func processData(historyData: [Date: String], period: String, item: Item?) -> [Date: String] {
        // Early return for non-chart data
        guard shouldProcessData(for: item) else {
            return historyData
        }
        
        // Return cached data if nothing has changed
        if lastPeriod == period &&
            lastHistoryData == historyData &&
            !cachedFilteredData.isEmpty {
            return cachedFilteredData
        }
        
        let (startDate, _) = getTimeRange(for: period)
        let filtered = historyData.filter { $0.key >= startDate }
        
        let reduced: [Date: String]
        if period == "1W" {
            reduced = downsampleWithLTTB(filtered, targetCount: weeklyTargetPoints)
        } else {
            reduced = filtered
        }
        
        // Update cache
        cachedFilteredData = reduced
        lastPeriod = period
        lastHistoryData = historyData
        
        return reduced
    }
    
    /**
     * Calculates the start and end dates for a given time period.
     *
     * @param period String representing the time period (e.g., "1H", "1W")
     * @return Tuple of (startDate, endDate) for the specified period
     */
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
    
    /**
     * Implements the LTTB (Largest-Triangle-Three-Buckets) algorithm for data reduction.
     * Maintains visual fidelity while reducing the number of points displayed.
     *
     * @param data Dictionary of date-value pairs to be reduced
     * @param targetCount Desired number of points in the output
     * @return Dictionary of reduced date-value pairs
     */
    private func downsampleWithLTTB(_ data: [Date: String], targetCount: Int) -> [Date: String] {
        // If we have fewer points than target or equal, return original
        guard data.count > targetCount, targetCount > 2 else { return data }
        
        // Convert dictionary to array of DataPoints
        let points = data.compactMap { date, valueStr -> DataPoint? in
            guard let value = Double(valueStr) else { return nil }
            return DataPoint(date: date, value: value)
        }.sorted()
        
        guard points.count > 2 else { return data }
        
        var sampled: [DataPoint] = []
        
        // Always add the first point
        sampled.append(points.first!)
        
        let bucketSize = Double(points.count - 2) / Double(targetCount - 2)
        
        for i in 0..<(targetCount - 2) {
            let bucketStart = Int(Double(i) * bucketSize) + 1
            let bucketEnd = Int(Double(i + 1) * bucketSize) + 1
            
            let avgX = points[bucketStart..<bucketEnd].map { $0.date.timeIntervalSince1970 }.reduce(0.0, +) / Double(bucketEnd - bucketStart)
            let avgY = points[bucketStart..<bucketEnd].map { $0.value }.reduce(0.0, +) / Double(bucketEnd - bucketStart)
            
            var maxArea = -1.0
            var maxAreaPoint = points[bucketStart]
            
            let a = sampled.last!
            let b = DataPoint(date: Date(timeIntervalSince1970: avgX), value: avgY)
            
            for point in points[bucketStart..<bucketEnd] {
                let area = abs(
                    (a.date.timeIntervalSince1970 - b.date.timeIntervalSince1970) * (point.value - a.value) -
                    (a.date.timeIntervalSince1970 - point.date.timeIntervalSince1970) * (b.value - a.value)
                )
                
                if area > maxArea {
                    maxArea = area
                    maxAreaPoint = point
                }
            }
            
            sampled.append(maxAreaPoint)
        }
        
        // Always add the last point
        sampled.append(points.last!)
        
        // Convert back to dictionary
        return Dictionary(uniqueKeysWithValues: sampled.map { ($0.date, String($0.value)) })
    }
    
    func shouldProcessData(for item: Item?) -> Bool {
        if case .chart = DisplayMode.determineMode(for: item) {
            return true
        }
        return false
    }
}

/**
 * DataPoint represents a single point of time series data.
 * Implements Comparable to enable sorting and comparison operations.
 *
 * Properties:
 * - date: The timestamp of the data point
 * - value: The numerical value at that timestamp
 */
private struct DataPoint: Comparable {
    let date: Date
    let value: Double
    
    static func < (lhs: DataPoint, rhs: DataPoint) -> Bool {
        lhs.date < rhs.date
    }
}


/**
 * Determines how item data should be displayed in the UI.
 *
 * This enum provides a clear distinction between data that should be displayed
 * as a chart (with time series data) versus simple text display. It helps prevent
 * unnecessary data processing and UI updates for non-graphable data types.
 *
 * Cases:
 * - chart: For time series data that can be visualized (e.g., percentages, bitrates)
 * - text: For data that should only be displayed as text (e.g., object IDs, status codes)
 */
enum DisplayMode: Equatable {
    case chart(unit: String)
    case text
    
    /**
     * Determines the appropriate display mode for a given item.
     *
     * This function examines the item's units to decide whether the data
     * should be displayed as a chart or as text. Only specific unit types
     * (percentages, bitrates, and seconds) are suitable for chart display.
     *
     * - Parameter item: The item whose display mode needs to be determined
     * - Returns: The appropriate DisplayMode for the item
     */
    static func determineMode(for item: Item?) -> DisplayMode {
        guard let unit = item?.units else { return .text }
        return ["%" ,"bps", "s"].contains(unit) ? .chart(unit: unit) : .text
    }
}

