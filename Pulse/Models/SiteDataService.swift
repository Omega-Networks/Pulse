//
//  SiteDataService.swift
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
import Dispatch
import OSLog

enum SiteDataError: Error {
    case invalidModelContainer
    case failedToFetchDevices
    case invalidConfiguration
    case networkError(Error)
}

actor SiteDataService {
    let modelContainer: ModelContainer
    private let fetcher: any NetBoxFetching
    private let filter: NetBoxFilterConfiguration
    private let logger = Logger(subsystem: "netbox", category: "site")

    init(
        modelContainer: ModelContainer,
        fetcher: any NetBoxFetching = NetBoxLiveFetcher(),
        filter: NetBoxFilterConfiguration = .default
    ) {
        self.modelContainer = modelContainer
        self.fetcher = fetcher
        self.filter = filter
    }

    //MARK: - Loading Static Devices and Loading Bays
    func getStaticDevices(for siteId: Int64) async throws {
        var query = [URLQueryItem(name: "site_id", value: String(siteId))]
        query.append(contentsOf: filter.staticDeviceRoleQueryItems)
        do {
            let (rows, skipped) = try await NetBoxPageIterator.fetchDecoded(
                path: "/api/dcim/devices/",
                extraQuery: query,
                as: NetBoxRecord.StaticDevice.self,
                using: fetcher
            )
            if skipped > 0 {
                logger.error("Skipped \(skipped) static devices for site \(siteId)")
            }
            let devices = rows.map { $0.asCacheValue() }
            await StaticDeviceCache.shared.setStaticDevices(devices, forSiteId: siteId)
            for device in devices where device.deviceRole == "Shelf" {
                try await getDeviceBays(for: device.id)
            }
        } catch {
            logger.error("Static devices for site \(siteId) failed: \(error.localizedDescription, privacy: .public)")
            throw SiteDataError.networkError(error)
        }
    }

    func getDeviceBays(for deviceId: Int64) async throws {
        do {
            let (rows, skipped) = try await NetBoxPageIterator.fetchDecoded(
                path: "/api/dcim/device-bays/",
                extraQuery: [URLQueryItem(name: "device_id", value: String(deviceId))],
                as: NetBoxRecord.DeviceBay.self,
                using: fetcher
            )
            if skipped > 0 {
                logger.error("Skipped \(skipped) device bays for device \(deviceId)")
            }
            await DeviceBayCache.shared.setDeviceBays(rows.map { $0.asCacheValue() }, forDeviceId: deviceId)
        } catch {
            logger.error("Device bays for device \(deviceId) failed: \(error.localizedDescription, privacy: .public)")
            throw SiteDataError.networkError(error)
        }
    }
    
    // Coordinator function that handles all loading
    func loadAllSiteData(for siteId: Int64) async throws {
        try await getStaticDevices(for: siteId)
        try await getInterfaces(for: siteId)
        try await getItems(for: siteId)
    }
    
    //     MARK: - Loading Interfaces and Items
    
    func getInterfaces(for siteId: Int64) async throws {
        let localContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Device>(
            predicate: #Predicate<Device> { device in
                device.site?.id == siteId
            }
        )
        let deviceIds = try localContext.fetch(descriptor).map(\.id)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    let (rows, skipped) = try await NetBoxPageIterator.fetchDecoded(
                        path: "/api/dcim/interfaces/",
                        extraQuery: [URLQueryItem(name: "device_id", value: String(deviceId))],
                        as: NetBoxRecord.Interface.self,
                        using: self.fetcher
                    )
                    if skipped > 0 {
                        self.logger.error("Skipped \(skipped) interfaces for device \(deviceId)")
                    }
                    await InterfaceCache.shared.setInterfaces(
                        rows.map { $0.asCacheValue() },
                        forDeviceId: deviceId
                    )
                }
            }
            try await group.waitForAll()
        }
    }
    
    //MARK: - WIP: loadItems function with TaskGroup
    
    //    func loadItems(for siteId: Int64) async throws {
    //        // Create local context
    //        let localContext = ModelContext(modelContainer)
    //
    //        // Create and execute fetch descriptor
    //        let descriptor = FetchDescriptor<Device>(
    //            predicate: #Predicate<Device> { device in
    //                device.site?.id == siteId && device.zabbixId != 0
    //            }
    //        )
    //
    //        let devices = try localContext.fetch(descriptor)
    //
    //        // Extract both IDs we need into a sendable collection
    //        let deviceZabbixIds = devices.map { $0.zabbixId }
    //
    //        print("Verifying devices with Zabbix IDs")
    //
    //        for id in deviceZabbixIds {
    //            print("Verifying device with Zabbix ID: \(id)")
    //        }
    //
    //        for device in devices {
    //            print("Device name: \(device.name ?? "Unknown Device Name") \n NetBox ID: \(device.id) \n Zabbix ID: \(device.zabbixId)")
    //        }
    //
    //        try await withThrowingTaskGroup(of: Void.self) { group in
    //            for deviceZabbixId in deviceZabbixIds {
    //                group.addTask { [deviceZabbixId] in  // Explicitly capture ids
    //
    //                    print("Device Zabbix ID: \(deviceZabbixId)")
    //
    //                    let itemProperties = try await fetchItems(hostId: deviceZabbixId)
    //                    let items = itemProperties.map { itemProperty in
    //                        var item = Item(itemId: itemProperty.itemId)
    //                        item.name = itemProperty.name
    //                        item.trends = itemProperty.trends
    //                        item.status = itemProperty.status
    //                        item.units = itemProperty.units
    //                        item.templateId = itemProperty.templateId
    //                        item.valueType = itemProperty.valueType
    //                        item.itemDescription = itemProperty.itemDescription
    //                        item.tags = itemProperty.tags
    //                        return item
    //                    }
    //
    //                    await ItemCache.shared.setItems(items, forDeviceId: deviceZabbixId)
    //                }
    //            }
    //
    //            try await group.waitForAll()
    //        }
    //    }
    
    
    //MARK: - Current loadItems function without TaskGroup
    
    func getItems(for siteId: Int64) async throws {
        
        // Create local context
        let localContext = ModelContext(modelContainer)
        
        // Create and execute fetch descriptor
        let descriptor = FetchDescriptor<Device>(
            predicate: #Predicate<Device> { device in
                device.site?.id == siteId && device.zabbixId != 0
            }
        )
        
        let devices = try localContext.fetch(descriptor)
        
        // Extract device IDs
        let deviceZabbixIds = devices.map { $0.zabbixId }
        
        // Process each device sequentially, matching the old pattern
        for deviceZabbixId in deviceZabbixIds {
            let itemProperties = try await fetchItems(hostId: deviceZabbixId)
            let items = itemProperties.map { itemProperty in
                var item = Item(itemId: itemProperty.itemId)
                item.name = itemProperty.name
                item.trends = itemProperty.trends
                item.status = itemProperty.status
                item.units = itemProperty.units
                item.templateId = itemProperty.templateId
                item.valueType = itemProperty.valueType
                item.itemDescription = itemProperty.itemDescription
                item.tags = itemProperty.tags
                return item
            }
            
            await ItemCache.shared.setItems(items, forDeviceId: deviceZabbixId)
        }
    }
    
    func getProblems(using eventIds: [String]? = nil, hostIds: [String]? = nil) async {
        let logger = Logger(subsystem: "zabbix", category: "problemSync")
        let batchSize = 200
        let maxRetries = 3
        
        logger.debug("Starting problem sync process")
        let startTime = Date()
        
        
        do {
            if let eventIds = eventIds {
                // Fast path - just update specific events
                logger.debug("Fetching specific events: \(eventIds)")
                let eventPropertiesList = try await fetchHostProblems(eventIds: eventIds)
                await processEvents(eventPropertiesList, modelContainer: modelContainer)
                
            } else if let hostIds = hostIds {
                // Specific hosts path - just update those hosts
                logger.debug("Fetching problems for hosts: \(hostIds)")
                let eventPropertiesList = try await fetchHostProblems(hostIds: hostIds)
                await processEvents(eventPropertiesList, modelContainer: modelContainer)
                
            } else {
                // Full sync path
                let context = ModelContext(modelContainer)
                
                // Fetch all devices with zabbixId and batch process
                let deviceFetchDescriptor = FetchDescriptor<Device>(
                    predicate: #Predicate<Device> { $0.zabbixId != 0 }
                )
                let devices = (try? context.fetch(deviceFetchDescriptor)) ?? []
                logger.debug("Found \(devices.count) devices to process")
                
                let zabbixIds = devices.map { String($0.zabbixId) }
                let batches = chunk(array: zabbixIds, size: batchSize)
                logger.debug("Created \(batches.count) batches of size \(batchSize)")
                
                // Process batches and collect current event IDs
                var currentEventIds: Set<String> = []
                try await withThrowingTaskGroup(of: [String].self) { group in
                    for (index, batch) in batches.enumerated() {
                        group.addTask {
                            logger.debug("Processing batch \(index + 1)/\(batches.count)")
                            var lastError: Error?
                            for attempt in 1...maxRetries {
                                do {
                                    let eventPropertiesList = try await fetchHostProblems(hostIds: batch)
                                    await self.processEvents(eventPropertiesList, modelContainer: self.modelContainer)
                                    return eventPropertiesList.map { $0.eventId }
                                } catch {
                                    lastError = error
                                    logger.error("Batch \(index + 1) attempt \(attempt) failed: \(error.localizedDescription)")
                                    if attempt < maxRetries {
                                        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                                        continue
                                    }
                                }
                            }
                            throw lastError ?? NSError(domain: "BatchProcessing", code: -1,
                                                 userInfo: [NSLocalizedDescriptionKey: "All retries failed"])
                        }
                    }
                    
                    // Collect all event IDs from successful batches
                    for try await batchEventIds in group {
                        currentEventIds.formUnion(batchEventIds)
                    }
                }
                
                // Delete outdated events
                logger.debug("Cleaning up old events")
                try context.delete(
                    model: Event.self,
                    where: #Predicate<Event> { event in
                        !currentEventIds.contains(event.eventId)
                    }
                )
                try context.save()
                logger.debug("Successfully cleaned up old events")
            }
            
            // Update last sync time
            let finalContext = ModelContext(modelContainer)
            if let syncProvider = try? finalContext.fetch(FetchDescriptor<SyncProvider>()).first {
                syncProvider.lastZabbixUpdate = Date()
                logger.debug("Updated last sync time")
                try finalContext.save()
            }
            
            logger.debug("Problem sync process completed successfully")
            // Performance Testing
            let timeElapsed = Date().timeIntervalSince(startTime)
            print("Total time elapsed: \(timeElapsed) seconds")
            
        } catch {
            logger.error("Failed to get problems: \(error.localizedDescription)")
        }
    }
    
    // Helper function to process events
    private func processEvents(_ eventPropertiesList: [EventProperties], modelContainer: ModelContainer) async {
        let logger = Logger(subsystem: "zabbix", category: "eventProcessing")
        let context = ModelContext(modelContainer)
        
        logger.debug("Starting to process \(eventPropertiesList.count) events")
        
        // First, fetch all existing events that match our incoming eventIds
        let eventIds = eventPropertiesList.map { $0.eventId }
        let descriptor = FetchDescriptor<Event>(
            predicate: #Predicate<Event> { event in
                eventIds.contains(event.eventId)
            }
        )
        
        let existingEvents = (try? context.fetch(descriptor)) ?? []
        logger.debug("Fetched \(existingEvents.count) existing events")
        
        // Create lookup dictionaries
        let existingEventsDict = Dictionary(uniqueKeysWithValues:
            existingEvents.map { ($0.eventId, $0) }
        )
        let propertiesDict = Dictionary(uniqueKeysWithValues:
            eventPropertiesList.map { ($0.eventId, $0) }
        )
        
        logger.debug("Created lookup dictionaries")
        
        // Update existing events
        var updateCount = 0
        for (eventId, event) in existingEventsDict {
            if let properties = propertiesDict[eventId] {
                event.update(with: properties)
                updateCount += 1
            }
        }
        
        logger.debug("Updated \(updateCount) events")
        
        // Insert new events
        let newEventIds = Set(eventIds).subtracting(existingEventsDict.keys)
        var insertCount = 0
        var insertedEventIds: [String] = []
        
        for eventId in newEventIds {
            if let properties = propertiesDict[eventId] {
                let event = Event(eventId: eventId)
                event.update(with: properties)
                context.insert(event)
                insertCount += 1
                insertedEventIds.append(eventId)
            }
        }
        
        logger.debug("Inserted \(insertCount) new events")
        
        do {
            try context.save()
            logger.debug("Successfully saved context")
            
            // Map devices for newly inserted events
            if !insertedEventIds.isEmpty {
                logger.debug("Mapping devices for \(insertedEventIds.count) new events")
                await self.getEvents(using: insertedEventIds)
            }
            
            // Total processing statistics
            logger.debug("""
                Event processing completed:
                - Processed: \(eventPropertiesList.count) events
                - Updated: \(updateCount) events
                - Inserted: \(insertCount) events
                - Device mappings: \(insertedEventIds.count) events
                """)
        } catch {
            logger.error("Failed to save context: \(error.localizedDescription)")
        }
        
        if updateCount + insertCount != eventPropertiesList.count {
            logger.warning("Mismatch in event counts. Expected \(eventPropertiesList.count), processed \(updateCount + insertCount)")
        }
    }
    
    func getEvents(using eventIds: [String]? = nil, deviceIds: [String]? = nil) async {
        let logger = Logger(subsystem: "zabbix", category: "eventSync")
        let batchSize = 200
        let maxRetries = 3
        
        logger.debug("Starting event sync process")
        
        do {
            // Determine fetch mode and get relevant devices
            let devices: [Device]
            if let deviceIds = deviceIds {
                logger.debug("Fetching events for specific devices: \(deviceIds)")
                let context = ModelContext(modelContainer)
                let ids = deviceIds.compactMap { Int64($0) }
                let descriptor = FetchDescriptor<Device>(
                    predicate: #Predicate<Device> { device in
                        device.zabbixId != 0 && ids.contains(device.id)
                    }
                )
                devices = (try? context.fetch(descriptor)) ?? []
                
            } else if eventIds == nil {
                // Full sync mode
                logger.debug("Performing full event sync")
                let context = ModelContext(modelContainer)
                let descriptor = FetchDescriptor<Device>(
                    predicate: #Predicate<Device> { $0.zabbixId != 0 }
                )
                devices = (try? context.fetch(descriptor)) ?? []
            } else {
                // Event mapping mode - we'll fetch devices later based on API response
                devices = []
            }
            
            // Prepare API request parameters
            let apiParameters: [String]
            if let eventIds = eventIds {
                apiParameters = eventIds
            } else {
                apiParameters = devices.map { String($0.zabbixId) }
            }
            
            let batches = chunk(array: apiParameters, size: batchSize)
            logger.debug("Created \(batches.count) batches for processing")
                        
            try await withThrowingTaskGroup(of: [(String, [EventProperties])].self) { group in
                // Create tasks for each batch
                for (index, batch) in batches.enumerated() {
                    group.addTask {
                        logger.debug("Processing batch \(index + 1)/\(batches.count)")
                        var lastError: Error?
                        for attempt in 1...maxRetries {
                            do {
                                let eventPropertiesList = try await fetchHostEvents(
                                    hostIds: eventIds == nil ? batch : nil,  // Fix the condition
                                    eventIds: eventIds != nil ? batch : nil
                                )
                                return eventPropertiesList.flatMap { event in
                                    event.hostIds.map { hostId in (hostId, [event]) }
                                }
                            } catch {
                                lastError = error
                                if attempt < maxRetries {
                                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                                    continue
                                }
                            }
                        }
                        throw lastError ?? NSError(domain: "BatchProcessing", code: -1,
                                                 userInfo: [NSLocalizedDescriptionKey: "All retries failed"])
                    }
                }
                
                // Process results and map to devices
                let context = ModelContext(modelContainer)
                for try await batchResults in group {
                    for (hostId, events) in batchResults {
                        // Fetch device if not already in our devices array
                        let device: Device?
                        if let existingDevice = devices.first(where: { String($0.zabbixId) == hostId }) {
                            device = existingDevice
                        } else {
                            let zabbixIdInt = Int64(hostId) ?? 0
                            let descriptor = FetchDescriptor<Device>(
                                predicate: #Predicate<Device> { $0.zabbixId == zabbixIdInt }
                            )
                            device = try? context.fetch(descriptor).first
                        }
                        
                        guard device != nil else { continue }
                                                
                        // Update or insert events
                        for eventProperty in events {
                            let searchEventId = eventProperty.eventId  // Keep as String
                            let descriptor = FetchDescriptor<Event>(
                                predicate: #Predicate<Event> { event in
                                    event.eventId == searchEventId
                                }
                            )
                            
                            if let existing = try? context.fetch(descriptor).first {
                                existing.update(with: eventProperty, device: device)
                                logger.debug("Updated existing event: \(searchEventId)")
                            } else {
                                let event = Event(eventId: searchEventId)
                                event.update(with: eventProperty, device: device)
                                context.insert(event)
                                logger.debug("Inserted new event: \(searchEventId)")
                            }
                        }
                    }
                    try context.save()
                }
            }
            
            logger.debug("Event sync completed successfully")
            
        } catch {
            logger.error("Failed to sync events: \(error.localizedDescription)")
        }
    }

    private func chunk<T>(array: [T], size: Int) -> [[T]] {
        stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }
    
    private func getDevicesWithZabbixId() async throws -> [Device] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Device>(
            predicate: #Predicate<Device> { $0.zabbixId != 0 }
        )
        return try context.fetch(descriptor)
    }
}
