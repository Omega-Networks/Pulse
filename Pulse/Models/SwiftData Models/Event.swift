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
    /// One `#Index`. Each array is its own index: `siteId` for the
    /// problems table, `rClock` for the active-event query, `hostId`
    /// for the count predicates, and `object` with `triggerDescription`
    /// for the nil-comment page. None of these add a column.
    /// `causeEventId` is the correlation. It is not an index.
    #Index<Event>([\.siteId], [\.rClock], [\.hostId], [\.object, \.triggerDescription])

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
    /// Zabbix problem rank. "0" is a cause. Any other value is the cause's
    /// event id, and this row is a symptom. Older Zabbix sends no rank.
    var causeEventId: String = "0"
    /// Trigger description (`trigger.get` comments, macros expanded).
    /// nil until fetched. "" when the trigger has none or is gone.
    var triggerDescription: String?
    var severity: String = ""
    var source: String = ""
    var suppressed: String = ""
    var device: Device?
    var virtualMachine: VirtualMachine?
    var cluster: Cluster?

    /// The owner that is set. A device wins when more than one is set,
    /// which is a data error and not a normal row.
    var owner: NetBoxObjectRef? {
        if let id = device?.id { return .device(id) }
        if let id = virtualMachine?.id { return .virtualMachine(id) }
        if let id = cluster?.id { return .cluster(id) }
        return nil
    }

    /// Added for Preview, might move to prod
    /// Preview value (Int64) over String
    var hostId: Int64 = 0
    var siteId: Int64 = 0
    
    init(eventId: String) {
        self.eventId = eventId
    }

    /// False after this row has been deleted from the store. Reading any
    /// persisted property then traps in SwiftData; callers that walk
    /// `Device.events` / `@Query` after Delete All must skip these.
    var isStoreBacked: Bool { modelContext != nil }

    /// In-memory form of `counted`. Call only after `isStoreBacked`.
    var isCountedProblem: Bool {
        rClock == "0" && suppressed == "0" && causeEventId == "0"
    }

    /// True when Zabbix ranks this row under a cause. A missing rank is a cause.
    var isSymptom: Bool { causeEventId != "0" }

    /// Open, not suppressed, and not a symptom. Zabbix counts maps the same way.
    static var counted: Predicate<Event> {
        #Predicate<Event> { event in
            event.rClock == "0" && event.suppressed == "0" && event.causeEventId == "0"
        }
    }

    /// `counted` limited to these Zabbix host ids. The host term cannot
    /// live inside `counted`: a `#Predicate` does not call another one.
    static func counted(amongHostIds hostIds: [Int64]) -> Predicate<Event> {
        let ids = hostIds
        return #Predicate<Event> { event in
            event.rClock == "0" && event.suppressed == "0"
                && event.causeEventId == "0" && ids.contains(event.hostId)
        }
    }
    
    /// Writes the payload onto this row. An equal value is left alone, so a
    /// quiet poll does not dirty the row. Returns whether anything changed.
    /// The relationship is the link. `siteId` is stamped from the device's
    /// resolved site when one is passed. A missing host id leaves `hostId` as it was.
    @discardableResult
    func update(with properties: EventProperties, device: Device? = nil) -> Bool {
        var changed = false
        changed = assign(\.name, properties.name) || changed
        changed = assign(\.source, properties.source) || changed
        changed = assign(\.object, properties.object) || changed
        changed = assign(\.objectId, properties.objectId) || changed
        changed = assign(\.clock, properties.clock) || changed
        changed = assign(\.acknowledged, properties.acknowledged) || changed
        changed = assign(\.severity, properties.severity) || changed
        changed = assign(\.opData, properties.opData) || changed
        changed = assign(\.suppressed, properties.suppressed) || changed
        if let causeEventId = properties.causeEventId {
            changed = assign(\.causeEventId, causeEventId) || changed
        }
        if let value = properties.value {
            changed = assign(\.value, value) || changed
        }
        if let rClock = properties.rClock {
            changed = assign(\.rClock, rClock) || changed
        }
        if let device, self.device?.id != device.id {
            self.device = device
            changed = true
        }
        if let device {
            let resolved = device.resolvedSiteId
            if resolved != 0, siteId != resolved {
                siteId = resolved
                changed = true
            }
        }
        if let rawHostId = properties.hostIds.first, let hostId = Int64(rawHostId), self.hostId != hostId {
            self.hostId = hostId
            changed = true
        }
        return changed
    }

    /// `problem.get` does not return hosts, so a linked row can still have
    /// `hostId == 0`. The device it is already on is the host. A set value
    /// is left alone.
    @discardableResult
    func stampHostIdIfMissing(from device: Device) -> Bool {
        guard hostId == 0, device.zabbixId != 0 else { return false }
        hostId = device.zabbixId
        return true
    }

    private func assign(_ keyPath: ReferenceWritableKeyPath<Event, String>, _ value: String) -> Bool {
        guard self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        return true
    }
    
    var severityString: String {
        Self.severityName(Int(severity) ?? -1)
    }

    var severityColor: Color {
        Self.severityColor(for: Int(severity) ?? -1)
    }

    static func severityName(_ value: Int) -> String {
        switch value {
        case 0: return "Not Classified"
        case 1: return "Information"
        case 2: return "Warning"
        case 3: return "Average"
        case 4: return "High"
        case 5: return "Disaster"
        default: return "Unknown"
        }
    }

    static func severityColor(for value: Int) -> Color {
        switch value {
        case 0: return .gray
        case 1: return .blue
        case 2: return .yellow
        case 3: return .orange
        case 4: return .red
        case 5: return .black
        default: return .purple
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
struct EventProperties: Decodable, Sendable {
    
    // MARK: - Codable
    
    private enum CodingKeys: String, CodingKey {
        case name, value, source, object, clock, acknowledged, severity, suppressed
        case eventId = "eventid"
        case objectId = "objectid"
        case rClock = "r_clock"
        case opData = "opdata"
        case causeEventId = "cause_eventid"
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

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try? values.decode(String.self, forKey: .hostId) {
                hostId = s
            } else if let i = try? values.decode(Int64.self, forKey: .hostId) {
                hostId = String(i)
            } else {
                throw SwiftDataError.missingData
            }
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
    /// Nil when the payload omits `cause_eventid`. An update then leaves
    /// the stored rank. A present value, including "0", is written.
    let causeEventId: String?

    let rClock: String?
    let value: String?
    let hostIds: [String]
    
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)

        func flex(_ key: CodingKeys) -> String? {
            if let s = try? values.decode(String.self, forKey: key) { return s }
            if let i = try? values.decode(Int64.self, forKey: key) { return String(i) }
            if let d = try? values.decode(Double.self, forKey: key) { return String(d) }
            return nil
        }

        let rawEventId = flex(.eventId)
        let rawName = flex(.name)
        let rawValue = flex(.value)
        let rawSource = flex(.source)
        let rawObject = flex(.object)
        let rawObjectId = flex(.objectId)
        let rawRClock = flex(.rClock)
        let rawClock = flex(.clock)
        let rawAcknowledged = flex(.acknowledged)
        let rawSeverity = flex(.severity)
        let rawOpData = flex(.opData)
        let rawSuppressed = flex(.suppressed)
        let rawCauseEventId = flex(.causeEventId)
        
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
        self.causeEventId = rawCauseEventId
        self.hostIds = hostIds
    }
}
