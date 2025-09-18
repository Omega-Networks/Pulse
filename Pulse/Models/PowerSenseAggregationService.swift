//
//  PowerSenseAggregationService.swift
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
import CoreLocation
import OSLog

/// Service for aggregating PowerSense device data while maintaining privacy controls
///
/// **CRITICAL**: This service enforces minimum device thresholds to ensure individual
/// device data is never exposed. All aggregation follows privacy-by-design principles.
@MainActor
final class PowerSenseAggregationService: ObservableObject {

    private let logger = Logger(subsystem: "powersense", category: "aggregation")
    private let modelContext: ModelContext

    // MARK: - Configuration

    private var minimumDeviceThreshold: Int {
        get async {
            await Configuration.shared.getPowerSenseMinDeviceThreshold()
        }
    }

    private var gridSize: Int {
        get async {
            await Configuration.shared.getPowerSenseGridSize()
        }
    }

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Privacy-Safe Aggregation

    /// Aggregate PowerSense devices into privacy-compliant grid cells
    /// Only returns cells with at least the minimum device threshold
    func aggregateDevicesIntoGridCells() async throws -> [PowerSenseGridCell] {
        let startTime = Date()
        let minThreshold = await minimumDeviceThreshold
        let gridSizeMeters = await gridSize

        logger.debug("Starting device aggregation with threshold: \(minThreshold), grid size: \(gridSizeMeters)m")

        // Fetch all valid PowerSense devices
        let descriptor = FetchDescriptor<PowerSenseDevice>(
            predicate: #Predicate<PowerSenseDevice> { device in
                device.canAggregate
            }
        )

        let devices = try modelContext.fetch(descriptor)
        logger.debug("Found \(devices.count) valid PowerSense devices for aggregation")

        // Group devices by grid cell
        let groupedDevices = PowerSenseDevice.groupByGridCell(devices)
        logger.debug("Grouped devices into \(groupedDevices.count) grid cells")

        // Create aggregated cells that meet privacy threshold
        var aggregatedCells: [PowerSenseGridCell] = []

        for (gridCellId, cellDevices) in groupedDevices {
            // Privacy control: Only include cells with minimum device count
            guard cellDevices.count >= minThreshold else {
                logger.debug("Skipping grid cell \(gridCellId) - only \(cellDevices.count) devices (below threshold)")
                continue
            }

            // Calculate aggregate statistics
            let cell = await createAggregatedCell(
                cellId: gridCellId,
                devices: cellDevices,
                gridSizeMeters: gridSizeMeters
            )
            aggregatedCells.append(cell)
        }

        logger.debug("Created \(aggregatedCells.count) privacy-compliant grid cells")
        logger.debug("Total aggregation took: \(Date().timeIntervalSince(startTime))s")

