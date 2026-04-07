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
import Combine

// MARK: - Background Sync Actor

/// Performs all heavy PowerSense SwiftData operations off the main thread.
/// Uses a single ModelContext per operation to ensure consistency between
/// device and event data (critical for event-device linking).
actor PowerSenseSyncActor {

    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "powersense", category: "syncActor")

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Full Sync

    /// Full sync: devices then events on a SINGLE context.
    /// Using one context ensures events can find devices saved moments before.
    func syncAll() async throws -> (deviceCount: Int, eventCount: Int) {
        let startTime = Date()
        let modelContext = ModelContext(modelContainer)
        logger.info("Starting PowerSense data sync (background)")

        let config = await Configuration.shared
        guard await config.isPowerSenseConfigured() else {
            throw PowerSenseDataServiceError.notConfigured
        }

        // Sync devices first, then events — same context so events see devices
        let deviceCount = try await syncDevices(modelContext: modelContext)
        let eventCount = try await syncEvents(modelContext: modelContext)

        // Refresh power status cache on devices that have events
        refreshAllPowerStatus(modelContext: modelContext)

        // Persist cachedIsOffline so other contexts (clustering actor) can see it
        try modelContext.save()

        let duration = Date().timeIntervalSince(startTime)
        logger.info("PowerSense sync completed in \(duration)s - \(deviceCount) devices, \(eventCount) events")

        return (deviceCount: deviceCount, eventCount: eventCount)
    }

    // MARK: - Device Sync

    /// Two-phase device sync: fetch IDs, then batch-fetch details.
    /// Uses bulk dictionary lookup instead of per-device SwiftData queries.
    private func syncDevices(modelContext: ModelContext) async throws -> Int {
        logger.info("Starting two-phase PowerSense device sync (background)")

        // Phase 1: Fetch all host IDs (lightweight API call)
        let allHostIds = try await fetchAllPowerSenseHostIds()
        logger.info("Phase 1 complete: Retrieved \(allHostIds.count) host IDs")

        // Pre-fetch ALL existing devices once into a dictionary (O(1) lookup)
        let allExistingDevices = try modelContext.fetch(FetchDescriptor<PowerSenseDevice>())
        var existingDevicesById: [String: PowerSenseDevice] = Dictionary(
            uniqueKeysWithValues: allExistingDevices.map { ($0.deviceId, $0) }
        )
        logger.info("Pre-fetched \(existingDevicesById.count) existing devices for bulk lookup")

        // Phase 2: Batch process host details
        var totalSyncedCount = 0
        var totalUpdatedCount = 0
        let batchSize = 1000
        let totalBatches = (allHostIds.count + batchSize - 1) / batchSize

        for batchIndex in 0..<totalBatches {
            let startIndex = batchIndex * batchSize
            let endIndex = min(startIndex + batchSize, allHostIds.count)
            let batchHostIds = Array(allHostIds[startIndex..<endIndex])

            let deviceProperties = try await fetchPowerSenseDevicesByIds(batchHostIds)

            var batchSyncedCount = 0
            var batchUpdatedCount = 0

            for properties in deviceProperties {
                if let existingDevice = existingDevicesById[properties.deviceId] {
                    updateDevice(existingDevice, with: properties)
                    batchUpdatedCount += 1
                } else {
                    let newDevice = PowerSenseDevice(
                        deviceId: properties.deviceId,
                        latitude: properties.privacyLatitude,
                        longitude: properties.privacyLongitude
                    )
                    updateDevice(newDevice, with: properties)
                    modelContext.insert(newDevice)
                    existingDevicesById[properties.deviceId] = newDevice
                    batchSyncedCount += 1
                }
            }

            try modelContext.save()

            totalSyncedCount += batchSyncedCount
            totalUpdatedCount += batchUpdatedCount

            let totalProgress = totalSyncedCount + totalUpdatedCount
            logger.info("Batch \(batchIndex + 1)/\(totalBatches) complete: \(batchSyncedCount) new, \(batchUpdatedCount) updated. Progress: \(totalProgress)/\(allHostIds.count)")
        }

        logger.info("Device sync complete: \(totalSyncedCount) new, \(totalUpdatedCount) updated out of \(allHostIds.count) total")
        return totalSyncedCount + totalUpdatedCount
    }

    // MARK: - Event Sync

    /// Sync events using sequential batch processing.
    /// Device lookup is built ONCE and reused across all batches.
    private func syncEvents(modelContext: ModelContext) async throws -> Int {
        logger.debug("Syncing PowerSense events (background)")

        let twentyFourHoursAgo = Date().addingTimeInterval(-24 * 3600)
        let eventProperties = try await fetchPowerSenseEvents(timeFrom: twentyFourHoursAgo)
        logger.debug("Fetched \(eventProperties.count) PowerSense events from API")

        guard !eventProperties.isEmpty else { return 0 }

        // Build device lookup ONCE for all batches
        let allDevices = try modelContext.fetch(FetchDescriptor<PowerSenseDevice>())
        let devicesByName: [String: PowerSenseDevice] = Dictionary(
            uniqueKeysWithValues: allDevices.compactMap { device -> (String, PowerSenseDevice)? in
                guard let name = device.name else { return nil }
                return (name, device)
            }
        )
        logger.debug("Built device lookup: \(devicesByName.count) devices by name")

        // Process in sequential batches
        if eventProperties.count > 500 {
            let batchSize = 200
            let batches = eventProperties.chunked(into: batchSize)
            var totalProcessed = 0

            logger.info("Processing \(eventProperties.count) events in \(batches.count) sequential batches of \(batchSize)")

            for (index, batch) in batches.enumerated() {
                logger.debug("Processing batch \(index + 1)/\(batches.count)")
                let count = try processPowerSenseEvents(batch, modelContext: modelContext, devicesByName: devicesByName)
                totalProcessed += count
            }

            logger.info("Batch processing complete: \(totalProcessed) events processed")
            return totalProcessed
        } else {
            return try processPowerSenseEvents(eventProperties, modelContext: modelContext, devicesByName: devicesByName)
        }
    }

    /// Bulk process a batch of events. Device lookup is passed in to avoid refetching.
    private func processPowerSenseEvents(
        _ eventPropertiesList: [PowerSenseEventProperties],
        modelContext: ModelContext,
        devicesByName: [String: PowerSenseDevice]
    ) throws -> Int {
        let startTime = Date()

        // Step 1: Bulk fetch existing events
        let eventIds = eventPropertiesList.map { $0.eventId }
        let eventIdSet = Set(eventIds)
        let existingEventsDescriptor = FetchDescriptor<PowerSenseEvent>(
            predicate: #Predicate<PowerSenseEvent> { event in
                eventIds.contains(event.eventId)
            }
        )
        let existingEvents = try modelContext.fetch(existingEventsDescriptor)
        let existingEventsDict = Dictionary(uniqueKeysWithValues:
            existingEvents.map { ($0.eventId, $0) }
        )

        // Step 2: Properties lookup
        let propertiesDict = Dictionary(uniqueKeysWithValues:
            eventPropertiesList.map { ($0.eventId, $0) }
        )

        // Step 3: Update existing events, track affected devices
        var updateCount = 0
        var affectedDevices: Set<String> = []

        for (eventId, event) in existingEventsDict {
            if let properties = propertiesDict[eventId] {
                event.update(with: properties)

                if event.device == nil, let ontName = properties.ontDeviceName {
                    event.device = devicesByName[ontName]
                }
                if let deviceId = event.device?.deviceId {
                    affectedDevices.insert(deviceId)
                }
                updateCount += 1
            }
        }

        // Step 4: Insert new events with linking
        let newEventIds = eventIdSet.subtracting(existingEventsDict.keys)
        var insertCount = 0
        var linkedCount = 0

        for eventId in newEventIds {
            if let properties = propertiesDict[eventId] {
                let newEvent = PowerSenseEvent(eventId: eventId, timestamp: properties.timestamp)
                newEvent.update(with: properties)

                if let ontName = properties.ontDeviceName {
                    newEvent.device = devicesByName[ontName]
                    if let device = newEvent.device {
                        linkedCount += 1
                        affectedDevices.insert(device.deviceId)
                    }
                }

                modelContext.insert(newEvent)
                insertCount += 1
            }
        }

        // Step 5: Save
        try modelContext.save()

        // Step 6: Refresh power status only on affected devices (not all 120k)
        for (_, device) in devicesByName where affectedDevices.contains(device.deviceId) {
            device.refreshPowerStatus()
        }

        let duration = Date().timeIntervalSince(startTime)
        logger.info("Processed \(eventPropertiesList.count) events in \(String(format: "%.2f", duration))s: \(updateCount) updated, \(insertCount) inserted, \(linkedCount) linked")

        return updateCount + insertCount
    }

    // MARK: - Power Status Refresh

    /// Refresh cached power status on all devices that have events.
    /// Called once at the end of a full sync cycle.
    private func refreshAllPowerStatus(modelContext: ModelContext) {
        do {
            let devicesWithEvents = try modelContext.fetch(
                FetchDescriptor<PowerSenseDevice>(
                    predicate: #Predicate<PowerSenseDevice> { !$0.events.isEmpty }
                )
            )
            for device in devicesWithEvents {
                device.refreshPowerStatus()
            }
            logger.debug("Refreshed power status on \(devicesWithEvents.count) devices")
        } catch {
            logger.error("Failed to refresh power status: \(error)")
        }
    }

    // MARK: - Helpers

    private func updateDevice(_ device: PowerSenseDevice, with properties: PowerSenseDeviceProperties) {
        device.name = properties.name
        device.isMonitored = properties.isMonitored
        device.tlc = properties.tlc
        device.tui = properties.tui
        device.alarmId = properties.alarmId
        device.zabbixHostId = properties.deviceId
        device.lastDataReceived = Date()
        device.lastUpdated = Date()
        device.latitude = properties.privacyLatitude
        device.longitude = properties.privacyLongitude
    }

    // MARK: - Data Management

    /// Get counts on background context
    func getDataCounts() throws -> (deviceCount: Int, eventCount: Int) {
        let modelContext = ModelContext(modelContainer)
        let deviceCount = try modelContext.fetchCount(FetchDescriptor<PowerSenseDevice>())
        let eventCount = try modelContext.fetchCount(FetchDescriptor<PowerSenseEvent>())
        return (deviceCount: deviceCount, eventCount: eventCount)
    }

    /// Clear only PowerSense events (keeps devices intact)
    func clearEvents() throws {
        let modelContext = ModelContext(modelContainer)
        logger.info("Clearing all PowerSense events")

        let events = try modelContext.fetch(FetchDescriptor<PowerSenseEvent>())
        for event in events { modelContext.delete(event) }

        // Reset cached power status on all devices since events are gone
        let devices = try modelContext.fetch(FetchDescriptor<PowerSenseDevice>())
        for device in devices {
            device.cachedIsOffline = nil
            device.cachedLastStatusChange = nil
        }

        try modelContext.save()
        logger.info("Cleared \(events.count) PowerSense events, reset power status on \(devices.count) devices")
    }

    /// Clear all PowerSense data (devices + events)
    func clearAllData() throws {
        let modelContext = ModelContext(modelContainer)
        logger.info("Clearing all PowerSense data")

        let events = try modelContext.fetch(FetchDescriptor<PowerSenseEvent>())
        for event in events { modelContext.delete(event) }

        let devices = try modelContext.fetch(FetchDescriptor<PowerSenseDevice>())
        for device in devices { modelContext.delete(device) }

        try modelContext.save()
        logger.info("Cleared \(events.count) events and \(devices.count) devices")
    }

    /// Sync problems and update resolutions on background context
    func syncProblems() async throws -> (activeCount: Int, resolvedCount: Int) {
        let modelContext = ModelContext(modelContainer)
        logger.info("Syncing PowerSense problems (background)")

        let config = await Configuration.shared
        guard await config.isPowerSenseConfigured() else {
            throw PowerSenseDataServiceError.notConfigured
        }

        let problems = try await fetchPowerSenseProblems()
        let activeProblemIds = Set(problems.map { $0.eventId })

        let existingEvents = try modelContext.fetch(FetchDescriptor<PowerSenseEvent>())
        let existingEventsDict = Dictionary(uniqueKeysWithValues:
            existingEvents.map { ($0.eventId, $0) }
        )

        var activeCount = 0
        var resolvedCount = 0

        for event in existingEvents {
            if activeProblemIds.contains(event.eventId) {
                if event.resolvedAt != nil { event.resolvedAt = nil }
                activeCount += 1
            } else {
                if event.resolvedAt == nil {
                    event.resolve()
                    resolvedCount += 1
                }
            }
        }

        let newProblems = problems.filter { !existingEventsDict.keys.contains($0.eventId) }

        if !newProblems.isEmpty {
            // Build device lookup for event linking
            let allDevices = try modelContext.fetch(FetchDescriptor<PowerSenseDevice>())
            let devicesByName: [String: PowerSenseDevice] = Dictionary(
                uniqueKeysWithValues: allDevices.compactMap { device -> (String, PowerSenseDevice)? in
                    guard let name = device.name else { return nil }
                    return (name, device)
                }
            )
            let newEventCount = try processPowerSenseEvents(newProblems, modelContext: modelContext, devicesByName: devicesByName)
            activeCount += newEventCount
        }

        try modelContext.save()

        logger.info("Problem sync: \(activeCount) active, \(resolvedCount) resolved, \(newProblems.count) new")
        return (activeCount: activeCount, resolvedCount: resolvedCount)
    }
}

