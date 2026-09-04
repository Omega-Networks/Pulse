//
//  Service.swift
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

/// Managed object subclass for the NetBox Application Service entity.

@Model
final class Service {
    @Attribute(.unique) var id: Int64
    var name: String?
    var display: String?
    var url: String?
    var serviceDescription: String?

    // `protocol` is a Swift keyword, so the nested protocol object's `value`
    // and `label` are stored under prefixed names.
    var protocolValue: String?
    var protocolLabel: String?

    // NetBox returns `ports` as a top-level array and `ipaddresses` as an
    // array of objects. SwiftData persists `[Int]` / `[String]` directly as
    // Codable attributes, so no child models or transformers are needed for
    // data that is only ever read as "the ports / IPs of this service".
    var ports: [Int] = []
    var ipAddresses: [String] = []

    // MARK: - Parent linkage (migration-proof)
    //
    // A NetBox service is attached to a parent that is either a `dcim.device`
    // or a `virtualization.virtualmachine`. The parent is stored generically
    // (`parentObjectType` / `parentObjectId` / `parentName`) so VM-parented
    // services are retained at full fidelity today, and a real `device`
    // relationship is wired only for device parents. When a VirtualMachine
    // model later arrives, adding a `virtualMachine` relationship alongside is
    // an additive SwiftData change that needs no VersionedSchema / MigrationPlan,
    // and the generic fields mean no backfill is ever required. See ADR 0001
    // (see ADR 0001).

    /// NetBox `parent_object_type`, e.g. `"dcim.device"` or
    /// `"virtualization.virtualmachine"`. Drives which typed relationship is
    /// wired at sync time.
    var parentObjectType: String?
    /// NetBox `parent_object_id` (the parent device or VM id).
    var parentObjectId: Int64 = 0
    /// Parent display name, carried verbatim so VM-parented services (which
    /// have no `device` relationship yet) still surface a name.
    var parentName: String?

    // MARK: Service Model Relationships

    // Many-To-One. Wired only when `parentObjectType == "dcim.device"`; nil for
    // VM parents by design, not by data loss. Inverse declared on
    // `Device.services`.
    var device: Device?

    init(id: Int64) {
        self.id = id
    }

    // MARK: - Computed Properties

    /// The bare IP address of the first associated IP, with any trailing CIDR
    /// prefix stripped. Mirrors `Device.primaryIPAddress`: NetBox's IPAM stores
    /// addresses in CIDR form (e.g. `192.0.2.10/24`), but the web companion
    /// and other network call sites need the bare address, not the CIDR string.
    /// The split is on the first `/` only; no IP address text contains a literal
    /// `/` for any other reason. Returns nil when there are no addresses.
    var primaryIPAddress: String? {
        guard let first = ipAddresses.first else { return nil }
        if let slash = first.firstIndex(of: "/") {
            return String(first[..<slash])
        }
        return first
    }
}

// MARK: - Identifiable

/// Matches `Device` / `Site`: `id` is already `@Attribute(.unique) Int64` (the
/// NetBox primary key), so the empty extension just marks that the model
/// participates in identity-based SwiftUI APIs.
extension Service: Identifiable {}

