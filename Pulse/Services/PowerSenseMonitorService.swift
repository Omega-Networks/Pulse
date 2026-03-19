//
//  PowerSenseMonitorService.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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

/// Background service for PowerSense event monitoring and cluster caching
/// Optimizes overlay display from 20-30s to <0.4s via pre-computed clustering
/// Uses background actor for heavy work, MainActor only for UI state updates
@Observable
@MainActor
final class PowerSenseMonitorService {

    // MARK: - Dependencies

    private let backgroundActor: BackgroundMonitorActor
    private let logger = Logger(subsystem: "pulse", category: "powerSenseMonitor")

    // MARK: - State (MainActor for UI binding)

    private(set) var isInitialized = false
    private(set) var cachedResult: ClusterResult?
    private(set) var lastUpdateTime: Date?

    // MARK: - Initialization

    init(clusteringService: ClusteringService, modelContainer: ModelContainer) {
        self.backgroundActor = BackgroundMonitorActor(
            clusteringService: clusteringService,
            modelContainer: modelContainer
        )
        logger.debug("PowerSenseMonitorService initialized")
    }

    // MARK: - Public Interface

    /// Initialize service: perform initial clustering and cache results (background)
    func initialize() async throws {
        logger.info("🚀 Initializing PowerSense monitor (background)...")

        // Perform heavy work on background actor
        let result = try await backgroundActor.initialize()

        // Update UI state on MainActor
        self.cachedResult = result
        self.lastUpdateTime = Date()
        self.isInitialized = true

        logger.info("✅ PowerSense monitor initialized with \(result.clusters.count) clusters")
    }

    /// Start 60-second event polling loop (background)
    func startMonitoring() {
        logger.info("▶️ Starting PowerSense event polling (60s interval, background)")
        Task {
            await backgroundActor.startMonitoring { [weak self] result in
                Task { @MainActor in
                    self?.cachedResult = result
                    self?.lastUpdateTime = Date()
                }
            }
        }
    }

    /// Stop event polling loop
    func stopMonitoring() {
        logger.info("⏹️ Stopping PowerSense event polling")
        Task {
            await backgroundActor.stopMonitoring()
        }
    }

    /// Force refresh of cached clusters (manual refresh, background)
    func refreshClusters() async throws {

        // Perform heavy work on background actor
        let result = try await backgroundActor.refreshClusters()

        // Update UI state on MainActor
        self.cachedResult = result
        self.lastUpdateTime = Date()

        logger.info("✅ Cache refreshed: \(result.clusters.count) clusters")
    }

    /// Get cached result if valid (synchronous, MainActor)
    func getCachedResultIfValid() -> ClusterResult? {
        return cachedResult
    }
}

// MARK: - Background Actor

