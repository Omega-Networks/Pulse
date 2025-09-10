//
//  Item.swift
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
import OSLog

struct Item: Equatable {
    var itemId: String = ""
    var name: String = ""
    var trends: String = ""
    var status: String = ""
    var units: String = ""
    var templateId: String = ""
    var valueType: String = ""
    var itemDescription: String = ""
    var tags: [String: [String]] = [:]
    
    init(itemId: String) {
        self.itemId = itemId
    }
}

//MARK: New actor for caching Items
actor ItemCache {
    static let shared = ItemCache()
    private var cache: [Int64: [Item]] = [:]
    private var allItems: Set<String> = []  // Track all item IDs
    
    private init() {}
    
    func getItems(forDeviceId deviceId: Int64) -> [Item] {
        return cache[deviceId] ?? []
    }
    
    func getItems(withId itemId: String) -> Item? {
        for items in cache.values {
            if let item = items.first(where: { $0.itemId == itemId }) {
                return item
            }
        }
        return nil
    }
    
    // Add notification when items are set
    func setItems(_ items: [Item], forDeviceId deviceId: Int64) {
        cache[deviceId] = items
        Task { @MainActor in
            NotificationCenter.default.post(name: .itemsCached, object: nil, userInfo: ["deviceId": deviceId])
        }
    }
    
    ///Functions for fetching a single Item or series of Items by name
    func getItem(forDeviceId deviceId: Int64, named itemName: String) -> Item? {
        guard let deviceItems = cache[deviceId] else { return nil }
        return deviceItems.first { $0.name == itemName }
    }
    
    // Optional: Add method to get multiple items matching criteria
    func getItems(forDeviceId deviceId: Int64, matching criteria: (Item) -> Bool) -> [Item] {
        guard let deviceItems = cache[deviceId] else { return [] }
        return deviceItems.filter(criteria)
    }
    
    func getItemById(_ itemId: String) -> Item? {
        for items in cache.values {
            if let item = items.first(where: { $0.itemId == itemId }) {
                return item
            }
        }
        return nil
    }
}

// Add Notification extension
extension Notification.Name {
    static let itemsCached = Notification.Name("ItemsCached")
}


struct ItemProperties: Decodable {
    
    // MARK: Codable
    
    private enum CodingKeys: String, CodingKey {
        case itemId = "itemid"
        case name
        case history
        case trends
        case status
        case units
        case templateId = "templateid"
        case valueType = "value_type"
        case itemDescription = "description"
        case tags
    }
    
    private enum TagsKeys: String, CodingKey {
        case tag, value
    }
    
    struct Tag: Decodable {
        let tag: String
        let value: String
    }
    
    let itemId: String
    let name: String
    let history: String
    let trends: String
    let status: String
    let units: String
    let templateId: String
    let valueType: String
    let itemDescription: String
    var tags: [String: [String]]
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        
        let rawItemId = try? values.decode(String.self, forKey: .itemId)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawHistory = try? values.decode(String.self, forKey: .history)
        let rawTrends = try? values.decode(String.self, forKey: .trends)
        let rawStatus = try? values.decode(String.self, forKey: .status)
        let rawUnits = try? values.decode(String.self, forKey: .units)
        let rawTemplateId = try? values.decode(String.self, forKey: .templateId)
        let rawValueType = try? values.decode(String.self, forKey: .valueType)
        let rawItemDescription = try? values.decode(String.self, forKey: .itemDescription)
        
        var rawTags: [String: [String]] = [:]
        
        // Decode tags
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let tagArray = try codingContainer.decodeIfPresent([Tag].self, forKey: .tags) {
                for tag in tagArray {
                    if rawTags[tag.tag] != nil {
                        rawTags[tag.tag]?.append(tag.value)
                    } else {
                        rawTags[tag.tag] = [tag.value]
                    }
                }
            }
        }
        
        guard let itemId = rawItemId,
              let name = rawName,
              let history = rawHistory,
              let trends = rawTrends,
              let status = rawStatus,
              let units = rawUnits,
              let templateId = rawTemplateId,
              let valueType = rawValueType,
              let itemDescription = rawItemDescription else {
                  
            let values = "itemId = \(rawItemId?.description ?? "nil"), " +
                         "name = \(rawName?.description ?? "nil"), " +
                         "history = \(rawHistory?.description ?? "nil"), " +
                         "trends = \(rawTrends?.description ?? "nil"), " +
                         "status = \(rawStatus?.description ?? "nil"), " +
                         "units = \(rawUnits?.description ?? "nil"), " +
                         "templateId = \(rawTemplateId?.description ?? "nil"), " +
                         "valueType = \(rawValueType?.description ?? "nil"), " +
                         "itemDescription = \(rawItemDescription?.description ?? "nil")"
            
            let logger = Logger(subsystem: "zabbix", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        
        self.itemId = itemId
        self.name = name
        self.history = history
        self.trends = trends
        self.status = status
        self.units = units
        self.templateId = templateId
        self.valueType = valueType
        self.itemDescription = itemDescription
        self.tags = rawTags
    }
    
    var dictionaryValue: [String: Any] {
        [
            "itemId": itemId,
            "name": name,
            "history": history,
            "trends": trends,
            "status": status,
            "units": units,
            "templateId": templateId,
            "valueType": valueType,
            "itemDescription": itemDescription,
            "tags": tags
        ]
    }
}

