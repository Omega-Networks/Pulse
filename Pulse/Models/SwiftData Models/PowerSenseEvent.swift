//
//  PowerSenseEvent.swift
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
import SwiftUI

/// SwiftData model representing a PowerSense power state change event
///
/// These events track when ONT devices lose or regain power, providing the historical
/// data needed for outage analysis while maintaining privacy through aggregation.
@Model
final class PowerSenseEvent {

    // MARK: - Core Properties

    /// Unique event identifier from PowerSense/Zabbix
    @Attribute(.unique) var eventId: String

    /// Event timestamp
    var timestamp: Date

    /// Whether the event is currently active (true = power off, false = resolved/power restored)
    var isActive: Bool {
        return resolvedAt == nil
    }

    /// Event severity level (0-5, following Zabbix convention)
    var severity: Int = 0

    /// Human-readable event description
    var eventDescription: String?

    /// Raw event value from PowerSense (if available)
    var rawValue: String?

    /// Event acknowledged status
    var isAcknowledged: Bool = false

    /// Event resolution timestamp (nil if not resolved)
    var resolvedAt: Date?

    /// Creation timestamp
    var created: Date = Date()

    // MARK: - Correlation Properties

    /// PowerSense alarm ID that triggered this event
    var alarmId: String?

    /// Zabbix event ID for correlation
    var zabbixEventId: String?

    /// Related outage duration (calculated when event resolves)
    var outageDuration: TimeInterval?

    // MARK: - Relationships

    /// The PowerSense device this event belongs to
    var device: PowerSenseDevice?

    // MARK: - Initialization

    init(eventId: String, timestamp: Date, deviceId: String? = nil) {
        self.eventId = eventId
        self.timestamp = timestamp
    }

    // MARK: - Event Processing

    /// Update event with properties from PowerSense/Zabbix
    func update(with properties: PowerSenseEventProperties) {
        self.eventDescription = properties.name
        self.severity = properties.severity
        self.rawValue = properties.value
        self.isAcknowledged = properties.acknowledged
        self.resolvedAt = properties.resolvedAt
        self.alarmId = properties.alarmId
        self.zabbixEventId = properties.zabbixEventId

        // Calculate outage duration if event is resolved
        if let resolvedAt = resolvedAt {
            self.outageDuration = resolvedAt.timeIntervalSince(timestamp)
        }
    }

    /// Mark event as acknowledged
    func acknowledge() {
        isAcknowledged = true
    }

    /// Resolve the event with current timestamp
    func resolve() {
        guard resolvedAt == nil else { return } // Already resolved

        resolvedAt = Date()
        outageDuration = resolvedAt!.timeIntervalSince(timestamp)
    }
}

// MARK: - PowerSense Event Properties (API Communication)

/// Properties structure for PowerSense event data from Zabbix API
struct PowerSenseEventProperties: Decodable {

    // MARK: - Codable Keys

    private enum CodingKeys: String, CodingKey {
        case eventId = "eventid"
        case name
        case source
        case object
        case objectId = "objectid"
        case clock
        case ns
        case severity
        case acknowledges
        case tags
        case hosts
        case rEventId = "r_eventid"
        case rClock = "r_clock"
    }

    struct TagData: Decodable {
        let tag: String
        let value: String
    }

    struct AcknowledgeData: Decodable {
        let acknowledgeid: String?
        let userid: String?
        let eventid: String?
        let clock: String?
        let message: String?
        let action: String?
    }

    struct HostData: Decodable {
        let hostid: String
    }

    // MARK: - Properties

    let eventId: String
    let name: String
    let source: String
    let object: String
    let objectId: String
    let clock: String
    let ns: String?
    let severity: Int
    let acknowledges: [AcknowledgeData]
    let tags: [TagData]
    let hosts: [HostData]?
    let rEventId: String?
    let rClock: String?

    // Computed properties for compatibility
    var hostIds: [String] {
        // For events (event.get): use hosts array if available
        if let hosts = hosts {
            return hosts.map { $0.hostid }
        }
        // For problems (problem.get): use objectId as hostId
        return [objectId]
    }

    var primaryHostId: String? {
        return hostIds.first
    }
    var value: String? { nil } // Not provided in problem.get
    var hostId: String { objectId } // Use objectId as hostId
    var acknowledged: Bool { !acknowledges.isEmpty }
    var alarmId: String? {
        // Extract alarm_id from tags
        tags.first { $0.tag == "alarm_id" }?.value
    }

