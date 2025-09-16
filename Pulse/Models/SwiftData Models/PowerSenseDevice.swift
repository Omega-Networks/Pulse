//
//  PowerSenseDevice.swift
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

/// SwiftData model representing an individual PowerSense ONT device
///
/// **CRITICAL PRIVACY NOTE**: This model stores individual device data and must NEVER be exposed
/// directly to the UI. All visualization must go through aggregation layers that enforce
/// minimum device thresholds and privacy controls.
@Model
final class PowerSenseDevice {

    // MARK: - Core Properties

    /// Unique device identifier from PowerSense/Zabbix
    @Attribute(.unique) var deviceId: String

    /// Device name/identifier
    var name: String?

    /// Current power status - nil means unknown/no data available
    /// true = powered, false = power lost, nil = unknown
    var isPowered: Bool?

    /// Last time power status changed (nil if never changed or unknown)
    var lastStatusChange: Date?

    /// Creation timestamp
    var created: Date = Date()

    /// Last update timestamp
    var lastUpdated: Date = Date()

    // MARK: - Location Properties (Privacy Sensitive)

    /// Device latitude (stored with reduced precision for privacy)
    var latitude: Double = 0.0

    /// Device longitude (stored with reduced precision for privacy)
    var longitude: Double = 0.0

    /// Location accuracy/confidence level
    var locationAccuracy: Double?

    // MARK: - Infrastructure Identifiers

    /// Telecom Location Code (TLC)
    var tlc: String?

    /// Terralink Unique ID (TUI)
    var tui: String?

    /// PowerSense alarm ID for correlation
    var alarmId: String?

    /// Zabbix host ID for this device
    var zabbixHostId: String?

    // MARK: - Data Quality Properties

    /// Whether we have valid power status data for this device
    var hasPowerStatusData: Bool {
        isPowered != nil
    }

    /// Last time we received any data about this device
    var lastDataReceived: Date?

    /// Device monitoring status
    var isMonitored: Bool = false

    // MARK: - Aggregation Properties

    /// Grid cell X coordinate (for aggregation grouping)
    var gridX: Int = 0

    /// Grid cell Y coordinate (for aggregation grouping)
    var gridY: Int = 0

    /// Pre-computed grid cell identifier for fast queries
    var gridCellId: String {
        "\(gridX),\(gridY)"
    }

    // MARK: - Relationships

    /// Related power events for this device
    @Relationship(deleteRule: .cascade, inverse: \PowerSenseEvent.device)
    var events: [PowerSenseEvent] = []

    /// Associated site (if device can be mapped to a network site)
    var site: Site?

    // MARK: - Initialization

    init(deviceId: String, latitude: Double = 0.0, longitude: Double = 0.0) {
        self.deviceId = deviceId
        self.latitude = latitude
        self.longitude = longitude
        self.updateGridCoordinates()
        // Explicitly not setting isPowered - it remains nil until we have actual data
    }

    // MARK: - Privacy and Aggregation Methods

    /// Update grid coordinates based on current location
    /// Uses 100m x 100m grid cells as specified in requirements
    private func updateGridCoordinates() {
        // Convert lat/lon to grid coordinates (100m cells)
        // Rough approximation: 1 degree lat ≈ 111km, 1 degree lon ≈ 111km * cos(lat)
        let gridSize = 0.0009 // Approximately 100m in degrees at Wellington latitude

        self.gridX = Int(latitude / gridSize)
        self.gridY = Int(longitude / gridSize)
    }

    /// Get CLLocation for mapping/distance calculations
    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    /// Calculate distance to another device (for aggregation purposes)
    func distance(to other: PowerSenseDevice) -> CLLocationDistance {
        return location.distance(from: other.location)
    }

    // MARK: - Power Status Methods

    /// Update power status and record the change
    func updatePowerStatus(_ newStatus: Bool?) {
        guard newStatus != isPowered else { return } // No change

        let oldStatus = isPowered
        isPowered = newStatus

        // Only update lastStatusChange if we have actual data
        if newStatus != nil {
            lastStatusChange = Date()
            lastDataReceived = Date()
            lastUpdated = Date()
        }
    }

    /// Power status as a string for debugging/logging
    var powerStatusString: String {
        switch isPowered {
        case true: return "Powered"
        case false: return "Power Lost"
        case nil: return "Unknown"
        }
    }
}

// MARK: - PowerSense Device Properties (API Communication)

/// Properties structure for PowerSense device data from Zabbix API
struct PowerSenseDeviceProperties: Decodable {

    // MARK: - Codable Keys

    private enum CodingKeys: String, CodingKey {
        case deviceId = "hostid"
        case name
        case host
        case status
        case macros
    }

