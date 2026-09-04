//
//  Site.swift
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

import SwiftData
import OSLog
import SwiftUI
import MapKit

// MARK: - SwiftData
//
// Managed object subclass for the Site entity.
//

@Model
final class Site {
    @Attribute(.unique) var id: Int64
    var created: Date?
    var deviceCount: Int64? = 0
    var display: String?
    var lastUpdated: Date?
    var latitude: Double? = 0.0
    var longitude: Double? = 0.0
    var name: String = ""
    var physicalAddress: String?
    var shippingAddress: String?
    var url: String?
    var group: SiteGroup?
    var region: Region?
    var tenant: Tenant?
    var status: String? // New property for status
    //Enables SiteRow to be updated in real time
    var highestSeverityStored: Int = -1
    var highestUnacknowledgedSeverityStored: Int = -1
    
    @Relationship(inverse: \Device.site)
    var devices: [Device]? = []
    
    @Relationship(deleteRule: .cascade, inverse: \Rack.site)
    var racks: [Rack]? = []
    
    init(id: Int64) {
        self.id = id
    }

    // MARK: - Location Properties
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude ?? 0, longitude: longitude ?? 0)
    }
    
    // MARK: - Device and Event Status
    
    private var monitoredDevices: [Device] {
        devices?.filter { $0.zabbixId != 0 } ?? []
    }
    
    private var activeEvents: [Event] {
        var result: [Event] = []
        for device in monitoredDevices {
            guard device.modelContext != nil, let events = device.events else { continue }
            for event in events where event.isStoreBacked && event.rClock == "0" && event.suppressed == "0" {
                result.append(event)
            }
        }
        return result
    }
    
    private var unacknowledgedActiveEvents: [Event] {
        activeEvents.filter { $0.acknowledged == "0" }
    }
    
    // MARK: - Severity Properties
    
    /// Map pins and lists read these stored fields. Walking `Event.rClock`
    /// from a live `@Query` after Delete All traps in SwiftData (invalidated
    /// backing data). Recompute from events at ingest, never in `body`.
    var highestSeverity: Int { highestSeverityStored }

    var highestUnacknowledgedSeverity: Int { highestUnacknowledgedSeverityStored }

    func refreshSeverityFromEvents() {
        if monitoredDevices.isEmpty {
            highestSeverityStored = -2
            highestUnacknowledgedSeverityStored = -1
            return
        }
        let active = activeEvents
        highestSeverityStored = active.compactMap { Int($0.severity) }.max() ?? -1
        highestUnacknowledgedSeverityStored =
            unacknowledgedActiveEvents.compactMap { Int($0.severity) }.max() ?? -1
    }
    
    // MARK: - Visual Properties
    
    var severityColor: Color {
        switch highestSeverity {
        case 0: return .gray
        case 1: return .blue
        case 2: return .yellow
        case 3: return .orange
        case 4: return .red
        case 5: return .black
        case -1: return .green
        default: return .indigo
        }
    }
    
    var unacknowledgedSeverityColor: Color {
        switch highestUnacknowledgedSeverity {
        case 0: return .gray
        case 1: return .blue
        case 2: return .yellow
        case 3: return .orange
        case 4: return .red
        case 5: return .black
        case -1: return .white
        default: return .indigo
            
        }
    }
}