        return aggregatedCells.sorted { $0.totalDevices > $1.totalDevices }
    }

    /// Aggregate power events into privacy-compliant time windows
    func aggregateEventsIntoTimeWindows(windowSize: TimeInterval = 3600) async throws -> [PowerSenseTimeWindow] {
        let startTime = Date()
        let minThreshold = await minimumDeviceThreshold

        logger.debug("Starting event aggregation with \(windowSize)s windows, threshold: \(minThreshold)")

        // Fetch recent power events
        let cutoffTime = Date().addingTimeInterval(-24 * 3600) // Last 24 hours
        let descriptor = FetchDescriptor<PowerSenseEvent>(
            predicate: #Predicate<PowerSenseEvent> { event in
                event.timestamp > cutoffTime
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        let events = try modelContext.fetch(descriptor)
        logger.debug("Found \(events.count) recent PowerSense events")

        // Group events by time window
        let groupedEvents = PowerSenseEvent.groupByTimeWindow(events, windowSize: windowSize)
        logger.debug("Grouped events into \(groupedEvents.count) time windows")

        // Create aggregated time windows that meet privacy threshold
        var timeWindows: [PowerSenseTimeWindow] = []

        for (windowStart, windowEvents) in groupedEvents {
            // Get unique device count in this window
            let uniqueDeviceIds = Set(windowEvents.compactMap { $0.device?.deviceId })

            // Privacy control: Only include windows with minimum device count
            guard uniqueDeviceIds.count >= minThreshold else {
                logger.debug("Skipping time window \(windowStart) - only \(uniqueDeviceIds.count) devices affected")
                continue
            }

            let timeWindow = createAggregatedTimeWindow(
                windowStart: windowStart,
                windowSize: windowSize,
                events: windowEvents,
                affectedDeviceCount: uniqueDeviceIds.count
            )
            timeWindows.append(timeWindow)
        }

        logger.debug("Created \(timeWindows.count) privacy-compliant time windows")
        logger.debug("Total event aggregation took: \(Date().timeIntervalSince(startTime))s")

        return timeWindows.sorted { $0.windowStart > $1.windowStart }
    }

    /// Get current outage overview with privacy controls
    func getCurrentOutageOverview() async throws -> PowerSenseOutageOverview {
        let startTime = Date()
        let minThreshold = await minimumDeviceThreshold

        logger.debug("Generating outage overview with threshold: \(minThreshold)")

        // Fetch all PowerSense devices
        let deviceDescriptor = FetchDescriptor<PowerSenseDevice>(
            predicate: #Predicate<PowerSenseDevice> { device in
                device.canAggregate
            }
        )
        let allDevices = try modelContext.fetch(deviceDescriptor)

        // Fetch recent power events (last hour)
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let eventDescriptor = FetchDescriptor<PowerSenseEvent>(
            predicate: #Predicate<PowerSenseEvent> { event in
                event.timestamp > oneHourAgo
            }
        )
        let recentEvents = try modelContext.fetch(eventDescriptor)

        // Calculate privacy-safe statistics
        let devicesWithData = PowerSenseDevice.filterWithPowerData(allDevices)
        let devicesWithoutPower = devicesWithData.filter { $0.isOffline == true }
        let devicesWithPower = devicesWithData.filter { $0.isOffline == false }
        let devicesUnknownStatus = allDevices.filter { !$0.hasPowerStatusData }

        // Group outages by region (grid cells) for affected area calculation
        let outagesByGrid = PowerSenseDevice.groupByGridCell(devicesWithoutPower)
        let affectedGridCells = outagesByGrid.filter { $0.value.count >= minThreshold }.count

        // Recent activity (active events in last hour)
        let recentPowerLostEvents = recentEvents.filter { $0.isActive }
        let recentAffectedDevices = Set(recentPowerLostEvents.compactMap { $0.device?.deviceId })

        let overview = PowerSenseOutageOverview(
            totalMonitoredDevices: allDevices.count,
            devicesWithPowerData: devicesWithData.count,
            devicesWithPower: devicesWithPower.count,
            devicesWithoutPower: devicesWithoutPower.count,
            devicesUnknownStatus: devicesUnknownStatus.count,
            affectedGridCells: affectedGridCells,
            recentActivityDevices: recentAffectedDevices.count >= minThreshold ? recentAffectedDevices.count : 0,
            recentActivityEvents: recentPowerLostEvents.count,
            lastUpdated: Date()
        )

        logger.debug("Generated outage overview in \(Date().timeIntervalSince(startTime))s")
        return overview
    }

    // MARK: - Private Helper Methods

    private func createAggregatedCell(
        cellId: String,
        devices: [PowerSenseDevice],
        gridSizeMeters: Int
    ) async -> PowerSenseGridCell {
        // Calculate center point (privacy-safe)
        let latitudes = devices.compactMap { $0.latitude != 0.0 ? $0.latitude : nil }
        let longitudes = devices.compactMap { $0.longitude != 0.0 ? $0.longitude : nil }

        let centerLat = latitudes.average ?? 0.0
        let centerLon = longitudes.average ?? 0.0

        // Power status aggregation
        let devicesWithPower = devices.filter { $0.isOffline == false }.count
        let devicesWithoutPower = devices.filter { $0.isOffline == true }.count
        let devicesUnknownStatus = devices.filter { !$0.hasPowerStatusData }.count

        // Recent activity (devices with power changes in last hour)
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let recentlyAffectedDevices = devices.filter { device in
            guard let lastChange = device.lastStatusChange else { return false }
            return lastChange > oneHourAgo
        }.count

        return PowerSenseGridCell(
            cellId: cellId,
            centerLatitude: centerLat,
            centerLongitude: centerLon,
            gridSizeMeters: gridSizeMeters,
            totalDevices: devices.count,
            devicesWithPower: devicesWithPower,
            devicesWithoutPower: devicesWithoutPower,
            devicesUnknownStatus: devicesUnknownStatus,
            recentlyAffectedDevices: recentlyAffectedDevices,
            lastUpdated: Date()
        )
    }

    private func createAggregatedTimeWindow(
        windowStart: Date,
        windowSize: TimeInterval,
        events: [PowerSenseEvent],
        affectedDeviceCount: Int
    ) -> PowerSenseTimeWindow {
        let powerLostEvents = events.filter { $0.isActive }
        let resolvedEvents = events.filter { $0.resolvedAt != nil }

        return PowerSenseTimeWindow(
            windowStart: windowStart,
            windowEnd: windowStart.addingTimeInterval(windowSize),
            totalEvents: events.count,
            powerLostEvents: powerLostEvents.count,
            powerRestoredEvents: resolvedEvents.count,
            affectedDeviceCount: affectedDeviceCount,
            averageSeverity: events.compactMap { $0.severity }.average ?? 0.0
        )
    }
}

