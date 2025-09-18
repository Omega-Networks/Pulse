//
//  PowerSenseDataViewer.swift
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

import SwiftUI
import SwiftData
import OSLog
import Foundation

struct PowerSenseDataViewer: View {
    @Environment(\.modelContext) private var modelContext

    private let logger = Logger(subsystem: "powersense", category: "dataViewer")

    // MARK: - Performance Monitoring

    @State private var queryStartTime: Date?
    @State private var queryExecutionTime: TimeInterval = 0
    @State private var deviceQueryTime: TimeInterval = 0
    @State private var eventQueryTime: TimeInterval = 0
    @State private var filteringTime: TimeInterval = 0
    @State private var memoryUsage: Double = 0
    @State private var showDebugOverlay = false

    // MARK: - State Properties

    @State private var deviceCount: Int = 0
    @State private var eventCount: Int = 0
    @State private var isRefreshing = false
    @State private var lastRefreshed: Date?

    // Device filtering and search
    @State private var deviceSearchText = ""
    @State private var selectedDeviceSort: DeviceSortOption = .name

    // Event filtering
    @State private var eventSearchText = ""
    @State private var selectedEventSort: EventSortOption = .timestamp
    @State private var showLast24HoursOnly = true

    // Navigation selection (using Picker instead of nested TabView)
    @State private var selectedView: DataViewerView = .devices

    // MARK: - Apple Best Practice: Efficient @Query with Dynamic Predicates

    // Primary queries with efficient descriptors
    @Query private var devices: [PowerSenseDevice]
    @Query private var events: [PowerSenseEvent]

    // Performance state
    @State private var deviceQuery: FetchDescriptor<PowerSenseDevice>
    @State private var eventQuery: FetchDescriptor<PowerSenseEvent>
    @State private var isInitialized = false