    struct MacroData: Decodable {
        let macro: String
        let value: String?
        let description: String?
    }

    // MARK: - Properties

    let deviceId: String
    let name: String
    let status: String // "0" = monitored, "1" = not monitored
    let latitude: Double?
    let longitude: Double?
    let tlc: String?
    let tui: String?
    let alarmId: String?
    let lastUpdate: String?

    // MARK: - Decodable Implementation

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields
        deviceId = try container.decode(String.self, forKey: .deviceId)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)

        // Initialize defaults
        var parsedLatitude: Double?
        var parsedLongitude: Double?
        var parsedTlc: String?
        var parsedTui: String?
        var parsedAlarmId: String?
        var parsedLastUpdate: String?

        // Parse macros to extract key PowerSense data
        if let macrosArray = try? container.decode([MacroData].self, forKey: .macros) {
            for macro in macrosArray {
                let macroValue = macro.value ?? ""

                switch macro.macro {
                case "{$LATITUDE}":
                    parsedLatitude = Double(macroValue)
                case "{$LONGITUDE}":
                    parsedLongitude = Double(macroValue)
                case "{$TLC}":
                    parsedTlc = macroValue.isEmpty ? nil : macroValue
                case "{$TUI}":
                    parsedTui = macroValue.isEmpty ? nil : macroValue
                case "{$POWERSENSE.LAST.ALARM.ID}":
                    parsedAlarmId = macroValue.isEmpty ? nil : macroValue
                default:
                    break
                }
            }
        }

        // Assign parsed values
        latitude = parsedLatitude
        longitude = parsedLongitude
        tlc = parsedTlc
        tui = parsedTui
        alarmId = parsedAlarmId
        lastUpdate = parsedLastUpdate
    }

    // MARK: - Computed Properties

    /// Returns nil for power status - actual power state should come from events, not host status
    var isPowered: Bool? {
        // Don't assume power state from host monitoring status
        // Power state should be determined from actual PowerSense events
        return nil
    }

    var isMonitored: Bool {
        return status == "0"
    }

    var lastUpdateDate: Date? {
        guard let lastUpdate = lastUpdate,
              let timestamp = Double(lastUpdate) else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    // MARK: - Privacy Methods

    /// Returns coordinates with reduced precision for privacy
    var privacyLatitude: Double {
        guard let lat = latitude else { return 0.0 }
        // Reduce precision to ~100m accuracy
        return Double(Int(lat * 10000)) / 10000
    }

    var privacyLongitude: Double {
        guard let lon = longitude else { return 0.0 }
        // Reduce precision to ~100m accuracy
        return Double(Int(lon * 10000)) / 10000
    }

    // MARK: - Validation

    var isValid: Bool {
        return !deviceId.isEmpty &&
               latitude != nil &&
               longitude != nil &&
               (latitude! >= -90 && latitude! <= 90) &&
               (longitude! >= -180 && longitude! <= 180)
    }
}

// MARK: - Privacy Extensions

extension PowerSenseDevice {

    /// Privacy-safe computed properties (never expose individual device data)

    /// Device is suitable for aggregation (has valid location data)
    var canAggregate: Bool {
        return latitude != 0.0 && longitude != 0.0 && !deviceId.isEmpty
    }

    /// Recent power loss (within last hour) - only if we have status data
    var hasRecentPowerLoss: Bool {
        guard let powered = isPowered,
              let statusChange = lastStatusChange else { return false }
        return !powered && statusChange.timeIntervalSinceNow > -3600
    }

    /// Stable power status (no changes in last 15 minutes) - only if we have data
    var hasStablePowerStatus: Bool {
        guard let statusChange = lastStatusChange else { return false }
        return statusChange.timeIntervalSinceNow < -900
    }

    /// Device has recent data (received data in last 5 minutes)
    var hasRecentData: Bool {
        guard let lastData = lastDataReceived else { return false }
        return lastData.timeIntervalSinceNow > -300
    }
}

// MARK: - Aggregation Helpers

extension PowerSenseDevice {

    /// Static method to group devices by grid cell for aggregation
    static func groupByGridCell(_ devices: [PowerSenseDevice]) -> [String: [PowerSenseDevice]] {
        return Dictionary(grouping: devices) { $0.gridCellId }
    }

    /// Static method to filter devices for privacy compliance
    static func filterForPrivacy(_ devices: [PowerSenseDevice]) -> [PowerSenseDevice] {
        return devices.filter { $0.canAggregate }
    }

    /// Static method to filter devices with known power status
    static func filterWithPowerData(_ devices: [PowerSenseDevice]) -> [PowerSenseDevice] {
        return devices.filter { $0.hasPowerStatusData }
    }
}