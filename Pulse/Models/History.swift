//
//  History.swift
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

import OSLog
import SwiftUI
import Foundation

/**
 A class that manages a cache of History data for Item objects from Zabbix.
 It uses NSCache for efficient memory management and provides methods to get, set, append, and remove history data.
 */
actor HistoryCache {
    static let shared = HistoryCache()
    private var cache: [String: [Date: String]] = [:]
    
    private init() {}
    
    /**
     Retrieves History data for a specific Item within a given date range.
     
     - Parameters:
     - itemId: The unique identifier for the item.
     - startDate: The start date of the range to retrieve.
     - endDate: The end date of the range to retrieve.
     
     - Returns: A dictionary of dates and their corresponding values, or nil if no data is found.
     */
    func getHistory(for itemId: String, from startDate: Date, to endDate: Date) -> [Date: String]? {
        if let historyData = cache[itemId] {
            return historyData.filter { $0.key >= startDate && $0.key <= endDate }
        }
        return nil
    }
    
    /**
     Sets the entire History data for a specific Item.
     
     - Parameters:
     - history: A dictionary of dates and their corresponding values.
     - itemId: The unique identifier for the item.
     */
    func setHistory(_ history: [Date: String], for itemId: String) {
        cache[itemId] = history
    }
    
    /**
     Appends new History data to an existing item's history, or creates a new entry if none exists.
     
     - Parameters:
     - history: A dictionary of new dates and their corresponding values to append.
     - itemId: The unique identifier for the item.
     */
    func appendHistory(_ history: [Date: String], for itemId: String) {
        if var existingHistory = cache[itemId] {
            existingHistory.merge(history) { (_, new) in new }
            cache[itemId] = existingHistory
        } else {
            cache[itemId] = history
        }
    }
    
    func removeHistory(for itemId: String) {
        cache.removeValue(forKey: itemId)
    }
    
    func clearCache() {
        cache.removeAll()
    }
}

/**
 A class that holds an individual History record for an Item.
 
 TODO: Refactor to be a struct
 */
struct HistoryData {
    let data: [Date: String]
}

/**
 A struct that represents the properties of a History record.
 It conforms to Decodable for JSON parsing.
 */
struct HistoryProperties: Decodable {
    
    // MARK: Codable
    
    private enum CodingKeys: String, CodingKey {
        case itemId = "itemid"
        case clock
        case value
    }
    
    let itemId: String
    let clock: String
    let value: String
    
    /**
     Initializes a new HistoryProperties instance from a decoder.
     Throws an error if required data is missing.
     
     - Parameter decoder: The decoder to read data from.
     - Throws: SwiftDataError.missingData if required fields are missing.
     */
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        
        let rawItemId = try? values.decode(String.self, forKey: .itemId)
        let rawClock = try? values.decode(String.self, forKey: .clock)
        let rawValue = try? values.decode(String.self, forKey: .value)
        
        guard let itemId = rawItemId,
              let clock = rawClock,
              let value = rawValue else {
            
            let values =  "itemId = \(rawItemId?.description ?? "nil"), " +
            "clock = \(rawClock?.description ?? "nil"), " +
            "value = \(rawValue?.description ?? "nil")"
            
            let logger = Logger(subsystem: "zabbix", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        
        self.itemId = itemId
        self.clock = clock
        self.value = value
    }
    
    /**
     Converts the HistoryProperties instance to a dictionary representation.
     
     - Returns: A dictionary with keys "itemId", "clock", and "value".
     */
    var dictionaryValue: [String: Any] {
        [
            "itemId": itemId,
            "clock": clock,
            "value": value
        ]
    }
}