    // Initialize with efficient queries
    init() {
        // Device query with sorting and initial setup
        let deviceDescriptor = FetchDescriptor<PowerSenseDevice>(
            sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)]
        )
        _deviceQuery = State(initialValue: deviceDescriptor)
        _devices = Query(deviceDescriptor)

        // Event query with time-based filtering (last 30 days for performance)
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        let eventDescriptor = FetchDescriptor<PowerSenseEvent>(
            predicate: #Predicate<PowerSenseEvent> { event in
                event.timestamp > thirtyDaysAgo
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        _eventQuery = State(initialValue: eventDescriptor)
        _events = Query(eventDescriptor)
    }

    // MARK: - Main View

    var body: some View {
        VStack(spacing: 16) {
            dataHealthHeader

            VStack(spacing: 0) {
                // Navigation Picker (replaces nested TabView)
                Picker("View", selection: $selectedView) {
                    Text("Devices (\(devices.count))").tag(DataViewerView.devices)
                    Text("Events (\(events.count))").tag(DataViewerView.events)
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 12)

                // Content based on selection
                Group {
                    switch selectedView {
                    case .devices:
                        deviceListView
                    case .events:
                        eventLogView
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: selectedView)
            }
        }
        .padding()
        .overlay(alignment: .topTrailing) {
            if showDebugOverlay {
                debugPerformanceOverlay
                    .padding()
            }
        }
        .task {
            // Initialize queries on first load
            updateDeviceQuery()
            updateEventQuery()
            await initializeWithPerformanceTracking()
        }
        .onAppear {
            startPerformanceMonitoring()
        }
        .onChange(of: deviceSearchText) { _, _ in
            updateDeviceQuery()
        }
        .onChange(of: selectedDeviceSort) { _, _ in
            updateDeviceQuery()
        }
        .onChange(of: eventSearchText) { _, _ in
            updateEventQuery()
        }
        .onChange(of: selectedEventSort) { _, _ in
            updateEventQuery()
        }
        .onChange(of: showLast24HoursOnly) { _, _ in
            updateEventQuery()
        }
        .gesture(
            TapGesture(count: 3)
                .onEnded {
                    showDebugOverlay.toggle()
                }
        )
    }

    // MARK: - Data Health Header

    private var dataHealthHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("PowerSense Data Viewer")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button(action: { Task { await refreshAll() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                }
                .disabled(isRefreshing)
            }

            HStack(spacing: 20) {
                DataHealthCard(
                    title: "Devices",
                    count: deviceCount,
                    icon: "network",
                    color: .blue
                )

                DataHealthCard(
                    title: "Events",
                    count: eventCount,
                    icon: "bolt.circle",
                    color: .orange
                )

                Spacer()

                if let lastRefreshed = lastRefreshed {
                    VStack(alignment: .trailing) {
                        Text("Last Updated")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(lastRefreshed, style: .time)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
        }
        .padding()
        .cornerRadius(8)
    }

    // MARK: - Device List View

    private var deviceListView: some View {
        VStack(spacing: 12) {
            deviceFilters

            if devices.isEmpty {
                emptyDeviceState
            } else {
                deviceList
            }
        }
    }

    private var deviceFilters: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search devices...", text: $deviceSearchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Sort", selection: $selectedDeviceSort) {
                    ForEach(DeviceSortOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Spacer()

                Text("\(devices.count) devices")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }

    private var deviceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(devices, id: \.deviceId) { device in
                PowerSenseDeviceRow(device: device)
                        .padding(.horizontal)
            }
            }
            .padding(.vertical)
        }
    }

    private var emptyDeviceState: some View {
        ContentUnavailableView(
            "No Devices Found",
            systemImage: "network.slash",
            description: Text("No PowerSense devices match your current filters. Try adjusting your search criteria or refresh the data.")
        )
    }

    // MARK: - Event Log View

    private var eventLogView: some View {
        VStack(spacing: 12) {
            eventFilters

            if events.isEmpty {
                emptyEventState
            } else {
                eventList
            }
        }
    }

    private var eventFilters: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search events...", text: $eventSearchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Sort", selection: $selectedEventSort) {
                    ForEach(EventSortOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Toggle("Last 24h Only", isOn: $showLast24HoursOnly)

                Spacer()

                Button("Delete All Events") {
                    Task {
                        await deleteAllEvents()
                    }
                }
                .foregroundColor(.red)

                Text("\(events.count) events")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(events, id: \.eventId) { event in
                EventRow(event: event)
                        .padding(.horizontal)
            }
            }
            .padding(.vertical)
        }
    }

    private var emptyEventState: some View {
        ContentUnavailableView(
            "No Events Found",
            systemImage: "bolt.slash.circle",
            description: Text("No PowerSense events match your current filters. Try adjusting your search criteria or refresh the data.")
        )
    }

    // MARK: - Performance Monitoring Functions

    // MARK: - Dynamic Query Updates (Apple Best Practice)

    private func updateDeviceQuery() {
        let startTime = Date()
        var predicate: Predicate<PowerSenseDevice>?

        // Simple search predicate only
        if !deviceSearchText.isEmpty {
            let searchText = deviceSearchText
            predicate = #Predicate<PowerSenseDevice> { device in
                device.deviceId.contains(searchText)
            }
        }

        // Create sort descriptor
        var sortDescriptors: [SortDescriptor<PowerSenseDevice>]
        switch selectedDeviceSort {
        case .name:
            sortDescriptors = [SortDescriptor(\.name, order: .forward)]
        case .deviceId:
            sortDescriptors = [SortDescriptor(\.deviceId, order: .forward)]
        case .powerStatus:
            sortDescriptors = [SortDescriptor(\.deviceId, order: .forward)] // Use deviceId as fallback
        case .lastUpdated:
            sortDescriptors = [SortDescriptor(\.lastUpdated, order: .reverse)]
        }

        // Create FetchDescriptor
        deviceQuery = FetchDescriptor<PowerSenseDevice>(
            predicate: predicate,
            sortBy: sortDescriptors
        )

        let queryTime = Date().timeIntervalSince(startTime)
        logger.info("📊 Device query updated in \(String(format: "%.3f", queryTime))s")
    }

    private func updateEventQuery() {
        let startTime = Date()
        var predicate: Predicate<PowerSenseEvent>?

        // Simple time-based predicate only
        let timeLimit = showLast24HoursOnly ?
            Date().addingTimeInterval(-24 * 3600) :
            Date().addingTimeInterval(-30 * 24 * 3600)

        predicate = #Predicate<PowerSenseEvent> { event in
            event.timestamp > timeLimit
        }

        // Create sort descriptor
        var sortDescriptors: [SortDescriptor<PowerSenseEvent>]
        switch selectedEventSort {
        case .timestamp:
            sortDescriptors = [SortDescriptor(\.timestamp, order: .reverse)]
        case .eventType:
            sortDescriptors = [SortDescriptor(\.eventId, order: .forward)] // Use eventId as fallback
        case .severity:
            sortDescriptors = [SortDescriptor(\.severity, order: .reverse)]
        }

        // Create FetchDescriptor
        eventQuery = FetchDescriptor<PowerSenseEvent>(
            predicate: predicate,
            sortBy: sortDescriptors
        )

        let queryTime = Date().timeIntervalSince(startTime)
        logger.info("📊 Event query updated in \(String(format: "%.3f", queryTime))s")
    }

    private func startPerformanceMonitoring() {
        let startTime = Date()
        logger.info("📊 PowerSenseDataViewer: Starting performance monitoring")
        logger.info("📊 Device count in query: \(devices.count)")
        logger.info("📊 Event count in query: \(events.count)")

        measureMemoryUsage()

        let initTime = Date().timeIntervalSince(startTime)
        logger.info("📊 Initial view setup completed in \(String(format: "%.3f", initTime))s")
    }

    private func measureQueryPerformance<T>(_ operation: () -> T, label: String) -> (result: T, time: TimeInterval) {
        let startTime = Date()
        let result = operation()
        let executionTime = Date().timeIntervalSince(startTime)
        logger.info("⏱️ \(label): \(String(format: "%.3f", executionTime))s")
        return (result, executionTime)
    }

    private func measureMemoryUsage() {
        var memInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

        let result = withUnsafeMutablePointer(to: &memInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            memoryUsage = Double(memInfo.resident_size) / (1024 * 1024) // MB
            logger.info("💾 Current memory usage: \(String(format: "%.2f", memoryUsage)) MB")
        }
    }

    private func initializeWithPerformanceTracking() async {
        let overallStart = Date()
        logger.info("🚀 PowerSenseDataViewer: Starting initialization with performance tracking")

        // Measure device query performance
        let deviceStart = Date()
        let deviceCountResult = measureQueryPerformance({ devices.count }, label: "Device count query")
        deviceQueryTime = Date().timeIntervalSince(deviceStart)

        // Measure event query performance
        let eventStart = Date()
        let eventCountResult = measureQueryPerformance({ events.count }, label: "Event count query")
        eventQueryTime = Date().timeIntervalSince(eventStart)

        // Update counts
        await refreshDataCounts()

        measureMemoryUsage()

        let totalTime = Date().timeIntervalSince(overallStart)
        logger.info("✅ PowerSenseDataViewer initialization completed in \(String(format: "%.3f", totalTime))s")
        logger.info("📈 Device query: \(String(format: "%.3f", deviceQueryTime))s for \(deviceCountResult.result) devices")
        logger.info("📈 Event query: \(String(format: "%.3f", eventQueryTime))s for \(eventCountResult.result) events")
    }

    // MARK: - Debug Overlay

    private var debugPerformanceOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("🔍 Performance Debug")
                .font(.headline)
                .foregroundColor(.white)

            Text("Devices: \(devices.count) (\(String(format: "%.3f", deviceQueryTime))s)")
                .font(.caption)
                .foregroundColor(.white)

            Text("Events: \(events.count) (\(String(format: "%.3f", eventQueryTime))s)")
                .font(.caption)
                .foregroundColor(.white)

            Text("Memory: \(String(format: "%.2f", memoryUsage)) MB")
                .font(.caption)
                .foregroundColor(.white)

            Text("Filtering: \(String(format: "%.3f", filteringTime))s")
                .font(.caption)
                .foregroundColor(.white)

            Divider()
                .background(Color.white)

            Text("Current View: \(selectedView.displayName)")
                .font(.caption)
                .foregroundColor(.cyan)

            Text("Tap 3x to hide")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(8)
        .background(Color.black.opacity(0.8))
        .cornerRadius(8)
    }

    // MARK: - Data Management

    private func refreshDataCounts() async {
        let refreshStart = Date()
        logger.info("🔄 Starting data count refresh...")

        do {
            // Measure device count query
            let deviceCountStart = Date()
            let deviceDescriptor = FetchDescriptor<PowerSenseDevice>()
            deviceCount = try modelContext.fetchCount(deviceDescriptor)
            let deviceCountTime = Date().timeIntervalSince(deviceCountStart)

            // Measure event count query
            let eventCountStart = Date()
            let eventDescriptor = FetchDescriptor<PowerSenseEvent>()
            eventCount = try modelContext.fetchCount(eventDescriptor)
            let eventCountTime = Date().timeIntervalSince(eventCountStart)

            lastRefreshed = Date()
            let totalRefreshTime = Date().timeIntervalSince(refreshStart)

            logger.info("✅ Data counts refreshed in \(String(format: "%.3f", totalRefreshTime))s")
            logger.info("📈 Device count query: \(String(format: "%.3f", deviceCountTime))s (\(deviceCount) devices)")
            logger.info("📈 Event count query: \(String(format: "%.3f", eventCountTime))s (\(eventCount) events)")

            measureMemoryUsage()
        } catch {
            logger.error("❌ Failed to refresh data counts: \(error.localizedDescription)")
        }
    }

    private func refreshAll() async {
        let syncStart = Date()
        logger.info("🔄 Starting full data refresh/sync...")

        isRefreshing = true
        defer {
            isRefreshing = false
            let totalSyncTime = Date().timeIntervalSince(syncStart)
            logger.info("✅ Full refresh completed in \(String(format: "%.3f", totalSyncTime))s")
        }

        do {
            let dataService = PowerSenseDataService(modelContext: modelContext)
            let (newDeviceCount, newEventCount) = try await dataService.syncPowerSenseData()

            await refreshDataCounts()
            measureMemoryUsage()

            logger.info("📈 Data refresh completed: \(newDeviceCount) devices, \(newEventCount) events processed")
        } catch {
            logger.error("❌ Data refresh failed: \(error.localizedDescription)")
        }
    }

    private func deleteAllEvents() async {
        let deleteStart = Date()
        logger.info("🗑️ Starting to delete all PowerSense events...")

        isRefreshing = true
        defer {
            isRefreshing = false
            let totalDeleteTime = Date().timeIntervalSince(deleteStart)
            logger.info("✅ Delete all events completed in \(String(format: "%.3f", totalDeleteTime))s")
        }

        do {
            let eventDescriptor = FetchDescriptor<PowerSenseEvent>()
            let allEvents = try modelContext.fetch(eventDescriptor)

            logger.info("🗑️ Found \(allEvents.count) events to delete")

            for event in allEvents {
                modelContext.delete(event)
            }

            try modelContext.save()

            await refreshDataCounts()
            measureMemoryUsage()

            logger.info("✅ Successfully deleted all \(allEvents.count) PowerSense events")
        } catch {
            logger.error("❌ Failed to delete events: \(error.localizedDescription)")
        }
    }
}

