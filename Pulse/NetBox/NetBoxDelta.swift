//
//  NetBoxDelta.swift
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

/// Changelog kinds Pulse applies. Raw values match NetBox
/// `changed_object_type`. Order is FK order, not raw time.
enum NetBoxChangeKind: String, Sendable, CaseIterable, Comparable {
    case tenantGroup = "tenancy.tenantgroup"
    case deviceRole = "dcim.devicerole"
    case deviceType = "dcim.devicetype"
    case tenant = "tenancy.tenant"
    case region = "dcim.region"
    case siteGroup = "dcim.sitegroup"
    case site = "dcim.site"
    case location = "dcim.location"
    case rackRole = "dcim.rackrole"
    case rack = "dcim.rack"
    case device = "dcim.device"
    case deviceBay = "dcim.devicebay"
    case frontPort = "dcim.frontport"
    case interface = "dcim.interface"
    case service = "ipam.service"
    case cable = "dcim.cable"

    private var rank: Int {
        switch self {
        case .tenantGroup: return 0
        case .deviceRole: return 1
        case .deviceType: return 2
        case .tenant: return 3
        case .region: return 4
        case .siteGroup: return 5
        case .site: return 6
        case .location: return 7
        case .rackRole: return 8
        case .rack: return 9
        case .device: return 10
        case .deviceBay: return 11
        case .frontPort: return 12
        case .interface: return 13
        case .service: return 14
        case .cable: return 15
        }
    }

    static func < (lhs: NetBoxChangeKind, rhs: NetBoxChangeKind) -> Bool {
        lhs.rank < rhs.rank
    }

    init?(objectType: String) {
        if let exact = NetBoxChangeKind(rawValue: objectType) {
            self = exact
            return
        }
        switch objectType {
        case "dcim.device_role", "dcim.devicerole": self = .deviceRole
        case "dcim.device_type", "dcim.devicetype": self = .deviceType
        case "tenancy.tenant_group", "tenancy.tenantgroup": self = .tenantGroup
        case "dcim.site_group", "dcim.sitegroup": self = .siteGroup
        case "dcim.device_bay", "dcim.devicebay": self = .deviceBay
        case "dcim.front_port", "dcim.frontport": self = .frontPort
        case "dcim.rack_role", "dcim.rackrole": self = .rackRole
        default: return nil
        }
    }

    var retrievePath: String {
        switch self {
        case .tenantGroup: return "/api/tenancy/tenant-groups/"
        case .deviceRole: return "/api/dcim/device-roles/"
        case .deviceType: return "/api/dcim/device-types/"
        case .tenant: return "/api/tenancy/tenants/"
        case .region: return "/api/dcim/regions/"
        case .siteGroup: return "/api/dcim/site-groups/"
        case .site: return "/api/dcim/sites/"
        case .location: return "/api/dcim/locations/"
        case .rackRole: return "/api/dcim/rack-roles/"
        case .rack: return "/api/dcim/racks/"
        case .device: return "/api/dcim/devices/"
        case .deviceBay: return "/api/dcim/device-bays/"
        case .frontPort: return "/api/dcim/front-ports/"
        case .interface: return "/api/dcim/interfaces/"
        case .service: return "/api/ipam/services/"
        case .cable: return "/api/dcim/cables/"
        }
    }
}

struct NetBoxDeltaItem: Sendable, Equatable {
    var kind: NetBoxChangeKind
    var objectID: Int64
    var action: String
    var changeID: Int64
    var time: Date?
}

enum NetBoxDelta {
    /// Last action per (type, id), then FK order. `request_id` is ignored
    /// for sequencing — kind rank is what keeps parents before children.
    static func coalesce(_ changes: [NetBoxRecord.ObjectChange]) -> (
        items: [NetBoxDeltaItem],
        skippedUnknown: Int,
        highWater: (id: Int64, time: Date?)?
    ) {
        var latest: [String: NetBoxRecord.ObjectChange] = [:]
        var skippedUnknown = 0
        var highID: Int64 = 0
        var highTime: Date?
        for change in changes {
            if change.id > highID {
                highID = change.id
                highTime = change.time
            }
            guard NetBoxChangeKind(objectType: change.changedObjectType) != nil else {
                skippedUnknown += 1
                continue
            }
            let key = "\(change.changedObjectType):\(change.changedObjectID)"
            if let existing = latest[key], existing.id > change.id { continue }
            latest[key] = change
        }
        let items = latest.values.compactMap { change -> NetBoxDeltaItem? in
            guard let kind = NetBoxChangeKind(objectType: change.changedObjectType) else {
                return nil
            }
            return NetBoxDeltaItem(
                kind: kind,
                objectID: change.changedObjectID,
                action: change.action,
                changeID: change.id,
                time: change.time
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.objectID < rhs.objectID
        }
        let water: (id: Int64, time: Date?)? = highID > 0 ? (highID, highTime) : nil
        return (items, skippedUnknown, water)
    }
}