// MARK: - UI-Facing Service (MainActor)

/// Thin MainActor wrapper for UI state. All heavy work delegates to PowerSenseSyncActor.
@MainActor
final class PowerSenseDataService: ObservableObject {

    private let logger = Logger(subsystem: "powersense", category: "dataService")
    private let syncActor: PowerSenseSyncActor

    // MARK: - Published State for UI
    @Published private(set) var isCurrentlySyncing = false
    @Published private(set) var deviceCount: Int = 0
    @Published private(set) var eventCount: Int = 0
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var syncStatus: SyncStatus = .idle
    @Published private(set) var isEnabled: Bool = false

    enum SyncStatus {
        case idle, syncing, completed, failed

        var displayName: String {
            switch self {
            case .idle: return "Ready"
            case .syncing: return "Syncing"
            case .completed: return "Completed"
            case .failed: return "Failed"
            }
        }
    }

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.syncActor = PowerSenseSyncActor(modelContainer: modelContext.container)
        logger.debug("PowerSenseDataService initialized")

        Task { await updateUIState() }
    }

    init(modelContainer: ModelContainer) {
        self.syncActor = PowerSenseSyncActor(modelContainer: modelContainer)
        logger.debug("PowerSenseDataService initialized")

        Task { await updateUIState() }
    }

    // MARK: - Sync

    func syncPowerSenseData() async throws -> (deviceCount: Int, eventCount: Int) {
        guard !isCurrentlySyncing else {
            throw PowerSenseDataServiceError.syncInProgress
        }

        isCurrentlySyncing = true
        syncStatus = .syncing
        defer { isCurrentlySyncing = false }

        return try await syncActor.syncAll()
    }

    func performSync() async {
        syncStatus = .syncing
        do {
            let (deviceCount, eventCount) = try await syncPowerSenseData()
            self.deviceCount = deviceCount
            self.eventCount = eventCount
            self.lastSyncTime = Date()
            self.syncStatus = .completed
        } catch {
            logger.error("Sync failed: \(error)")
            self.syncStatus = .failed
        }
    }

    // MARK: - Data Management

    func clearAllPowerSenseEvents(monitorService: PowerSenseMonitorService? = nil, clusteringService: ClusteringService? = nil) async {
        // Pause polling to prevent race with background event insertion
        await monitorService?.pauseForMaintenance()

        do {
            try await syncActor.clearEvents()
            await updateUIState()

            // Invalidate clustering cache and clear UI overlay
            await clusteringService?.invalidateCache()
            await monitorService?.clearCachedResults()

            logger.info("PowerSense events cleared successfully")
        } catch {
            logger.error("Clear events failed: \(error.localizedDescription)")
        }

        // Resume polling after clear completes
        await monitorService?.resumeAfterMaintenance()
    }

    func clearAllPowerSenseData(monitorService: PowerSenseMonitorService? = nil, clusteringService: ClusteringService? = nil) async {
        await monitorService?.pauseForMaintenance()
        do {
            try await syncActor.clearAllData()
            await updateUIState()
            await clusteringService?.invalidateCache()
            await monitorService?.clearCachedResults()
            logger.info("PowerSense data cleared successfully")
        } catch {
            logger.error("Clear data failed: \(error)")
        }
        await monitorService?.resumeAfterMaintenance()
    }

    func getDataCounts() async throws -> (deviceCount: Int, eventCount: Int) {
        return try await syncActor.getDataCounts()
    }

    func clearAllData() async throws {
        try await syncActor.clearAllData()
    }

    // MARK: - Configuration

    func enable() async {
        let config = await Configuration.shared
        await config.setPowerSenseEnabled(true)
        await updateUIState()
    }

    func disable() async {
        let config = await Configuration.shared
        await config.setPowerSenseEnabled(false)
        await updateUIState()
    }

    // MARK: - Test Methods

    func testEventFetching() async -> (success: Bool, message: String, eventCount: Int) {
        do {
            let config = await Configuration.shared
            guard await config.isPowerSenseConfigured() else {
                return (false, "PowerSense not configured", 0)
            }

            let (_, eventCount) = try await syncActor.syncAll()
            return (true, "Successfully fetched and processed PowerSense events", eventCount)
        } catch {
            logger.error("PowerSense event test failed: \(error)")
            return (false, "Event test failed: \(error.localizedDescription)", 0)
        }
    }

    func testProblemsFetching() async -> (success: Bool, message: String, activeCount: Int, resolvedCount: Int) {
        do {
            let config = await Configuration.shared
            guard await config.isPowerSenseConfigured() else {
                return (false, "PowerSense not configured", 0, 0)
            }

            let (activeCount, resolvedCount) = try await syncActor.syncProblems()
            return (true, "Successfully synced problems", activeCount, resolvedCount)
        } catch {
            logger.error("PowerSense problems test failed: \(error)")
            return (false, "Problems test failed: \(error.localizedDescription)", 0, 0)
        }
    }

    func testDataIngestion() async -> (success: Bool, message: String, deviceCount: Int, eventCount: Int) {
        do {
            let config = await Configuration.shared
            guard await config.isPowerSenseConfigured() else {
                return (false, "PowerSense not configured", 0, 0)
            }

            let (deviceCount, eventCount) = try await syncPowerSenseData()
            return (true, "Successfully synced PowerSense data", deviceCount, eventCount)
        } catch {
            logger.error("PowerSense test failed: \(error)")
            return (false, "Test failed: \(error.localizedDescription)", 0, 0)
        }
    }

    // MARK: - Private

    private func updateUIState() async {
        let config = await Configuration.shared
        self.isEnabled = await config.isPowerSenseEnabled()

        let counts = try? await syncActor.getDataCounts()
        self.deviceCount = counts?.deviceCount ?? 0
        self.eventCount = counts?.eventCount ?? 0
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
