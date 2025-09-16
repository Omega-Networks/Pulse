//
//  Event.swift
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

import CoreData
import OSLog
import SwiftData
import SwiftUI

// MARK: - SwiftData

@Model
final class Event {
    // TODO: Make into non-unique with error handling on import
    @Attribute(.unique) var eventId: String
    var acknowledged: String = ""
    var clock: String = ""
    var value: String = ""
    var name: String = ""
    var object: String = ""
    var objectId: String = ""
    var rClock: String = ""
    var opData: String = ""
    var severity: String = ""
    var source: String = ""
    var suppressed: String = ""
    var device: Device?
    
    /// Added for Preview, might move to prod
    /// Preview value (Int64) over String
    var hostId: Int64 = 0
    
    init(eventId: String) {
        self.eventId = eventId
    }
}

extension Event {
    
    func update(with properties: EventProperties, device: Device? = nil) {
        // Always update these properties as they come from both problem.get and event.get
        self.name = properties.name
        self.source = properties.source
        self.object = properties.object
        self.objectId = properties.objectId
        self.clock = properties.clock
        self.acknowledged = properties.acknowledged
        self.severity = properties.severity
        self.opData = properties.opData
        self.suppressed = properties.suppressed
        
        // Only update device if provided
        if let device = device {
            self.device = device
        }
        
        // Only update value if it exists in properties
        if (properties.value != nil) {
            self.value = properties.value ?? ""
        }
        
        // Only update rClock if it exists in properties
        if (properties.rClock != nil) {
            self.rClock = properties.rClock ?? ""
        }
    }
    
    var severityString: String {
        switch Int(self.severity) {
        case 0:
            return "Not Classified"
        case 1:
            return "Information"
        case 2:
            return "Warning"
        case 3:
            return "Average"
        case 4:
            return "High"
        case 5:
            return "Disaster"
        default:
            return "Unknown"
        }
    }
    
    var severityColor: Color {
        switch Int(self.severity) {
        case 0:
            return .gray
        case 1:
            return .blue
        case 2:
            return .yellow
        case 3:
            return .orange
        case 4:
            return .red
        case 5:
            return .black
        default:
            return .purple
        }
    }
    
    var acknowledgedString: String {
        switch Int(self.acknowledged) {
        case 0:
            return "No"
        case 1:
            return "Yes"
        default:
            return "Unknown"
        }
    }
    
    var acknowledgedColor: Color {
        switch Int(self.acknowledged) {
        case 0:
            return .red
        case 1:
            return .green
        default:
            return .purple
        }
    }
    
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    
    var formattedClock: String {
        guard let clockInt = Int(clock) else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(clockInt))
        return Event.dateFormatter.string(from: date)
    }
    
    var state: String {
        if let rClockInt = Int(rClock), rClockInt != 0 {
            return "RESOLVED"
        }
        if let suppressedInt = Int(suppressed), suppressedInt != 0 {
            return "SUPPRESSED"
        }
        else {
            return "PROBLEM"
        }
    }
    
    var stateColor: Color {
        if let rClockInt = Int(rClock), rClockInt != 0 {
            return .green
        }
        if let suppressedInt = Int(suppressed), suppressedInt != 0 {
            return .primary
        }
        else {
            return .red
        }
    }
    
    
    // TODO: Need to update this to work with Events since no r_clock
    var timeTillResolvedOrNow: String {
        guard let clockInt = Int(clock) else { return "" }
        let startDate = Date(timeIntervalSince1970: TimeInterval(clockInt))
        let endDate: Date
        
        if let rClockInt = Int(rClock), rClockInt != 0 {
            endDate = Date(timeIntervalSince1970: TimeInterval(rClockInt))
        } else {
            endDate = Date()
        }
        
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: startDate, to: endDate)
        
        if let days = components.day, let hours = components.hour, let minutes = components.minute {
            return "\(days)d \(hours)h \(minutes)m"
        } else {
            return ""
        }
    }
}

//MARK: - API request for Event as a reference
//{
//    "eventid": "24715519",
//    "source": "0",
//    "object": "0",
//    "objectid": "54940",
//    "clock": "1723350644",
//    "value": "0",
//    "acknowledged": "0",
//    "ns": "820202127",
//    "name": "Interface sw1.0005(demo_switch): Link down",
//    "severity": "0",
//    "r_eventid": "0",
//    "c_eventid": "0",
//    "correlationid": "0",
//    "userid": "0",
//    "cause_eventid": "0",
//    "opdata": "Current state: *UNKNOWN*",
//    "hosts": [
//        {
//            "hostid": "10499"
//        }
//    ],
//    "suppressed": "0",
//    "urls": [],
//    "tags": [
//        {
//            "tag": "Application",
//            "value": "Interface sw1.0005(demo_switch)"
//        }
//    ]
//},

