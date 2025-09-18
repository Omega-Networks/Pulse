//
//  PowerSenseDataService.swift
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

/// Simple service for PowerSense data ingestion and SwiftData mapping
/// Focus: Basic data fetching and storage without complex UI bindings
@MainActor
final class PowerSenseDataService {

    private let logger = Logger(subsystem: "powersense", category: "dataService")
    private let modelContext: ModelContext

    // MARK: - Simple State
    private var isCurrentlySyncing = false

    // MARK: - Initialization
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        logger.debug("PowerSenseDataService initialized")
    }

    // MARK: - Basic Data Sync

    /// Simple sync method - just fetch and store data
    func syncPowerSenseData() async throws -> (deviceCount: Int, eventCount: Int) {
        guard !isCurrentlySyncing else {
            logger.debug("Sync already in progress, skipping")
            throw PowerSenseDataServiceError.syncInProgress
        }

        isCurrentlySyncing = true
        defer { isCurrentlySyncing = false }

        let startTime = Date()
        logger.info("Starting PowerSense data sync")

        // Check configuration
        let config = await Configuration.shared
        guard await config.isPowerSenseConfigured() else {
            throw PowerSenseDataServiceError.notConfigured
        }

        // Sync devices first
        let deviceCount = try await syncDevices()

        // Then sync events
        let eventCount = try await syncEvents()

        let duration = Date().timeIntervalSince(startTime)
        logger.info("PowerSense sync completed in \(duration)s - \(deviceCount) devices, \(eventCount) events")

        return (deviceCount: deviceCount, eventCount: eventCount)
    }

    /// Sync PowerSense devices using two-phase approach
    private func syncDevices() async throws -> Int {
        logger.info("Starting two-phase PowerSense device sync")

        // Phase 1: Fetch all host IDs (lightweight call)
        logger.info("Phase 1: Fetching all PowerSense host IDs...")
        let allHostIds = try await fetchAllPowerSenseHostIds()
        logger.info("Phase 1 complete: Retrieved \(allHostIds.count) host IDs (range: \(allHostIds.first ?? "none") to \(allHostIds.last ?? "none"))")

        // Verify we got the expected count
        let expectedCount = try await countPowerSenseDevices()
        if allHostIds.count != expectedCount {
            logger.warning("Host ID count mismatch: got \(allHostIds.count), expected \(expectedCount)")
        }

        // Phase 2: Batch process host details using exact host ID arrays
        var totalSyncedCount = 0
        var totalUpdatedCount = 0
        let batchSize = 1000  // Process 1000 host IDs per batch
        let totalBatches = (allHostIds.count + batchSize - 1) / batchSize

        logger.info("Phase 2: Processing \(totalBatches) batches of \(batchSize) devices each...")

        for batchIndex in 0..<totalBatches {
            let startIndex = batchIndex * batchSize
            let endIndex = min(startIndex + batchSize, allHostIds.count)
            let batchHostIds = Array(allHostIds[startIndex..<endIndex])

            logger.debug("Batch \(batchIndex + 1)/\(totalBatches): Processing host IDs \(startIndex) to \(endIndex - 1)")

            // Fetch full device details for this batch of host IDs
            let deviceProperties = try await fetchPowerSenseDevicesByIds(batchHostIds)
            logger.info("Batch \(batchIndex + 1): Fetched details for \(deviceProperties.count) devices")

            var batchSyncedCount = 0
            var batchUpdatedCount = 0

            for properties in deviceProperties {
                // Check if device already exists
                let deviceId = properties.deviceId
                let predicate = #Predicate<PowerSenseDevice> { device in
                    device.deviceId == deviceId
                }

                var descriptor = FetchDescriptor(predicate: predicate)
                descriptor.fetchLimit = 1
                let existingDevices = try modelContext.fetch(descriptor)

                if let existingDevice = existingDevices.first {
                    // Update existing device
                    updateDevice(existingDevice, with: properties)
                    batchUpdatedCount += 1
                } else {
                    // Create new device
                    let newDevice = PowerSenseDevice(
                        deviceId: properties.deviceId,
                        latitude: properties.privacyLatitude,
                        longitude: properties.privacyLongitude
                    )
                    updateDevice(newDevice, with: properties)
                    modelContext.insert(newDevice)
                    batchSyncedCount += 1
                }
            }

            // Save batch progress
            try modelContext.save()

            totalSyncedCount += batchSyncedCount
            totalUpdatedCount += batchUpdatedCount

            let totalProgress = totalSyncedCount + totalUpdatedCount
            logger.info("Batch \(batchIndex + 1)/\(totalBatches) complete: \(batchSyncedCount) new, \(batchUpdatedCount) updated. Total progress: \(totalProgress)/\(allHostIds.count)")
        }

        logger.info("Two-phase device sync complete: \(totalSyncedCount) new devices, \(totalUpdatedCount) updated devices out of \(allHostIds.count) total")
        return totalSyncedCount + totalUpdatedCount
    }

    /// Bulk process PowerSense events (optimized version)
    private func processPowerSenseEvents(_ eventPropertiesList: [PowerSenseEventProperties]) async throws -> Int {
        let logger = Logger(subsystem: "powersense", category: "bulkProcessing")

        logger.debug("🚀 Starting bulk processing of \(eventPropertiesList.count) PowerSense events")
        let startTime = Date()

        // Step 1: Bulk fetch existing events using eventIds array
        let eventIds = eventPropertiesList.map { $0.eventId }
        let existingEventsDescriptor = FetchDescriptor<PowerSenseEvent>(
            predicate: #Predicate<PowerSenseEvent> { event in
                eventIds.contains(event.eventId)
            }
        )
        let existingEvents = try modelContext.fetch(existingEventsDescriptor)
        let existingEventsDict = Dictionary(uniqueKeysWithValues:
            existingEvents.map { ($0.eventId, $0) }
        )

        logger.debug("📊 Fetched \(existingEvents.count) existing events in bulk")

        // Step 2: Bulk fetch all PowerSense devices for manual linking
        let devicesDescriptor = FetchDescriptor<PowerSenseDevice>()
        let allDevices = try modelContext.fetch(devicesDescriptor)

        logger.debug("📊 Fetched \(allDevices.count) PowerSense devices for manual linking")

        // Step 3: Create properties lookup dictionary
        let propertiesDict = Dictionary(uniqueKeysWithValues:
            eventPropertiesList.map { ($0.eventId, $0) }
        )

        // Step 4: Bulk process updates
        var updateCount = 0
        for (eventId, event) in existingEventsDict {
            if let properties = propertiesDict[eventId] {
                event.update(with: properties)

                // Update device linking if not already linked (using manual linking)
                if event.device == nil {
                    await linkEventToDevice(event, properties: properties)
                    if event.device != nil {
                        logger.debug("🔗 Linked existing event \(eventId) to device via manual linking")
                    }
                }
                updateCount += 1
            }
        }

        logger.debug("✅ Updated \(updateCount) existing events")

        // Step 5: Bulk process inserts with manual linking
        let newEventIds = Set(eventIds).subtracting(existingEventsDict.keys)
        var insertCount = 0
        var linkedCount = 0

        for eventId in newEventIds {
            if let properties = propertiesDict[eventId] {
                let newEvent = PowerSenseEvent(eventId: eventId, timestamp: properties.timestamp)
                newEvent.update(with: properties)

                // Use reliable manual linking for all new events
                await linkEventToDevice(newEvent, properties: properties)
                if newEvent.device != nil {
                    linkedCount += 1
                }

                modelContext.insert(newEvent)
                insertCount += 1
            }
        }

        logger.debug("✅ Inserted \(insertCount) new events")
        logger.debug("🔗 Manual device linking: \(linkedCount) successful links")

        // Step 6: Single context save
        try modelContext.save()

        let duration = Date().timeIntervalSince(startTime)
        logger.info("""
        🚀 Bulk PowerSense event processing completed in \(String(format: "%.2f", duration))s:
        - Processed: \(eventPropertiesList.count) events
        - Updated: \(updateCount) events
        - Inserted: \(insertCount) events
        - Manual links: \(linkedCount)/\(insertCount) successful
        - Performance: \(String(format: "%.0f", Double(eventPropertiesList.count) / duration)) events/sec
        """)

        return updateCount + insertCount
    }

    /// Sync PowerSense events with concurrent batch processing
    private func syncEvents() async throws -> Int {
        logger.debug("Syncing PowerSense events with concurrent batch processing")

        // Fetch events from last 24 hours
        let twentyFourHoursAgo = Date().addingTimeInterval(-24 * 3600)
        let eventProperties = try await fetchPowerSenseEvents(timeFrom: twentyFourHoursAgo)
        logger.debug("Fetched \(eventProperties.count) PowerSense events from API")

        // If we have many events, process in concurrent batches
        if eventProperties.count > 500 {
            return try await processPowerSenseEventsWithBatching(eventProperties)
        } else {
            // Use standard bulk processing for smaller datasets
            return try await processPowerSenseEvents(eventProperties)
        }
    }

    /// Process PowerSense events with concurrent batching for large datasets
    private func processPowerSenseEventsWithBatching(_ eventProperties: [PowerSenseEventProperties]) async throws -> Int {
        let logger = Logger(subsystem: "powersense", category: "batchProcessing")
        let batchSize = 200
        let batches = eventProperties.chunked(into: batchSize)

        logger.info("🚀 Processing \(eventProperties.count) events in \(batches.count) concurrent batches of \(batchSize)")

        return try await withThrowingTaskGroup(of: Int.self) { group in
            for (index, batch) in batches.enumerated() {
                group.addTask {
                    self.logger.debug("Processing batch \(index + 1)/\(batches.count)")
                    return try await self.processPowerSenseEvents(batch)
                }
            }

            var totalProcessed = 0
            for try await batchCount in group {
                totalProcessed += batchCount
            }

            logger.info("🎉 Concurrent batch processing complete: \(totalProcessed) events processed")
            return totalProcessed
        }
    }

    /// Update a PowerSenseDevice with properties from the API
    private func updateDevice(_ device: PowerSenseDevice, with properties: PowerSenseDeviceProperties) {
        logger.info("🔧 Updating device ID: \(properties.deviceId), Name: '\(properties.name)'")

        device.name = properties.name
        device.isMonitored = properties.isMonitored
        device.tlc = properties.tlc
        device.tui = properties.tui
        device.alarmId = properties.alarmId
        device.zabbixHostId = properties.deviceId
        device.lastDataReceived = Date()
        device.lastUpdated = Date()

        // Update location with privacy-safe coordinates
        device.latitude = properties.privacyLatitude
        device.longitude = properties.privacyLongitude

        logger.info("🔧 Device updated - Final name: '\(device.name ?? "nil")', ID: \(device.deviceId)")
    }

    /// Link PowerSense event to device using ONT device name extraction
    private func linkEventToDevice(_ event: PowerSenseEvent, properties: PowerSenseEventProperties) async {
        logger.debug("🔗 Starting linkEventToDevice for event \(properties.eventId)")

        // Extract ONT device name from event name
        guard let ontDeviceName = properties.ontDeviceName else {
            logger.debug("🔗 ❌ No ONT device name found in event: '\(properties.name)'")
            return
        }

        logger.debug("🔗 ✅ Extracted ONT device name '\(ontDeviceName)' from event: '\(properties.name)'")

        // Find matching PowerSense device by name
        let predicate = #Predicate<PowerSenseDevice> { device in
            device.name == ontDeviceName
        }

        do {
            var descriptor = FetchDescriptor(predicate: predicate)
            descriptor.fetchLimit = 1
            let matchingDevices = try modelContext.fetch(descriptor)

            if let matchingDevice = matchingDevices.first {
                event.device = matchingDevice
                logger.debug("🔗 ✅ Successfully linked event \(properties.eventId) to device '\(matchingDevice.name ?? "nil")'")
            } else {
                logger.debug("🔗 ❌ No PowerSense device found with name '\(ontDeviceName)' for event \(properties.eventId)")
            }
        } catch {
            logger.error("🔗 ❌ Error linking event to device: \(error)")
        }
    }

    // MARK: - Simple Data Management

    /// Get basic counts of stored data
    func getDataCounts() async throws -> (deviceCount: Int, eventCount: Int) {
        let deviceDescriptor = FetchDescriptor<PowerSenseDevice>()
        let eventDescriptor = FetchDescriptor<PowerSenseEvent>()

        let deviceCount = try modelContext.fetchCount(deviceDescriptor)
        let eventCount = try modelContext.fetchCount(eventDescriptor)

        return (deviceCount: deviceCount, eventCount: eventCount)
    }

    /// Clear all PowerSense data from local storage
    func clearAllData() async throws {
        logger.info("Clearing all PowerSense data")

        // Delete all events
        let eventDescriptor = FetchDescriptor<PowerSenseEvent>()
        let events = try modelContext.fetch(eventDescriptor)
        for event in events {
            modelContext.delete(event)
        }

        // Delete all devices
        let deviceDescriptor = FetchDescriptor<PowerSenseDevice>()
        let devices = try modelContext.fetch(deviceDescriptor)
        for device in devices {
            modelContext.delete(device)
        }

        try modelContext.save()
        logger.info("Cleared all PowerSense data")
    }

    /// Test method to fetch and process events only (no device sync)
    func testEventFetching() async -> (success: Bool, message: String, eventCount: Int) {
        do {
            logger.info("Testing PowerSense event fetching only...")

            // Check configuration first
            let config = await Configuration.shared
            guard await config.isPowerSenseConfigured() else {
                return (false, "PowerSense not configured", 0)
            }

            // Sync events only (no devices)
            let eventCount = try await syncEvents()

            return (true, "Successfully fetched and processed PowerSense events", eventCount)

        } catch {
            logger.error("PowerSense event test failed: \(error)")
            return (false, "Event test failed: \(error.localizedDescription)", 0)
        }
    }

    /// Test method to fetch active problems and update event resolutions (using bulk processing)
    func testProblemsFetching() async -> (success: Bool, message: String, activeCount: Int, resolvedCount: Int) {
        do {
            logger.info("🔍 Testing PowerSense problems fetching with bulk processing...")

            // Check configuration first
            let config = await Configuration.shared
            guard await config.isPowerSenseConfigured() else {
                return (false, "PowerSense not configured", 0, 0)
            }

            // Fetch current problems from API
            let problems = try await fetchPowerSenseProblems()
            logger.info("📊 Found \(problems.count) active problems")

            // Get active problem IDs
            let activeProblemIds = Set(problems.map { $0.eventId })

            // Bulk fetch all existing events
            let allEventsDescriptor = FetchDescriptor<PowerSenseEvent>()
            let existingEvents = try modelContext.fetch(allEventsDescriptor)
            let existingEventsDict = Dictionary(uniqueKeysWithValues:
                existingEvents.map { ($0.eventId, $0) }
            )

            logger.debug("📊 Fetched \(existingEvents.count) existing events for resolution checking")

            var activeCount = 0
            var resolvedCount = 0

            // Bulk update event resolutions
            for event in existingEvents {
                if activeProblemIds.contains(event.eventId) {
                    // Event is still active
                    if event.resolvedAt != nil {
                        event.resolvedAt = nil  // Mark as active again
                        logger.debug("🔴 Reactivated event \(event.eventId)")
                    }
                    activeCount += 1
                } else {
                    // Event is not in active problems, so it's resolved
                    if event.resolvedAt == nil {
                        event.resolve()  // Mark as resolved
                        logger.debug("✅ Resolved event \(event.eventId)")
                        resolvedCount += 1
                    }
                }
            }

            // Find new problems not in our database
            let newProblems = problems.filter { problem in
                !existingEventsDict.keys.contains(problem.eventId)
            }

            logger.debug("📥 Found \(newProblems.count) new problems to add")

            if !newProblems.isEmpty {
                // Use bulk processing for new problems
                let newEventCount = try await processPowerSenseEvents(newProblems)
                activeCount += newEventCount
                logger.debug("📥 Added \(newEventCount) new active problems via bulk processing")
            }

            try modelContext.save()

            logger.info("""
            🔍 Problem resolution test completed:
            - Active problems: \(activeCount)
            - Resolved events: \(resolvedCount)
            - New problems added: \(newProblems.count)
            """)

            return (true, "Successfully synced problems with bulk processing", activeCount, resolvedCount)

        } catch {
            logger.error("PowerSense problems test failed: \(error)")
            return (false, "Problems test failed: \(error.localizedDescription)", 0, 0)
        }
    }

    /// Simple test method to verify PowerSense data ingestion (full sync)
    func testDataIngestion() async -> (success: Bool, message: String, deviceCount: Int, eventCount: Int) {
        do {
            logger.info("Testing PowerSense data ingestion...")

            // Check configuration first
            let config = await Configuration.shared
            guard await config.isPowerSenseConfigured() else {
                return (false, "PowerSense not configured", 0, 0)
            }

            // Try to sync data
            let (deviceCount, eventCount) = try await syncPowerSenseData()

            return (true, "Successfully synced PowerSense data", deviceCount, eventCount)

        } catch {
            logger.error("PowerSense test failed: \(error)")
            return (false, "Test failed: \(error.localizedDescription)", 0, 0)
        }
    }
}

// MARK: - Supporting Types

enum PowerSenseDataServiceError: LocalizedError {
    case notConfigured
    case syncInProgress
    case noData

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "PowerSense is not properly configured"
        case .syncInProgress:
            return "Sync is already in progress"
        case .noData:
            return "No PowerSense data available"
        }
    }
}

