//
//  Device.swift
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

import OSLog
import SwiftData
import SwiftUI

// MARK: - Core Data

/// Managed object subclass for the Device entity.

@Model
final class Device {
    // Secondary index on `defaultCredentialID` so the credential-delete
    // cleanup fetch resolves via the index rather than a full-table scan at
    // 1M+ devices. See the `defaultCredentialID` declaration below.
    #Index<Device>([\.defaultCredentialID])

    @Attribute(.unique) var id: Int64
    var created: Date?
    var display: String?
    var lastUpdated: Date?
    var name: String?
    var primaryIP: String?
    var serial: String?
    var url: String?
    var x: Double?
    var y: Double?
    var zabbixId: Int64 = 0
    var zabbixInstance: Int64?
    var status: String?
    
    // --- NEW PROPERTY ---
    //Property for storing camera stream URL (only applies to cameras)
    var cameraStreamURL: String?
    
    //Property to determine rack position
    var rackPosition: Float?

    // MARK: - SSH / Web preferences
    //
    // Username sits on the device (or the per-session override), not the credential:
    // one key authorises many usernames across different devices. `defaultCredentialID`
    // points at the operator's preferred `SSHCredential` for this device when one has
    // been chosen; nil means the connect sheet picks at runtime. See ADR 0001 §4.

    // Indexed (see `#Index` at the top of the model). The credential-delete
    // cleanup in `SSHCredentialsSettings.deleteCredential` runs
    // `#Predicate { $0.defaultCredentialID == id }`; the index turns that from
    // a full-table scan into an index lookup at 1M+ devices.
    var defaultCredentialID: UUID?
    var defaultUsername: String?
    var preferredSSHPort: Int?
    var preferredWebURL: String?

    // MARK: Device Model Relationships
    
    //One-To-Many
    @Relationship(deleteRule: .cascade, inverse: \Event.device)
    var events: [Event]?

    // NetBox Application Services attached to this device (inverse of
    // Service.device). VM-parented services point elsewhere and never appear
    // here. Cascade so deleting a device removes its service rows; the
    // server-authoritative stale-delete in getServices() is the primary cleanup.
    @Relationship(deleteRule: .cascade, inverse: \Service.device)
    var services: [Service]?

    // NetBox interfaces attached to this device (inverse of Interface.device).
    // Cascade so deleting a device removes its interface rows; the
    // server-authoritative stale-delete in the interface sync stage is
    // the primary cleanup.
    @Relationship(deleteRule: .cascade, inverse: \Interface.device)
    var interfaces: [Interface]?


    //Many-To-One
    var site: Site?
    var rack: Rack?
    var deviceRole: DeviceRole?
    var deviceType: DeviceType?
    
    
    init(id: Int64) {
         self.id = id
         self.localX = x ?? 150
         self.localY = y ?? 150
     }
    
    var localX: Double = 0
    var localY: Double = 0
    var highestSeverityStored: Int = -2
    var highestUnacknowledgedSeverityStored: Int = -1
    
    // MARK: - Computed Properties

    /// The bare IP address from `primaryIP`, with any trailing CIDR
    /// prefix stripped. NetBox's IPAM stores addresses in CIDR form
    /// (e.g., `172.17.255.1/32` for a host address, `2001:db8::1/64`
    /// for IPv6), but consumers that pass the value to network APIs
    /// — the SSH client, future web companion, future ping/traceroute —
    /// need the bare address, not the CIDR string.
    ///
    /// The split is on the first `/` only. IPv4 and IPv6 CIDR
    /// representations both place the prefix length after a single
    /// slash; no IP address text contains a literal `/` for any
    /// other reason. Returns nil when `primaryIP` is nil; returns an
    /// empty string when `primaryIP` is empty (caller-side guards
    /// already handle the empty case via `!isEmpty`).
    ///
    /// Display sites (Device Detail panes, the device row metadata)
    /// keep reading `primaryIP` directly — the CIDR carries subnet
    /// context that NetBox-fluent operators expect to see in
    /// informational labels. Only the network-layer call sites
    /// route through `primaryIPAddress`.
    var primaryIPAddress: String? {
        guard let primaryIP else { return nil }
        if let slash = primaryIP.firstIndex(of: "/") {
            return String(primaryIP[..<slash])
        }
        return primaryIP
    }