    /// Extract ONT device name from PowerSense event name for device matching
    /// Format: "Power Off Event: ONT030842360" -> "ONT030842360"
    var ontDeviceName: String? {
        // PowerSense events are always in format "Power Off Event: [ONT_NAME]"
        let powerOffPrefix = "Power Off Event: "

        if name.starts(with: powerOffPrefix) {
            let deviceName = String(name.dropFirst(powerOffPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if deviceName.starts(with: "ONT") && !deviceName.isEmpty {
                return deviceName
            }
        }

        return nil
    }

    // MARK: - Decodable Implementation

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields
        eventId = try container.decode(String.self, forKey: .eventId)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(String.self, forKey: .source)
        object = try container.decode(String.self, forKey: .object)
        objectId = try container.decode(String.self, forKey: .objectId)
        clock = try container.decode(String.self, forKey: .clock)

        // Optional fields
        ns = try container.decodeIfPresent(String.self, forKey: .ns)
        rEventId = try container.decodeIfPresent(String.self, forKey: .rEventId)
        rClock = try container.decodeIfPresent(String.self, forKey: .rClock) // Will be nil for event.get

        // Handle severity as string or int
        if let severityInt = try? container.decode(Int.self, forKey: .severity) {
            severity = severityInt
        } else if let severityString = try? container.decode(String.self, forKey: .severity) {
            severity = Int(severityString) ?? 0
        } else {
            severity = 0
        }

        // Decode acknowledges, tags, and hosts arrays
        acknowledges = try container.decodeIfPresent([AcknowledgeData].self, forKey: .acknowledges) ?? []
        tags = try container.decodeIfPresent([TagData].self, forKey: .tags) ?? []
        hosts = try container.decodeIfPresent([HostData].self, forKey: .hosts) // Optional for problem.get
    }

    // MARK: - Computed Properties

    var timestamp: Date {
        guard let clockValue = Double(clock) else { return Date() }
        return Date(timeIntervalSince1970: clockValue)
    }

    var resolvedAt: Date? {
        guard let rClock = rClock,
              let clockValue = Double(rClock),
              clockValue > 0 else { return nil }
        return Date(timeIntervalSince1970: clockValue)
    }

    var zabbixEventId: String {
        return eventId
    }

    /// Whether this event represents a power loss event based on the name
    var isPowerLossEvent: Bool {
        // PowerSense events are always "Power Off Event: [ONT_NAME]" format
        return name.starts(with: "Power Off Event: ")
    }

    /// Whether this event represents an active outage
    var isActiveOutage: Bool {
        return isPowerLossEvent && resolvedAt == nil
    }

    // MARK: - Validation

    var isValid: Bool {
        return !eventId.isEmpty &&
               !hostId.isEmpty &&
               !clock.isEmpty &&
               Double(clock) != nil
    }
}

// MARK: - Extensions

extension PowerSenseEvent {

    /// Whether this event represents an active outage (power lost and not resolved)
    var isActiveOutage: Bool {
        return isActive  // Active means power is off
    }

    /// Human-readable duration string
    var durationString: String {
        guard let duration = outageDuration else {
            if isActiveOutage {
                let currentDuration = Date().timeIntervalSince(timestamp)
                return formatDuration(currentDuration) + " (ongoing)"
            }
            return "N/A"
        }
        return formatDuration(duration)
    }

    /// Format duration as human-readable string
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    /// Event age (time since event occurred)
    var age: TimeInterval {
        return Date().timeIntervalSince(timestamp)
    }

    /// Whether event is recent (within last hour)
    var isRecent: Bool {
        return age < 3600
    }
}

// MARK: - Aggregation Helpers

extension PowerSenseEvent {

    /// Group events by time window for analysis
    static func groupByTimeWindow(_ events: [PowerSenseEvent], windowSize: TimeInterval = 3600) -> [Date: [PowerSenseEvent]] {
        _ = Calendar.current
        return Dictionary(grouping: events) { event in
            let windowStart = floor(event.timestamp.timeIntervalSince1970 / windowSize) * windowSize
            return Date(timeIntervalSince1970: windowStart)
        }
    }

    /// Filter events for recent outages (active events within timeframe)
    static func recentOutages(_ events: [PowerSenseEvent], within timeframe: TimeInterval = 3600) -> [PowerSenseEvent] {
        let cutoff = Date().addingTimeInterval(-timeframe)
        return events.filter { event in
            event.isActive && event.timestamp > cutoff
        }
    }

    /// Calculate outage statistics for a collection of events
    static func outageStatistics(for events: [PowerSenseEvent]) -> OutageStatistics {
        let powerLostEvents = events  // All events are power-related
        let activeOutages = powerLostEvents.filter { $0.isActive }
        let resolvedOutages = powerLostEvents.filter { !$0.isActive && $0.outageDuration != nil }

        let totalOutages = powerLostEvents.count
        let activeCount = activeOutages.count
        let averageDuration = resolvedOutages.compactMap { $0.outageDuration }.average

        return OutageStatistics(
            totalOutages: totalOutages,
            activeOutages: activeCount,
            resolvedOutages: resolvedOutages.count,
            averageOutageDuration: averageDuration
        )
    }
}

// MARK: - OutageStatistics

/// Statistics summary for PowerSense outages
struct OutageStatistics {
    let totalOutages: Int
    let activeOutages: Int
    let resolvedOutages: Int
    let averageOutageDuration: TimeInterval?

    var outageRate: Double {
        guard totalOutages > 0 else { return 0.0 }
        return Double(activeOutages) / Double(totalOutages)
    }
}

// MARK: - Array Extensions

private extension Array where Element == TimeInterval {
    var average: TimeInterval? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}