/// A struct encapsulating the properties of an Event.
struct EventProperties: Decodable {
    
    // MARK: - Codable
    
    private enum CodingKeys: String, CodingKey {
        case name, value, source, object, clock, acknowledged, severity, suppressed
        case eventId = "eventid"
        case objectId = "objectid"
        case rClock = "r_clock"
        case opData = "opdata"
        case hosts
    }
    
    private enum HostsKeys: String, CodingKey {
        case hostId = "hostid"
    }
    
    struct Host: Decodable {
        let hostId: String
        
        private enum CodingKeys: String, CodingKey {
            case hostId = "hostid"
        }
    }
    
    let eventId: String
    let name: String
    let source: String
    let object: String
    let objectId: String
    let clock: String
    let acknowledged: String
    let severity: String
    let opData: String
    let suppressed: String
    let lastUpdated: Date

    
    let rClock: String?
    let value: String?
    let hostIds: [String]
    
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        
        let rawEventId = try? values.decode(String.self, forKey: .eventId)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawValue = try? values.decode(String.self, forKey: .value)
        let rawSource = try? values.decode(String.self, forKey: .source)
        let rawObject = try? values.decode(String.self, forKey: .object)
        let rawObjectId = try? values.decode(String.self, forKey: .objectId)
        let rawRClock = try? values.decode(String.self, forKey: .rClock)
        let rawClock = try? values.decode(String.self, forKey: .clock)
        let rawAcknowledged = try? values.decode(String.self, forKey: .acknowledged)
        let rawSeverity = try? values.decode(String.self, forKey: .severity)
        let rawOpData = try? values.decode(String.self, forKey: .opData)
        let rawSuppressed = try? values.decode(String.self, forKey: .suppressed)
        
        // Nested Hosts attributes
        var rawHostIds: [String] = []
        
        if let codingContainer = try? decoder.container(keyedBy: CodingKeys.self) {
            if let hostArray = try codingContainer.decodeIfPresent([Host].self, forKey: .hosts) {
                for host in hostArray {
                    rawHostIds.append(host.hostId)
                }
            }
        }
        
        
        // Ignore records with missing data.
        guard let eventId = rawEventId,
            let name = rawName,
            let source = rawSource,
            let object = rawObject,
            let objectId = rawObjectId,
            let clock = rawClock,
            let acknowledged = rawAcknowledged,
            let severity = rawSeverity,
            let opData = rawOpData,
            let suppressed = rawSuppressed
        else {
            let values = "eventId = \(rawEventId?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "source = \(rawSource?.description ?? "nil"), "
            + "object = \(rawObject?.description ?? "nil"), "
            + "objectId = \(rawObjectId?.description ?? "nil"), "
            + "clock = \(rawClock?.description ?? "nil"), "
            + "acknowledged = \(rawSeverity?.description ?? "nil"), "
            + "severity = \(rawSeverity?.description ?? "nil"), "
            + "opData = \(rawOpData?.description ?? "nil"), "
            + "suppressed = \(rawSuppressed?.description ?? "nil"), "
            
            let logger = Logger(subsystem: "zabbix", category: "parsing")
            logger.debug("Ignored: \(values)")
            
            throw SwiftDataError.missingData
        }
        
        /// Assign defaults for value with potential 'nil' return
        let hostIds = rawHostIds
        let value = rawValue
        let rClock = rawRClock
        
        self.eventId = eventId
        self.name = name
        self.value = value
        self.source = source
        self.object = object
        self.objectId = objectId
        self.rClock = rClock
        self.clock = clock
        self.acknowledged = acknowledged
        self.severity = severity
        self.opData = opData
        self.suppressed = suppressed
        self.hostIds = hostIds
        self.lastUpdated = Date.now
    }
    
    var dictionaryValue: [String: Any] {
        [
            "eventId": eventId,
            "name": name,
            "source": source,
            "object": object,
            "objectId": objectId,
            "clock": clock,
            "acknowledged": acknowledged,
            "severity": severity,
            "opData": opData,
            "suppressed": suppressed
        ]
    }
}