// MARK: - PowerSense Grid Cell Model

/// Privacy-compliant representation of PowerSense devices in a geographic grid cell
struct PowerSenseGridCell: Identifiable, Hashable {
    let id = UUID()
    let cellId: String
    let centerLatitude: Double
    let centerLongitude: Double
    let gridSizeMeters: Int
    let totalDevices: Int
    let devicesWithPower: Int
    let devicesWithoutPower: Int
    let devicesUnknownStatus: Int
    let recentlyAffectedDevices: Int
    let lastUpdated: Date

    var centerLocation: CLLocation {
        CLLocation(latitude: centerLatitude, longitude: centerLongitude)
    }

    var outageRate: Double {
        guard totalDevices > 0 else { return 0.0 }
        return Double(devicesWithoutPower) / Double(totalDevices)
    }

    var dataQualityRate: Double {
        guard totalDevices > 0 else { return 0.0 }
        let devicesWithData = totalDevices - devicesUnknownStatus
        return Double(devicesWithData) / Double(totalDevices)
    }

    var hasRecentActivity: Bool {
        recentlyAffectedDevices > 0
    }

    var statusSummary: String {
        if devicesWithoutPower == 0 {
            return "All Online"
        } else if devicesWithPower == 0 {
            return "Full Outage"
        } else {
            return "Partial Outage"
        }
    }
}

// MARK: - PowerSense Time Window Model

/// Privacy-compliant representation of PowerSense events in a time window
struct PowerSenseTimeWindow: Identifiable {
    let id = UUID()
    let windowStart: Date
    let windowEnd: Date
    let totalEvents: Int
    let powerLostEvents: Int
    let powerRestoredEvents: Int
    let affectedDeviceCount: Int
    let averageSeverity: Double

    var duration: TimeInterval {
        windowEnd.timeIntervalSince(windowStart)
    }

    var isActiveWindow: Bool {
        windowEnd > Date()
    }

    var activityLevel: PowerSenseActivityLevel {
        switch totalEvents {
        case 0...2: return .low
        case 3...10: return .medium
        case 11...25: return .high
        default: return .critical
        }
    }
}

enum PowerSenseActivityLevel: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"

    var color: String {
        switch self {
        case .low: return "green"
        case .medium: return "yellow"
        case .high: return "orange"
        case .critical: return "red"
        }
    }
}

// MARK: - PowerSense Outage Overview Model

/// High-level overview of PowerSense outage status
struct PowerSenseOutageOverview {
    let totalMonitoredDevices: Int
    let devicesWithPowerData: Int
    let devicesWithPower: Int
    let devicesWithoutPower: Int
    let devicesUnknownStatus: Int
    let affectedGridCells: Int
    let recentActivityDevices: Int
    let recentActivityEvents: Int
    let lastUpdated: Date

    var overallOutageRate: Double {
        guard devicesWithPowerData > 0 else { return 0.0 }
        return Double(devicesWithoutPower) / Double(devicesWithPowerData)
    }

    var dataQualityRate: Double {
        guard totalMonitoredDevices > 0 else { return 0.0 }
        return Double(devicesWithPowerData) / Double(totalMonitoredDevices)
    }

    var systemStatus: PowerSenseSystemStatus {
        switch overallOutageRate {
        case 0.0: return .allOnline
        case 0.01..<0.05: return .minorOutages
        case 0.05..<0.15: return .moderateOutages
        case 0.15..<0.50: return .majorOutages
        default: return .widespreadOutages
        }
    }
}

enum PowerSenseSystemStatus: String, CaseIterable {
    case allOnline = "All Online"
    case minorOutages = "Minor Outages"
    case moderateOutages = "Moderate Outages"
    case majorOutages = "Major Outages"
    case widespreadOutages = "Widespread Outages"

    var color: String {
        switch self {
        case .allOnline: return "green"
        case .minorOutages: return "yellow"
        case .moderateOutages: return "orange"
        case .majorOutages: return "red"
        case .widespreadOutages: return "red"
        }
    }
}

// MARK: - Array Extensions for Aggregation

private extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}

private extension Array where Element == Int {
    var average: Double? {
        guard !isEmpty else { return nil }
        return Double(reduce(0, +)) / Double(count)
    }
}