    // --- NEW HELPER PROPERTY ---
     var supportsCameraStream: Bool {
         return deviceRole?.id == 11 || deviceRole?.id == 35 // Camera or Edge Node
     }
    
    /// Device symbol based on its role
    var symbolName: String {
        switch deviceRole?.name {
        case "Access Switch", "Distribution Switch", "Management Switch":
            return "custom.switch"
        case "Core Switch":
            return "custom.coreswitch"
        case "Security Router", "Core Firewall", "Management Firewall":
            return "custom.securityrouter"
        case "Access Point", "Wireless Bridge":
            return "custom.wirelessap"
        case "Camera":
            return "custom.camera"
        case "Router", "Terminal Server", "Provider Edge":
            return "custom.router"
        case "Certificate":
            return "custom.scroll.fill"
        case "Digital Display":
            return "custom.inset.filled.tv"
        case "Edge Node":
            return "custom.externaldrive.fill"
        default:
            return "custom.questionmark"
        }
    }
    
    // MARK: - Event States
    
    /// Active events that are not suppressed or resolved
    private var activeEvents: [Event] {
        events?.filter {
            $0.isStoreBacked && $0.rClock == "0" && $0.suppressed == "0"
        } ?? []
    }
    
    /// Active events that have not been acknowledged
    private var unacknowledgedEvents: [Event] {
        activeEvents.filter {
            $0.acknowledged == "0"
        }
    }
    
    /// Current highest severity level among active events.
    /// Reads a stored field so map/list `body` never touches `Event.rClock`
    /// after Delete All invalidates backing data.
    var highestSeverity: Int { highestSeverityStored }

    var highestUnacknowledgedSeverity: Int { highestUnacknowledgedSeverityStored }

    func refreshSeverityFromEvents() {
        guard zabbixId != 0 else {
            highestSeverityStored = -2
            highestUnacknowledgedSeverityStored = -1
            return
        }
        let active = activeEvents
        highestSeverityStored = active.compactMap { Int($0.severity) }.max() ?? -1
        highestUnacknowledgedSeverityStored =
            unacknowledgedEvents.compactMap { Int($0.severity) }.max() ?? -1
    }
    
     /// Count of active events grouped by severity level
     var eventCountBySeverity: [String: Int] {
         guard let events = events else { return [:] }
         return events
             .filter { $0.isStoreBacked && $0.rClock == "0" }
             .reduce(into: [:]) { counts, event in
                 counts[event.severity, default: 0] += 1
             }
     }
    
    // MARK: - Visual Properties
    
    /// Color representation of the highest severity
    var severityColor: Color {
        switch highestSeverity {
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
    
    /// Color representation of the highest unacknowledged severity
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
    
    // MARK: - Helper Methods
    
    /// Converts hex color string to SwiftUI Color
    private func color(fromHex hex: String) -> Color {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Identifiable

/// SwiftUI's `WindowGroup(for: Device.ID.self)` routing and any
/// `ForEach(_:)` that doesn't take an explicit `id:` keypath require
/// `Identifiable`. `Device.id` is already `@Attribute(.unique) Int64`
/// (the NetBox primary key) which satisfies the protocol without any
/// additional work; the empty extension is a structural marker that
/// the model participates in identity-based SwiftUI APIs. ADR §9 uses
/// `WindowGroup("SSH Terminal", for: Device.ID.self)` as the entry
/// point for the operator-facing terminal, so this conformance is
/// load-bearing for the routing rather than cosmetic.
extension Device: Identifiable {}