/// Actor for performing heavy PowerSense work off the main thread
actor BackgroundMonitorActor {

    private let clusteringService: ClusteringService
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "pulse", category: "powerSenseBackgroundActor")

    // State
    private var currentOfflineDeviceIds: Set<String> = []
    private var pollingTask: Task<Void, Never>?

    // Metrics
    private var pollCount = 0
    private var reclusterCount = 0

    init(clusteringService: ClusteringService, modelContainer: ModelContainer) {
        self.clusteringService = clusteringService
        self.modelContainer = modelContainer
    }

    /// Initialize: run 10-minute verification cycle, then perform clustering
    func initialize() async throws -> ClusterResult {
        guard await isConfiguredAndEnabled() else {
            logger.debug("⏭️ Skipping initialization: not configured/enabled")
            throw PowerSenseMonitorError.notConfigured
        }

        logger.info("🔧 Initializing PowerSense monitor (background thread)...")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Step 1: Run 10-minute verification cycle on boot
        logger.info("🔍 Running initial 10-minute verification cycle...")
        try await verifyActiveEventsWithEventGet()

        // Step 2: Perform initial clustering (GPU/CPU work on background)
        logger.info("🔧 Performing initial clustering...")
        let result = try await clusteringService.clusterDevices()

        // Step 3: Track offline device set
        currentOfflineDeviceIds = Set(
            result.clusters.flatMap { $0.devices }
                .filter { $0.isOffline == true }
                .map { $0.deviceId }
        )

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("✅ Initialization complete in \(String(format: "%.1f", duration))s (\(self.currentOfflineDeviceIds.count) offline devices)")

        return result
    }

    /// Start polling loop (background)
    func startMonitoring(onUpdate: @escaping @Sendable (ClusterResult) -> Void) {
        guard pollingTask == nil else { return }

        pollingTask = Task {
            while !Task.isCancelled {
                await pollEvents(onUpdate: onUpdate)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Stop polling loop
    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Refresh clusters (background)
    func refreshClusters() async throws -> ClusterResult {
        guard await isConfiguredAndEnabled() else {
            throw PowerSenseMonitorError.notConfigured
        }

        let result = try await clusteringService.clusterDevices()

        // Update offline tracking
        currentOfflineDeviceIds = Set(
            result.clusters.flatMap { $0.devices }
                .filter { $0.isOffline == true }
                .map { $0.deviceId }
        )

        reclusterCount += 1
        logger.info("✅ Cluster refresh complete: \(result.clusters.count) clusters")

        return result
    }

    // MARK: - Private Methods

    /// Poll events and trigger re-clustering if needed (background)
    private func pollEvents(onUpdate: @escaping @Sendable (ClusterResult) -> Void) async {
        guard await isConfiguredAndEnabled() else {
            logger.debug("⏭️ Skipping poll: not configured/enabled")
            return
        }

        logger.debug("⏰ Polling PowerSense events (background)...")
        pollCount += 1

        do {
            // Step 1: Fetch ALL problems (recent=true includes resolved)
            let problems = try await fetchPowerSenseProblems()
            logger.debug("📊 Fetched \(problems.count) problems from Zabbix")

            // Step 2: Process problems with two-phase approach
            try await processProblemsTwoPhase(problems)

            // Step 3: Every 10th poll, verify active events
            if pollCount % 10 == 0 {
                try await verifyActiveEventsWithEventGet()
            }

            // Step 4: Check if offline device count changed
            let changed = try await hasOfflineSetChanged()

            if changed {
                logger.info("🔄 Offline device count changed - re-clustering (background)...")
                let result = try await clusteringService.clusterDevices()

                // Update tracking
                currentOfflineDeviceIds = Set(
                    result.clusters.flatMap { $0.devices }
                        .filter { $0.isOffline == true }
                        .map { $0.deviceId }
                )

                reclusterCount += 1

                // Notify UI with full result (MainActor update)
                onUpdate(result)

                logger.info("✅ Re-clustering complete: \(result.clusters.count) clusters")
            } else {
                logger.debug("✅ No changes detected - cache still valid")
            }

            // Log metrics every 10 polls
            if pollCount % 10 == 0 {
                logger.info("📊 Metrics: \(self.pollCount) polls, \(self.reclusterCount) re-clusters")
            }

        } catch {
            logger.error("❌ Event polling failed: \(error.localizedDescription)")
        }
    }

    /// Two-phase problem processing: problem.get + event.get for new events
    private func processProblemsTwoPhase(_ problems: [PowerSenseEventProperties]) async throws {
        let modelContext = ModelContext(modelContainer)

        // Step 1: Filter valid problems (must have ONT device name)
        let validProblems = problems.filter { $0.ontDeviceName != nil }
        let discardedInvalidCount = problems.count - validProblems.count
        if discardedInvalidCount > 0 {
            logger.info("⚠️ Discarded \(discardedInvalidCount) problems with invalid ONT names")
        }

        // Step 2: Fetch existing events
        let eventIds = validProblems.map { $0.eventId }
        let existingEvents = try modelContext.fetch(
            FetchDescriptor<PowerSenseEvent>(
                predicate: #Predicate { eventIds.contains($0.eventId) }
            )
        )
        let existingDict = Dictionary(uniqueKeysWithValues: existingEvents.map { ($0.eventId, $0) })

        // Step 3: Categorize problems
        var newEventIds: [String] = []
        var updateCount = 0
        var ignoreCount = 0

        for problem in validProblems {
            if let existingEvent = existingDict[problem.eventId] {
                // Existing event - update if r_clock changed
                if let newResolvedAt = problem.resolvedAt, existingEvent.resolvedAt != newResolvedAt {
                    existingEvent.resolvedAt = newResolvedAt
                    updateCount += 1
                } else {
                    ignoreCount += 1
                }
            } else {
                // New event - needs device linking
                newEventIds.append(problem.eventId)
            }
        }

        // Step 3.5: Purge stale active events (not in problem.get results)
        let problemEventIds = Set(validProblems.map { $0.eventId })
        let allActiveEvents = try modelContext.fetch(
            FetchDescriptor<PowerSenseEvent>(
                predicate: #Predicate { $0.resolvedAt == nil }
            )
        )

        var staleCount = 0
        for activeEvent in allActiveEvents {
            if !problemEventIds.contains(activeEvent.eventId) {
                // Event is active in DB but not in problem.get → resolved
                activeEvent.resolvedAt = Date()
                staleCount += 1
            }
        }

        if staleCount > 0 {
            logger.info("🧹 Purged \(staleCount) stale events (not in problem.get)")
        }

        logger.info("""
        📊 Problem categorization:
        - New events: \(newEventIds.count)
        - Updated (r_clock): \(updateCount)
        - Ignored (no change): \(ignoreCount)
        - Stale (purged): \(staleCount)
        - Discarded (invalid name): \(discardedInvalidCount)
        """)

        // Step 4: For new events, fetch full details via event.get to get hostId
        if !newEventIds.isEmpty {
            try await linkNewEventsViaEventGet(newEventIds, validProblems: validProblems, modelContext: modelContext)
        }

        // Step 5: Save changes
        if updateCount > 0 || !newEventIds.isEmpty || staleCount > 0 {
            try modelContext.save()
            logger.info("✅ Problem sync saved: \(newEventIds.count) new, \(updateCount) updated, \(staleCount) purged")
        } else {
            logger.debug("✅ No changes to save")
        }
    }

    /// Link new events to devices using event.get API (provides hostId)
    private func linkNewEventsViaEventGet(_ eventIds: [String], validProblems: [PowerSenseEventProperties], modelContext: ModelContext) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()

        logger.debug("Linking \(eventIds.count) NEW events to devices")

        // Batch into 1K chunks to avoid Zabbix parameter limits
        let batches = eventIds.chunked(into: 1000)
        var allDetailedEvents: [PowerSenseEventProperties] = []

        for (index, batch) in batches.enumerated() {
            logger.debug("Fetching NEW event batch \(index + 1)/\(batches.count) (\(batch.count) events)")
            let batchEvents = try await fetchPowerSenseEvents(eventIds: batch)
            allDetailedEvents.append(contentsOf: batchEvents)
        }

        let fetchDuration = CFAbsoluteTimeGetCurrent() - startTime
        logger.debug("⏱️ Fetched \(allDetailedEvents.count) events in \(String(format: "%.2f", fetchDuration))s (\(batches.count) batch(es))")

        // Build lookup
        let detailedEventsDict = Dictionary(uniqueKeysWithValues: allDetailedEvents.map { ($0.eventId, $0) })

        // Pre-fetch devices by zabbixHostId
        let allDevices = try modelContext.fetch(FetchDescriptor<PowerSenseDevice>())
        let devicesByHostId: [String: PowerSenseDevice] = Dictionary(uniqueKeysWithValues:
            allDevices.compactMap { device -> (String, PowerSenseDevice)? in
                guard let hostId = device.zabbixHostId else { return nil }
                return (hostId, device)
            }
        )

        // Create problem lookup
        let problemDict = Dictionary(uniqueKeysWithValues: validProblems.map { ($0.eventId, $0) })

        var linkedCount = 0
        var unlinkedCount = 0
        var insertCount = 0
        var missingFromEventGet = 0

        for eventId in eventIds {
            guard let problem = problemDict[eventId] else { continue }

            guard let detailedEvent = detailedEventsDict[eventId] else {
                missingFromEventGet += 1
                continue
            }

            // Create new event
            let newEvent = PowerSenseEvent(eventId: eventId, timestamp: problem.timestamp)
            newEvent.resolvedAt = problem.resolvedAt

            // Link to device via hostId
            if let hostId = detailedEvent.primaryHostId,
               let device = devicesByHostId[hostId] {
                newEvent.device = device
                linkedCount += 1
            } else {
                unlinkedCount += 1
            }

            modelContext.insert(newEvent)
            insertCount += 1
        }

        logger.info("""
        🔗 event.get linking complete:
        - Inserted: \(insertCount) events
        - Linked to devices: \(linkedCount)
        - Unlinked (no hostId/device): \(unlinkedCount)
        - Missing from event.get: \(missingFromEventGet)
        """)
    }

    /// Verify active events with problem.get (10-minute deep check)
    private func verifyActiveEventsWithEventGet() async throws {
        let modelContext = ModelContext(modelContainer)
        let startTime = CFAbsoluteTimeGetCurrent()

        logger.info("🔍 Running 10-minute deep verification with problem.get")

        // Fetch all active events (resolvedAt == nil)
        let activeEvents = try modelContext.fetch(
            FetchDescriptor<PowerSenseEvent>(
                predicate: #Predicate { $0.resolvedAt == nil }
            )
        )

        guard !activeEvents.isEmpty else {
            logger.debug("No active events to verify")
            return
        }

        logger.info("Verifying \(activeEvents.count) active events with Zabbix via problem.get")

        // Fetch all current problems from Zabbix (recent=true includes active + recently resolved)
        let problems = try await fetchPowerSenseProblems()

        // Filter valid problems
        let validProblems = problems.filter { $0.ontDeviceName != nil }
        let problemDict = Dictionary(uniqueKeysWithValues: validProblems.map { ($0.eventId, $0) })

        // Update resolutions
        var resolvedCount = 0
        var missingCount = 0
        var updatedCount = 0

        for activeEvent in activeEvents {
            if let problem = problemDict[activeEvent.eventId] {
                // Event found in problem.get
                if let resolvedAt = problem.resolvedAt, activeEvent.resolvedAt == nil {
                    // Event resolved in Zabbix - update DB with r_clock
                    activeEvent.resolvedAt = resolvedAt
                    resolvedCount += 1
                    updatedCount += 1
                }
                // else: still active in both DB and Zabbix (no change)
            } else {
                // Event not in problem.get results - must be resolved/stale
                activeEvent.resolvedAt = Date()
                resolvedCount += 1
                missingCount += 1
            }
        }

        if updatedCount > 0 {
            try modelContext.save()
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("""
        ✅ Deep verification complete in \(String(format: "%.2f", duration))s:
        - Verified: \(activeEvents.count) active events
        - Zabbix problems: \(validProblems.count)
        - Resolved with r_clock: \(resolvedCount - missingCount) events
        - Stale (force-resolved): \(missingCount) events
        """)
    }

    /// Check if offline device set has changed (background, SwiftData fetch)
    private func hasOfflineSetChanged() async throws -> Bool {
        let modelContext = ModelContext(modelContainer)

        // Fetch all devices (background thread - safe for SwiftData read)
        let descriptor = FetchDescriptor<PowerSenseDevice>()
        let devices = try modelContext.fetch(descriptor)

        // Count offline devices
        let newOfflineDeviceIds = Set(
            devices.filter { $0.isOffline == true }
                .map { $0.deviceId }
        )

        let oldCount = currentOfflineDeviceIds.count
        let newCount = newOfflineDeviceIds.count

        if newCount != oldCount {
            logger.info("📊 Offline device count changed: \(oldCount) → \(newCount)")
            currentOfflineDeviceIds = newOfflineDeviceIds
            return true
        }

        return false
    }

    /// Sync events to SwiftData (used for boot initialization)
    private func syncEventsToSwiftData(_ events: [PowerSenseEventProperties]) async throws {
        guard !events.isEmpty else { return }

        let modelContext = ModelContext(modelContainer)
        let startTime = Date()

        logger.debug("🚀 Starting event sync for \(events.count) events")

        // Bulk fetch existing events
        let eventIds = events.map { $0.eventId }
        let existingEvents = try modelContext.fetch(
            FetchDescriptor<PowerSenseEvent>(
                predicate: #Predicate { eventIds.contains($0.eventId) }
            )
        )
        let existingDict = Dictionary(uniqueKeysWithValues: existingEvents.map { ($0.eventId, $0) })

        logger.debug("📊 Found \(existingEvents.count) existing events")

        // Create properties lookup
        let propertiesDict = Dictionary(uniqueKeysWithValues: events.map { ($0.eventId, $0) })

        // Update existing
        var updateCount = 0
        for (eventId, event) in existingDict {
            if let properties = propertiesDict[eventId] {
                event.resolvedAt = properties.resolvedAt
                updateCount += 1
            }
        }

        logger.debug("✅ Updated \(updateCount) existing events")

        // Pre-fetch devices by zabbixHostId for O(1) linking
        let allDevices = try modelContext.fetch(FetchDescriptor<PowerSenseDevice>())
        let devicesByHostId: [String: PowerSenseDevice] = Dictionary(uniqueKeysWithValues:
            allDevices.compactMap { device -> (String, PowerSenseDevice)? in
                guard let hostId = device.zabbixHostId else { return nil }
                return (hostId, device)
            }
        )

        // Insert new events with device linking via hostId
        let newEventIds = Set(eventIds).subtracting(existingDict.keys)
        var insertCount = 0
        var linkedCount = 0

        for eventId in newEventIds {
            if let properties = propertiesDict[eventId] {
                let newEvent = PowerSenseEvent(eventId: eventId, timestamp: properties.timestamp)
                newEvent.resolvedAt = properties.resolvedAt

                // Link to device via hostId (event.get provides this)
                if let hostId = properties.primaryHostId,
                   let device = devicesByHostId[hostId] {
                    newEvent.device = device
                    linkedCount += 1
                }

                modelContext.insert(newEvent)
                insertCount += 1
            }
        }

        logger.debug("✅ Inserted \(insertCount) new events (\(linkedCount) linked to devices)")

        // Save
        try modelContext.save()

        let duration = Date().timeIntervalSince(startTime)
        logger.info("""
        📝 Event sync complete in \(String(format: "%.2f", duration))s:
        - Processed: \(events.count) events
        - Updated: \(updateCount) events
        - Inserted: \(insertCount) events
        """)
    }

    // MARK: - API Helper Methods

    /// Fetch PowerSense events via event.get (includes hostId for device linking)
    private func fetchPowerSenseEvents(timeFrom: Date? = nil, eventIds: [String]? = nil) async throws -> [PowerSenseEventProperties] {
        if let eventIds = eventIds {
            logger.debug("Fetching \(eventIds.count) specific PowerSense events via event.get (eventids filter)")
        } else {
            logger.debug("Fetching PowerSense events via event.get")
        }

        let resource = PowerSenseEventResource(eventIds: eventIds, timeFrom: timeFrom)
        let request = try await resource.request
        let (data, _) = try await URLSession.shared.data(for: request)

        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let result = jsonObject["result"] as? [[String: Any]] {
            let jsonData = try JSONSerialization.data(withJSONObject: result)
            let events = try JSONDecoder().decode([PowerSenseEventProperties].self, from: jsonData)
            logger.debug("Successfully fetched \(events.count) PowerSense events")
            return events.filter { $0.isValid }
        } else if let error = jsonObject["error"] as? [String: Any],
                  let message = error["message"] as? String {
            logger.error("PowerSense event.get error: \(message)")
            throw PowerSenseZabbixError.authenticationFailed(message)
        }

        logger.warning("PowerSense event.get returned no results")
        return []
    }

    /// Fetch PowerSense problems via problem.get (recent=true for active + recently resolved)
    private func fetchPowerSenseProblems() async throws -> [PowerSenseEventProperties] {
        logger.debug("Fetching PowerSense problems via problem.get")

        let resource = PowerSenseProblemsResource()
        let request = try await resource.request
        let (data, _) = try await URLSession.shared.data(for: request)

        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let result = jsonObject["result"] as? [[String: Any]] {
            let jsonData = try JSONSerialization.data(withJSONObject: result)
            let problems = try JSONDecoder().decode([PowerSenseEventProperties].self, from: jsonData)
            logger.debug("Successfully fetched \(problems.count) PowerSense problems")
            return problems.filter { $0.isValid }
        } else if let error = jsonObject["error"] as? [String: Any],
                  let message = error["message"] as? String {
            logger.error("PowerSense problem.get error: \(message)")
            throw PowerSenseZabbixError.authenticationFailed(message)
        }

        logger.warning("PowerSense problem.get returned no results")
        return []
    }

    /// Check if PowerSense is configured and enabled
    private func isConfiguredAndEnabled() async -> Bool {
        let config = await Configuration.shared
        let configured = await config.isPowerSenseConfigured()
        let enabled = await config.isPowerSenseEnabled()
        return configured && enabled
    }
}

// MARK: - Errors

enum PowerSenseMonitorError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "PowerSense is not configured or enabled"
        }
    }
}