// MARK: - Supporting Types

enum DataViewerView: String, CaseIterable {
    case devices = "devices"
    case events = "events"

    var displayName: String {
        switch self {
        case .devices: return "Devices"
        case .events: return "Events"
        }
    }

    var icon: String {
        switch self {
        case .devices: return "network"
        case .events: return "bolt.circle"
        }
    }
}

enum DeviceSortOption: String, CaseIterable {
    case name = "name"
    case deviceId = "deviceId"
    case powerStatus = "powerStatus"
    case lastUpdated = "lastUpdated"

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .deviceId: return "Device ID"
        case .powerStatus: return "Power Status"
        case .lastUpdated: return "Last Updated"
        }
    }
}

enum EventSortOption: String, CaseIterable {
    case timestamp = "timestamp"
    case eventType = "eventType"
    case severity = "severity"

    var displayName: String {
        switch self {
        case .timestamp: return "Time"
        case .eventType: return "Type"
        case .severity: return "Severity"
        }
    }
}

// MARK: - Data Health Card

struct DataHealthCard: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(count)")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - PowerSense Device Row

struct PowerSenseDeviceRow: View {
    let device: PowerSenseDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name ?? device.deviceId)
                        .font(.headline)

                    Text("ID: \(device.deviceId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    powerStatusBadge

                    if device.isMonitored {
                        Text("Monitored")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
            }

            if let tlc = device.tlc, let tui = device.tui {
                HStack {
                    Text("TLC: \(tlc)")
                    Spacer()
                    Text("TUI: \(tui)")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            if device.lastUpdated != Date(timeIntervalSince1970: 0) {
                Text("Updated: \(device.lastUpdated, style: .relative) ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var powerStatusBadge: some View {
        Group {
            switch device.isOffline {
            case false:
                Text("Online")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(4)

            case true:
                Text("Offline")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.2))
                    .foregroundColor(.red)
                    .cornerRadius(4)

            case nil:
                Text("Unknown")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.gray)
                    .cornerRadius(4)
            }
        }
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: PowerSenseEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.eventDescription ?? "PowerSense Event")
                        .font(.headline)

                    Text("ID: \(event.eventId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    eventTypeBadge
                    severityBadge
                }
            }

            HStack {
                Text(event.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text("Device: \(event.device?.name ?? "nil")")
                    .font(.caption)
                    .foregroundColor(event.device?.name != nil ? .secondary : .red)
            }

            if event.isActiveOutage {
                Text("Duration: \(event.durationString)")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if event.outageDuration != nil {
                Text("Duration: \(event.durationString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var eventTypeBadge: some View {
        Text(event.isActive ? "Active" : "Resolved")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((event.isActive ? Color.red : Color.green).opacity(0.2))
            .foregroundColor(event.isActive ? .red : .green)
            .cornerRadius(4)
    }

    private var severityBadge: some View {
        Text("Severity \(event.severity)")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(severityColor.opacity(0.2))
            .foregroundColor(severityColor)
            .cornerRadius(4)
    }

    private var severityColor: Color {
        switch event.severity {
        case 0...1: return .gray
        case 2: return .yellow
        case 3: return .orange
        case 4...5: return .red
        default: return .gray
        }
    }
}
