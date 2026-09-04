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

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    @MainActor
    private static func dismissZabbixWarningIfNeeded() {
        switch RequestStatusManager.shared.currentStatus[.zabbix] {
        case .connectionError, .authenticationFailure, .dataError, .unknownError:
            RequestStatusManager.shared.clear(.zabbix)
        default:
            break
        }
    }

    /// Zabbix items for this site. Racks, fillers, bays, interfaces, and
    /// cables live in SwiftData from the boot / Settings full sync.
    func loadAllSiteData(for siteId: Int64) async throws {
        do {
            try await getItems(for: siteId)
            await MainActor.run { Self.dismissZabbixWarningIfNeeded() }
        } catch {
            await MainActor.run {
                RequestStatusManager.shared.updateStatus(
                    .zabbix,
                    ZabbixError.status(from: error)
                )
            }
            throw error
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
    //                device.siteId == siteId && device.zabbixId != 0
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
                device.siteId == siteId && device.zabbixId != 0
            }
        )
        
        let presentation = RolePresentationStorage.load(from: .standard)
        let devices = try localContext.fetch(descriptor).filter {
            !presentation.policy(for: $0.deviceRole?.id).skipMonitoring
        }

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
                refreshSeverities(in: context)
                try context.save()
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
            await MainActor.run { Self.dismissZabbixWarningIfNeeded() }

        } catch {
            logger.error("Failed to get problems: \(error.localizedDescription)")
            let status = ZabbixError.status(from: error)
            await MainActor.run {
                RequestStatusManager.shared.updateStatus(.zabbix, status)
            }
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
        var insertedEvents: [Event] = []
        
        for eventId in newEventIds {
            if let properties = propertiesDict[eventId] {
                let event = Event(eventId: eventId)
                event.update(with: properties)
                context.insert(event)
                insertCount += 1
                insertedEventIds.append(eventId)
                insertedEvents.append(event)
            }
        }
        
        logger.debug("Inserted \(insertCount) new events")
        
        do {
            try context.save()
            logger.debug("Successfully saved context")
            let touched = Array(existingEventsDict.values) + insertedEvents
            refreshSeverities(in: context, events: touched)
            try? context.save()
            
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
                var mappedEvents: [Event] = []
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
                                mappedEvents.append(existing)
                                logger.debug("Updated existing event: \(searchEventId)")
                            } else {
                                let event = Event(eventId: searchEventId)
                                event.update(with: eventProperty, device: device)
                                context.insert(event)
                                mappedEvents.append(event)
                                logger.debug("Inserted new event: \(searchEventId)")
                            }
                        }
                    }
                    try context.save()
                }
                refreshSeverities(in: context, events: mappedEvents)
                try? context.save()
            }
            
            logger.debug("Event sync completed successfully")
            
        } catch {
            logger.error("Failed to sync events: \(error.localizedDescription)")
        }
    }

    func refreshSeverities() {
        let context = ModelContext(modelContainer)
        refreshSeverities(in: context)
        try? context.save()
    }

    /// Recompute stored pin colours. Pass the events that just changed so a
    /// single acknowledge does not walk every device and site (that path was
    /// ~8s at 12K devices). Full sync after stale-event delete still refreshes
    /// the whole store so resolved problems clear.
    private func refreshSeverities(in context: ModelContext, events: [Event]? = nil) {
        if let events {
            var seenDevice = Set<Int64>()
            var seenSite = Set<Int64>()
            for device in devicesTouched(by: events, in: context) {
                guard seenDevice.insert(device.id).inserted else { continue }
                device.refreshSeverityFromEvents()
                if let site = device.site, seenSite.insert(site.id).inserted {
                    site.refreshSeverityFromEvents()
                }
            }
            return
        }
        let devices = (try? context.fetch(FetchDescriptor<Device>())) ?? []
        for device in devices {
            device.refreshSeverityFromEvents()
        }
        let sites = (try? context.fetch(FetchDescriptor<Site>())) ?? []
        for site in sites {
            site.refreshSeverityFromEvents()
        }
    }

    private func devicesTouched(by events: [Event], in context: ModelContext) -> [Device] {
        var devices: [Device] = []
        var seen = Set<Int64>()
        for event in events {
            if let device = event.device, seen.insert(device.id).inserted {
                devices.append(device)
                continue
            }
            let hostId = event.hostId
            guard hostId != 0 else { continue }
            let descriptor = FetchDescriptor<Device>(
                predicate: #Predicate<Device> { $0.zabbixId == hostId }
            )
            if let device = try? context.fetch(descriptor).first, seen.insert(device.id).inserted {
                devices.append(device)
            }
        }
        return devices
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
