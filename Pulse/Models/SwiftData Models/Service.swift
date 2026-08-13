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

//MARK: API request for Application Service as a reference
//{
//    "id": 7,
//    "url": "https://netbox.example/api/ipam/services/7/",
//    "display": "SSH (TCP/22)",
//    "parent_object_type": "dcim.device",
//    "parent_object_id": 6023,
//    "parent": { "id": 6023, "name": "core-switch-01", "description": "Example switch" },
//    "name": "SSH",
//    "protocol": { "value": "tcp", "label": "TCP" },
//    "ports": [22],
//    "ipaddresses": [ { "id": 2275, "address": "192.0.2.10/24", "family": { "value": 4, "label": "IPv4" } } ],
//    "description": "Secure shell access"
//}

//MARK: For fetching Service from NetBox
/// A struct encapsulating the properties of a NetBox Application Service.
struct ServiceProperties: Codable {

    // MARK: Decodable

    private enum CodingKeys: String, CodingKey {
        case id, name, display, url, parent, ports, ipaddresses
        case serviceDescription = "description"
        case serviceProtocol = "protocol"
        case parentObjectType = "parent_object_type"
        case parentObjectId = "parent_object_id"
    }

    /// Nested `protocol` object. Decoded as a small `Decodable` rather than a
    /// `nestedContainer` so unknown keys are ignored and a missing field is
    /// simply nil. Fields are optional: a service is still usable if NetBox
    /// omits one.
    private struct ProtocolEntry: Decodable {
        let value: String?
        let label: String?
    }

    /// Nested `parent` object. Only `name` is needed here; the id and type come
    /// from the flat `parent_object_*` fields.
    private struct ParentEntry: Decodable {
        let name: String?
    }

    /// One element of the `ipaddresses` array. Only `address` is needed; `id`
    /// and `family` are ignored. Optional so a malformed element degrades to a
    /// nil that `compactMap` drops, rather than aborting the whole array.
    private struct IPAddressEntry: Decodable {
        let address: String?
    }

    /// Decodes `Wrapped` if the element is well-formed, otherwise yields nil
    /// without throwing, so one structurally-malformed array element does not
    /// abort decoding of the whole array and drop a service's good IPs.
    private struct FailableDecodable<Wrapped: Decodable>: Decodable {
        let value: Wrapped?
        init(from decoder: Decoder) throws {
            value = try? Wrapped(from: decoder)
        }
    }

    let id: Int64
    let name: String
    let display: String
    let url: String
    let serviceDescription: String

    let protocolValue: String
    let protocolLabel: String

    let ports: [Int]
    let ipAddresses: [String]

    let parentObjectType: String
    let parentObjectId: Int64
    let parentName: String

    /**
     Initialisation body for fetching a Service object from NetBox and decoding
     its properties from the returned JSON response.

     Unlike `DeviceProperties`, the nested objects are read with `try?` (never
     `try!`) so an omitted nested field never crashes the parse, and the parse
     does NOT require `created` / `last_updated`: the services payload carries
     no timestamps, so requiring them would reject every record.
     */
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)

        let rawId = try? values.decode(Int64.self, forKey: .id)
        let rawName = try? values.decode(String.self, forKey: .name)
        let rawDisplay = try? values.decode(String.self, forKey: .display)
        let rawURL = try? values.decode(String.self, forKey: .url)
        let rawDescription = try? values.decode(String.self, forKey: .serviceDescription)
        let rawParentObjectType = try? values.decode(String.self, forKey: .parentObjectType)
        let rawParentObjectId = try? values.decode(Int64.self, forKey: .parentObjectId)

        // `ports` is a top-level array; absent or empty is allowed.
        let rawPorts = (try? values.decode([Int].self, forKey: .ports)) ?? []

        // Nested `protocol` { value, label }.
        let protocolEntry = try? values.decode(ProtocolEntry.self, forKey: .serviceProtocol)

        // `ipaddresses` is an array of objects; keep each element's CIDR
        // `address`. Decode per element through FailableDecodable so a single
        // structurally-malformed element is skipped while the good elements are
        // retained, rather than the whole-array decode failing and dropping
        // every IP (which would null `primaryIPAddress` and lose the web target).
        let ipEntries = (try? values.decode([FailableDecodable<IPAddressEntry>].self, forKey: .ipaddresses)) ?? []
        let rawIPAddresses = ipEntries.compactMap { $0.value?.address }

        // Nested `parent` { name }.
        let parentEntry = try? values.decode(ParentEntry.self, forKey: .parent)

        // Ignore records missing the minimum required fields: without a parent
        // a service cannot be wired to a device or surfaced.
        guard let id = rawId,
              let name = rawName,
              let parentObjectType = rawParentObjectType,
              let parentObjectId = rawParentObjectId
        else {
            let logged = "id = \(rawId?.description ?? "nil"), "
            + "name = \(rawName?.description ?? "nil"), "
            + "parentObjectType = \(rawParentObjectType ?? "nil"), "
            + "parentObjectId = \(rawParentObjectId?.description ?? "nil")"

            let logger = Logger(subsystem: "netbox", category: "parsing")
            logger.debug("Ignored Service: \(logged)")

            throw SwiftDataError.missingData
        }

        self.id = id
        self.name = name
        self.display = rawDisplay ?? name
        self.url = rawURL ?? ""
        self.serviceDescription = rawDescription ?? ""
        self.protocolValue = protocolEntry?.value ?? ""
        self.protocolLabel = protocolEntry?.label ?? ""
        self.ports = rawPorts
        self.ipAddresses = rawIPAddresses
        self.parentObjectType = parentObjectType
        self.parentObjectId = parentObjectId
        self.parentName = parentEntry?.name ?? ""
    }

    //MARK: Encodable
    //
    // Service sync is read-only (GET). No push path exists for services yet, so this
    // is a minimal conformance mirroring the keyed-container style; flesh it out
    // if/when services gain a POST/PATCH path.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(ports, forKey: .ports)
    }
}
