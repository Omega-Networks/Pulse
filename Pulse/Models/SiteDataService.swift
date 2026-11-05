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
        OperatorNoticeCenter.shared.clear(id: OperatorNotice.zabbixStatusID)
    }

    /// Deletes every stored event and clears the severity those rows had
    /// written. Squares read the stored ints, so a host stays lit until
    /// this write. One context, one save. Returns false when the save fails.
    func deleteAllEvents() async -> Bool {
        let logger = Logger(subsystem: "zabbix", category: "eventProcessing")
        do {
            let context = makeContext()
            let events = try context.fetch(FetchDescriptor<Event>())
            var devices = Set<Device>()
            var hostIds = Set<Int64>()
            for event in events {
                if let device = event.device {
                    devices.insert(device)
                }
                if event.hostId != 0 {
                    hostIds.insert(event.hostId)
                }
                context.delete(event)
            }
            for batch in chunk(array: Array(hostIds), size: 200) {
                let ids = batch
                let fetched = try context.fetch(
                    FetchDescriptor<Device>(
                        predicate: #Predicate<Device> { device in
                            ids.contains(device.zabbixId)
                        }
                    )
                )
                for device in fetched {
                    devices.insert(device)
                }
            }
            var siteIds = Set<Int64>()
            for device in devices {
                let cleared = device.zabbixId == 0 ? ActiveSeverity.unmonitored : ActiveSeverity()
                device.assignActiveSeverity(cleared)
                if device.siteId != 0 {
                    siteIds.insert(device.siteId)
                } else if let site = device.site {
                    siteIds.insert(site.id)
                }
            }
            for batch in chunk(array: Array(siteIds), size: 200) {
                let ids = batch
                let sites = try context.fetch(
                    FetchDescriptor<Site>(
                        predicate: #Predicate<Site> { site in
                            ids.contains(site.id)
                        }
                    )
                )
                for site in sites {
                    site.refreshSeverityFromDevices()
                }
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            logger.error("Failed to delete events: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @MainActor
    private static func publishZabbixFailure(_ error: Error) {
        let status = ZabbixError.status(from: error)
        RequestStatusManager.shared.updateStatus(.zabbix, status)
        if let notice = OperatorNotice.fromZabbix(status) {
            OperatorNoticeCenter.shared.post(notice)
        }
    }

    /// Zabbix items for this site. Racks, fillers, bays, interfaces, and
    /// cables live in SwiftData from the boot / Settings full sync.
    func loadAllSiteData(for siteId: Int64) async throws {
        do {
            try await getItems(for: siteId)
            await MainActor.run { Self.dismissZabbixWarningIfNeeded() }
        } catch {
            await MainActor.run { Self.publishZabbixFailure(error) }
            throw error
        }
    }
    
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

        let config = await Configuration.shared
        guard await config.isZabbixReady() else {
            logger.debug("Zabbix not configured; skipping problem sync")
            return
        }

        logger.debug("Starting problem sync process")

        do {
            if let eventIds = eventIds {
                logger.debug("Fetching specific events: \(eventIds)")
                let decoded = try await fetchHostProblems(eventIds: eventIds)
                let inserted = try await applyProblems(decoded.items, deleteAbsent: false)
                if !inserted.isEmpty {
                    await getEvents(using: inserted)
                }
            } else if let hostIds = hostIds {
                logger.debug("Fetching problems for hosts: \(hostIds)")
                let decoded = try await fetchHostProblems(hostIds: hostIds)
                let inserted = try await applyProblems(decoded.items, deleteAbsent: false)
                if !inserted.isEmpty {
                    await getEvents(using: inserted)
                }
            } else {
                // Full sync. Host ids are paged and that context is gone
                // before the network calls. `recent: true` returns the
                // open problems for every stored host and the recently
                // resolved ones. A complete pull deletes stale ids on
                // the write context. `skipped != 0` skips the delete.
#if DEBUG
                let started = ContinuousClock.now
                defer {
                    logger.info("timing getProblems \(netBoxTimingMilliseconds(since: started))ms")
                }
#endif
                let zabbixIds = try pagedZabbixHostIds()
                logger.debug("Found \(zabbixIds.count) devices to process")

                let batches = chunk(array: zabbixIds, size: batchSize)
                logger.debug("Created \(batches.count) batches of size \(batchSize)")

                let parts = try await mapZabbixBatchesCapped(batches) { index, batch in
                    logger.debug("Processing problem batch \(index + 1)/\(batches.count)")
                    return try await fetchHostProblems(hostIds: batch)
                }
                var items: [EventProperties] = []
                var skipped = 0
                for part in parts {
                    items.append(contentsOf: part.items)
                    skipped += part.skipped
                }
                if skipped != 0 {
                    logger.debug("Skipping stale-event delete; skipped=\(skipped)")
                }
                let inserted = try await applyProblems(items, deleteAbsent: skipped == 0)
                if !inserted.isEmpty {
                    await getEvents(using: inserted)
                }
            }

            logger.debug("Problem sync process completed successfully")
            await MainActor.run { Self.dismissZabbixWarningIfNeeded() }

        } catch {
            logger.error("Failed to get problems: \(error.localizedDescription)")
            await MainActor.run { Self.publishZabbixFailure(error) }
        }
    }

    /// Writes one pull on one context and saves once. Returns the ids of
    /// rows that were inserted. The caller maps those through `getEvents`,
    /// which is a network call and must see the saved insert. A quiet pull
    /// still stamps `lastZabbixUpdate`, so that one row saves even when no
    /// event changed.
    private func applyProblems(
        _ eventPropertiesList: [EventProperties],
        deleteAbsent: Bool
    ) async throws -> [String] {
        let logger = Logger(subsystem: "zabbix", category: "eventProcessing")
        let context = makeContext()
        logger.debug("Starting to process \(eventPropertiesList.count) events")

        // Last-wins. `uniqueKeysWithValues` traps in Release when
        // problem.get returns the same eventid twice (duplicate zabbix
        // host ids, overlapping batches, or a trigger on more than one
        // host).
        let propertiesDict = Dictionary(
            eventPropertiesList.map { ($0.eventId, $0) },
            uniquingKeysWith: { _, last in last }
        )
        if propertiesDict.count != eventPropertiesList.count {
            logger.debug(
                "Collapsed \(eventPropertiesList.count - propertiesDict.count) duplicate problem rows"
            )
        }

        let existingEventsDict = try eventsById(Array(propertiesDict.keys), in: context)
        logger.debug("Fetched \(existingEventsDict.count) existing events")

        var changedEvents: [Event] = []
        var updateCount = 0
        for (eventId, event) in existingEventsDict {
            if let properties = propertiesDict[eventId], event.update(with: properties) {
                changedEvents.append(event)
                updateCount += 1
            }
        }
        logger.debug("Updated \(updateCount) events")

        var insertedEventIds: [String] = []
        let newEventIds = Set(propertiesDict.keys).subtracting(existingEventsDict.keys)
        for eventId in newEventIds {
            guard let properties = propertiesDict[eventId] else { continue }
            let event = Event(eventId: eventId)
            event.update(with: properties)
            context.insert(event)
            insertedEventIds.append(eventId)
        }
        logger.debug("Inserted \(insertedEventIds.count) new events")

        var staleDeviceIds: [Int64] = []
        if deleteAbsent {
            logger.debug("Cleaning up old events")
            let stale = try staleProblemRows(absentFrom: Set(propertiesDict.keys))
            staleDeviceIds = stale.deviceIds
            for batch in chunk(array: stale.eventIds, size: 200) {
                let batchIds = batch
                try context.delete(
                    model: Event.self,
                    where: #Predicate<Event> { event in
                        batchIds.contains(event.eventId)
                    }
                )
            }
        }

        if !changedEvents.isEmpty || !staleDeviceIds.isEmpty {
            try refreshApplied(
                events: changedEvents,
                staleDeviceIds: staleDeviceIds,
                in: context
            )
        }

        try stampZabbixUpdate(in: context)
        if context.hasChanges {
#if DEBUG
            let started = ContinuousClock.now
#endif
            try context.save()
#if DEBUG
            Logger(subsystem: "zabbix", category: "problemSync")
                .info("timing problemSave \(netBoxTimingMilliseconds(since: started))ms")
#endif
            logger.debug("Successfully saved context")
        }
        return insertedEventIds
    }
    
    func getEvents(using eventIds: [String]? = nil, deviceIds: [String]? = nil) async {
        let logger = Logger(subsystem: "zabbix", category: "eventSync")
        let batchSize = 200

        logger.debug("Starting event sync process")

        do {
            // Host ids for the API. The context that reads them ends
            // before the network call. `deviceIds` are NetBox ids.
            let apiParameters: [String]
            if let eventIds {
                apiParameters = eventIds
            } else if let deviceIds {
                logger.debug("Fetching events for specific devices: \(deviceIds)")
                apiParameters = try zabbixHostIds(forDeviceIds: deviceIds)
            } else {
                logger.debug("Performing full event sync")
                apiParameters = try pagedZabbixHostIds()
            }

            let batches = chunk(array: apiParameters, size: batchSize)
            logger.debug("Created \(batches.count) batches for processing")

            let mapped = try await mapZabbixBatchesCapped(batches) { index, batch in
                logger.debug("Processing event batch \(index + 1)/\(batches.count)")
                let decoded = try await fetchHostEvents(
                    hostIds: eventIds == nil ? batch : nil,
                    eventIds: eventIds != nil ? batch : nil
                )
                return decoded.items.flatMap { event in
                    event.hostIds.map { hostId in (hostId, [event]) }
                }
            }

            let context = makeContext()
#if DEBUG
            let started = ContinuousClock.now
            defer {
                logger.info("timing eventSave \(netBoxTimingMilliseconds(since: started))ms")
            }
#endif
            var responseEventIds: [String] = []
            var responseHostIds: [String] = []
            var seenEventIds = Set<String>()
            var seenHostIds = Set<String>()
            for batchResults in mapped {
                for (hostId, events) in batchResults {
                    if seenHostIds.insert(hostId).inserted {
                        responseHostIds.append(hostId)
                    }
                    for event in events where seenEventIds.insert(event.eventId).inserted {
                        responseEventIds.append(event.eventId)
                    }
                }
            }

            var stored = try self.eventsById(responseEventIds, in: context)
            let devicesByHost = try devicesByZabbixId(responseHostIds, in: context)
            var changed: [Event] = []
            for batchResults in mapped {
                for (hostId, events) in batchResults {
                    guard let device = devicesByHost[hostId] else { continue }
                    for eventProperty in events {
                        let searchEventId = eventProperty.eventId
                        let event: Event
                        let wrote: Bool
                        if let existing = stored[searchEventId] {
                            event = existing
                            wrote = existing.update(with: eventProperty, device: device)
                        } else {
                            event = Event(eventId: searchEventId)
                            event.update(with: eventProperty, device: device)
                            context.insert(event)
                            stored[searchEventId] = event
                            wrote = true
                        }
                        let stamped = event.stampHostIdIfMissing(from: device)
                        if wrote || stamped {
                            changed.append(event)
                        }
                    }
                }
            }
            if !changed.isEmpty {
                var devices: [Device] = []
                var seen = Set<Int64>()
                for event in changed {
                    if event.hostId != 0,
                       let device = devicesByHost[String(event.hostId)],
                       seen.insert(device.id).inserted {
                        devices.append(device)
                    }
                    if let device = event.device, seen.insert(device.id).inserted {
                        devices.append(device)
                    }
                }
                try storeActiveCounts(on: devices, in: context)
            }
            if context.hasChanges {
                try context.save()
            }

            logger.debug("Event sync completed successfully")

        } catch {
            logger.error("Failed to sync events: \(error.localizedDescription)")
        }
    }

    /// Stamps the freshness row on the context that is about to save.
    /// A new `Date` dirties that one row even when no event changed.
    private func stampZabbixUpdate(in context: ModelContext) throws {
        if let syncProvider = try context.fetch(FetchDescriptor<SyncProvider>()).first {
            syncProvider.lastZabbixUpdate = Date()
        }
    }

    private func mapZabbixBatchesCapped<Out: Sendable>(
        _ batches: [[String]],
        operation: @escaping @Sendable (Int, [String]) async throws -> Out
    ) async throws -> [Out] {
        let maxInFlight = 4
        let maxRetries = 3
        return try await withThrowingTaskGroup(of: Out.self) { group in
            var iterator = batches.enumerated().makeIterator()
            func submitNext() {
                guard let (index, batch) = iterator.next() else { return }
                group.addTask {
                    var lastError: Error?
                    for attempt in 1...maxRetries {
                        do {
                            return try await operation(index, batch)
                        } catch {
                            lastError = error
                            if attempt < maxRetries {
                                try await Task.sleep(
                                    nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                                )
                            }
                        }
                    }
                    throw lastError ?? ZabbixError.unreachable
                }
            }
            for _ in 0..<min(maxInFlight, batches.count) {
                submitNext()
            }
            var results: [Out] = []
            while let value = try await group.next() {
                results.append(value)
                submitNext()
            }
            return results
        }
    }

    /// Nil-events walk. Boot calls it after the NetBox sync. So does
    /// `NetBoxSyncEngine.refreshTouchedSites`. The walk was ~8s at 12K
    /// devices. A full problem sync does not call it. This stamps
    /// `siteId` on historical rows, and `hostId` where it is still 0.
    /// That host stamp is a one-time migration for rows written before
    /// the field was filled.
    func refreshSeverities() async {
        let context = makeContext()
        let devices = (try? context.fetch(FetchDescriptor<Device>())) ?? []
        for device in devices {
            device.refreshSeverityFromEvents()
        }
        let sites = (try? context.fetch(FetchDescriptor<Site>())) ?? []
        for site in sites {
            site.refreshSeverityFromDevices()
        }
        do {
            try context.save()
        } catch {
            Logger(subsystem: "zabbix", category: "problemSync")
                .error("Severity backfill save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Host ids for the full pull. Each page starts after the last device
    /// id, so a later page does not re-read the rows before it. The context
    /// ends with this function, before any network call.
    func pagedZabbixHostIds() throws -> [String] {
        let context = makeContext()
        var ids: [String] = []
        var seen = Set<String>()
        var lastId = Int64.min
        let pageSize = 200
        while true {
            let after = lastId
            var descriptor = FetchDescriptor<Device>(
                predicate: #Predicate<Device> { device in
                    device.zabbixId != 0 && device.id > after
                },
                sortBy: [SortDescriptor(\Device.id, order: .forward)]
            )
            descriptor.fetchLimit = pageSize
            let page = try context.fetch(descriptor)
            if page.isEmpty { break }
            for device in page {
                let id = String(device.zabbixId)
                if seen.insert(id).inserted {
                    ids.append(id)
                }
            }
            lastId = page[page.count - 1].id
            if page.count < pageSize { break }
        }
        return ids
    }

    /// Event ids absent from the pull, and the device id of a stale row
    /// whose `hostId` names a stored device. The fetch reads each stored
    /// event. `hostId == 0` does not name a device.
    private func staleProblemRows(absentFrom currentEventIds: Set<String>) throws -> (eventIds: [String], deviceIds: [Int64]) {
#if DEBUG
        let started = ContinuousClock.now
        defer {
            Logger(subsystem: "zabbix", category: "problemSync")
                .info("timing staleProblemRows \(netBoxTimingMilliseconds(since: started))ms")
        }
#endif
        let context = makeContext()
        let rows = try context.fetch(FetchDescriptor<Event>())
        var eventIds: [String] = []
        var hostIds = Set<Int64>()
        for event in rows where !currentEventIds.contains(event.eventId) {
            eventIds.append(event.eventId)
            if event.hostId != 0 {
                hostIds.insert(event.hostId)
            }
        }
        let devices = try devicesByZabbixId(hostIds.map(String.init), in: context)
        return (eventIds, devices.values.map(\.id))
    }

    /// Devices whose rows changed, plus devices that lost a stale row,
    /// refreshed once after the delete so a deleted event is already gone.
    /// Counts come from the open rows for those Zabbix hosts. Inserted
    /// rows are not here; `getEvents` links them and refreshes.
    private func refreshApplied(
        events: [Event],
        staleDeviceIds: [Int64],
        in context: ModelContext
    ) throws {
        var hostIds: [Int64] = []
        var seenHost = Set<Int64>()
        for event in events where event.hostId != 0 && seenHost.insert(event.hostId).inserted {
            hostIds.append(event.hostId)
        }
        var devices = Array(try devicesByZabbixId(hostIds.map(String.init), in: context).values)
        var seen = Set(devices.map(\.id))
        for event in events {
            if let device = event.device, seen.insert(device.id).inserted {
                devices.append(device)
            }
        }
        for batch in chunk(array: staleDeviceIds, size: 200) {
            let ids = batch
            let fetched = try context.fetch(
                FetchDescriptor<Device>(
                    predicate: #Predicate<Device> { device in
                        ids.contains(device.id)
                    }
                )
            )
            for device in fetched where seen.insert(device.id).inserted {
                devices.append(device)
            }
        }
        try storeActiveCounts(on: devices, in: context)
    }

    /// Open rows for these devices, counted by `hostId`. An open row
    /// still at `hostId == 0` is stamped from the device it is linked to
    /// before the count. History is not walked. Site ints are then read
    /// from the stored device counts.
    private func storeActiveCounts(on devices: [Device], in context: ModelContext) throws {
        guard !devices.isEmpty else { return }
        for device in devices where device.zabbixId == 0 {
            device.assignActiveSeverity(.unmonitored)
        }
        let monitored = devices.filter { $0.zabbixId != 0 }
        try stampMissingHostIds(on: monitored, in: context)
        var tally: [Int64: ActiveSeverity] = [:]
        for batch in chunk(array: Array(Set(monitored.map(\.zabbixId))), size: 200) {
            let ids = batch
            let descriptor = FetchDescriptor<Event>(
                predicate: #Predicate<Event> { event in
                    event.rClock == "0" && event.suppressed == "0" && ids.contains(event.hostId)
                }
            )
            for event in try context.fetch(descriptor) {
                var next = tally[event.hostId] ?? ActiveSeverity()
                next.observe(severity: event.severity, acknowledged: event.acknowledged)
                tally[event.hostId] = next
            }
        }
        var siteIds = Set<Int64>()
        for device in devices {
            if device.zabbixId != 0 {
                device.assignActiveSeverity(tally[device.zabbixId] ?? ActiveSeverity())
            }
            if device.siteId != 0 {
                siteIds.insert(device.siteId)
            } else if let site = device.site {
                siteIds.insert(site.id)
            }
        }
        for batch in chunk(array: Array(siteIds), size: 200) {
            let ids = batch
            let sites = try context.fetch(
                FetchDescriptor<Site>(
                    predicate: #Predicate<Site> { site in
                        ids.contains(site.id)
                    }
                )
            )
            for site in sites {
                site.refreshSeverityFromDevices()
            }
        }
    }

    /// Open problems that `problem.get` stored without a host. The link
    /// already names the device. History is not in this fetch.
    private func stampMissingHostIds(on devices: [Device], in context: ModelContext) throws {
        let byId = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !byId.isEmpty else { return }
        let rows = try context.fetch(
            FetchDescriptor<Event>(
                predicate: #Predicate<Event> { event in
                    event.hostId == 0 && event.rClock == "0" && event.suppressed == "0"
                }
            )
        )
        for event in rows {
            guard let device = event.device, let monitored = byId[device.id] else { continue }
            event.stampHostIdIfMissing(from: monitored)
        }
    }

    private func eventsById(_ ids: [String], in context: ModelContext) throws -> [String: Event] {
        var found: [Event] = []
        for batch in chunk(array: ids, size: 200) {
            let batchIds = batch
            found.append(contentsOf: try context.fetch(
                FetchDescriptor<Event>(
                    predicate: #Predicate<Event> { event in
                        batchIds.contains(event.eventId)
                    }
                )
            ))
        }
        return Dictionary(found.map { ($0.eventId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func devicesByZabbixId(_ ids: [String], in context: ModelContext) throws -> [String: Device] {
        let zabbixIds = Array(Set(ids.compactMap(Int64.init).filter { $0 != 0 }))
        var found: [Device] = []
        for batch in chunk(array: zabbixIds, size: 200) {
            let batchIds = batch
            found.append(contentsOf: try context.fetch(
                FetchDescriptor<Device>(
                    predicate: #Predicate<Device> { device in
                        batchIds.contains(device.zabbixId)
                    }
                )
            ))
        }
        return Dictionary(
            found.map { (String($0.zabbixId), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// NetBox device ids to Zabbix host ids. The context ends here.
    private func zabbixHostIds(forDeviceIds deviceIds: [String]) throws -> [String] {
        let context = makeContext()
        let ids = deviceIds.compactMap(Int64.init)
        var hosts: [String] = []
        var seen = Set<String>()
        for batch in chunk(array: ids, size: 200) {
            let batchIds = batch
            let fetched = try context.fetch(
                FetchDescriptor<Device>(
                    predicate: #Predicate<Device> { device in
                        device.zabbixId != 0 && batchIds.contains(device.id)
                    }
                )
            )
            for device in fetched {
                let host = String(device.zabbixId)
                if seen.insert(host).inserted {
                    hosts.append(host)
                }
            }
        }
        return hosts
    }

    /// Autosave off. A context that saves again as it dies is a second
    /// merge onto the main thread.
    private func makeContext() -> ModelContext {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return context
    }

    private func chunk<T>(array: [T], size: Int) -> [[T]] {
        stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }
}
