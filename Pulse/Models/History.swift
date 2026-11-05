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
import Foundation

/**
 A struct that represents the properties of a History record.
 It conforms to Decodable for JSON parsing.
 */
struct HistoryProperties: Decodable, Sendable {
    
    // MARK: Codable
    
    private enum CodingKeys: String, CodingKey {
        case itemId = "itemid"
        case clock
        case value
    }
    
    let itemId: String
    let clock: String
    let value: String

    init(itemId: String, clock: String, value: String) {
        self.itemId = itemId
        self.clock = clock
        self.value = value
    }
    
    /**
     Initializes a new HistoryProperties instance from a decoder.
     Throws an error if required data is missing.
     
     - Parameter decoder: The decoder to read data from.
     - Throws: SwiftDataError.missingData if required fields are missing.
     */
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        
        let rawItemId = ZabbixJSONRPC.flexibleString(values, .itemId)
        let rawClock = ZabbixJSONRPC.flexibleString(values, .clock)
        let rawValue = ZabbixJSONRPC.flexibleString(values, .value)
        
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

/// One hour of a numeric item. Zabbix keeps this after the raw history rows are gone.
struct TrendProperties: Decodable, Sendable {
    let itemId: String
    let clock: String
    let valueAvg: String

    private enum CodingKeys: String, CodingKey {
        case itemId = "itemid"
        case clock
        case valueAvg = "value_avg"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let itemId = ZabbixJSONRPC.flexibleString(values, .itemId),
              let clock = ZabbixJSONRPC.flexibleString(values, .clock),
              let valueAvg = ZabbixJSONRPC.flexibleString(values, .valueAvg) else {
            throw SwiftDataError.missingData
        }
        self.itemId = itemId
        self.clock = clock
        self.valueAvg = valueAvg
    }
}

