//
//  NetBoxWriteBodies.swift
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

/// Hand-written write bodies. Generated `PatchedWritable*Request` types
/// are not `Encodable` (empty `oneOf` in the NetBox 4.6.2 schema).
/// Encode only present keys; `custom_fields` must contain only the keys
/// the operator changed.
enum NetBoxWriteBody {
    enum JSONValue: Encodable, Equatable, Sendable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case null

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }

    struct InterfacePatch: Encodable, Equatable, Sendable {
        var enabled: Bool?
        /// `nil` omits the key. `""` is a clear — it must be sent.
        var description: String?
        var customFields: [String: JSONValue]?

        enum CodingKeys: String, CodingKey {
            case enabled, description
            case customFields = "custom_fields"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(enabled, forKey: .enabled)
            // encodeIfPresent would also keep "", but spell it out so a
            // clear cannot be "fixed" back into an omit.
            if let description {
                try container.encode(description, forKey: .description)
            }
            try container.encodeIfPresent(customFields, forKey: .customFields)
        }
    }

    struct Termination: Encodable, Equatable, Sendable {
        var objectType: String
        var objectID: Int64

        enum CodingKeys: String, CodingKey {
            case objectType = "object_type"
            case objectID = "object_id"
        }

        static func interface(_ id: Int64) -> Termination {
            Termination(objectType: "dcim.interface", objectID: id)
        }

        static func frontPort(_ id: Int64) -> Termination {
            Termination(objectType: "dcim.frontport", objectID: id)
        }
    }

    struct CableCreate: Encodable, Equatable, Sendable {
        var aTerminations: [Termination]
        var bTerminations: [Termination]
        var status: String?

        enum CodingKeys: String, CodingKey {
            case aTerminations = "a_terminations"
            case bTerminations = "b_terminations"
            case status
        }

        static func connecting(_ a: Int64, to b: Int64) -> CableCreate {
            CableCreate(
                aTerminations: [.interface(a)],
                bTerminations: [.interface(b)],
                status: nil
            )
        }

        static func connectingFrontPort(_ a: Int64, toInterface b: Int64) -> CableCreate {
            CableCreate(
                aTerminations: [.frontPort(a)],
                bTerminations: [.interface(b)],
                status: nil
            )
        }

        static func connectingFrontPorts(_ a: Int64, to b: Int64) -> CableCreate {
            CableCreate(
                aTerminations: [.frontPort(a)],
                bTerminations: [.frontPort(b)],
                status: nil
            )
        }
    }

    struct DevicePatch: Encodable, Equatable, Sendable {
        var name: String?
        var status: String?
        var rack: Int64?
        var position: Float?
        var face: String?
        var customFields: [String: JSONValue]?
        /// Send `rack` and `position` as JSON null (unrack).
        var clearRack: Bool = false

        enum CodingKeys: String, CodingKey {
            case name, status, rack, position, face
            case customFields = "custom_fields"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encodeIfPresent(face, forKey: .face)
            if clearRack {
                try container.encodeNil(forKey: .rack)
                try container.encodeNil(forKey: .position)
            } else {
                try container.encodeIfPresent(rack, forKey: .rack)
                try container.encodeIfPresent(position, forKey: .position)
            }
            try container.encodeIfPresent(customFields, forKey: .customFields)
        }
    }

    struct DeviceCreate: Encodable, Equatable, Sendable {
        var name: String
        var deviceType: Int64
        var role: Int64
        var site: Int64
        var status: String? = nil
        var rack: Int64? = nil
        var position: Float? = nil
        var face: String? = nil
        var tenant: Int64? = nil
        var customFields: [String: JSONValue]? = nil

        enum CodingKeys: String, CodingKey {
            case name, role, site, status, rack, position, face, tenant
            case deviceType = "device_type"
            case customFields = "custom_fields"
        }
    }

    struct RackCreate: Encodable, Equatable, Sendable {
        var name: String
        var site: Int64
        var status: String? = "active"
        var uHeight: Int64
        var startingUnit: Int64? = nil
        var formFactor: String? = nil
        var width: Int? = nil
        var mountingDepth: Int? = nil
        var outerWidth: Int? = nil
        var outerHeight: Int? = nil
        var outerDepth: Int? = nil
        var outerUnit: String? = nil
        var airflow: String? = nil
        var facilityId: String? = nil
        var serial: String? = nil
        var description: String? = nil
        var descUnits: Bool? = nil
        var tenant: Int64? = nil
        var location: Int64? = nil
        var role: Int64? = nil
        var weight: Double? = nil
        var maxWeight: Int? = nil
        var weightUnit: String? = nil

        enum CodingKeys: String, CodingKey {
            case name, site, status, width, airflow, serial, description, tenant, location, role, weight
            case uHeight = "u_height"
            case startingUnit = "starting_unit"
            case formFactor = "form_factor"
            case mountingDepth = "mounting_depth"
            case outerWidth = "outer_width"
            case outerHeight = "outer_height"
            case outerDepth = "outer_depth"
            case outerUnit = "outer_unit"
            case facilityId = "facility_id"
            case descUnits = "desc_units"
            case maxWeight = "max_weight"
            case weightUnit = "weight_unit"
        }
    }

    struct SiteCreate: Encodable, Equatable, Sendable {
        var name: String
        var slug: String
        var status: String
        var timeZone: String? = nil
        var description: String? = nil
        var physicalAddress: String? = nil
        var shippingAddress: String? = nil
        var latitude: Double? = nil
        var longitude: Double? = nil
        var region: Int64? = nil
        var group: Int64? = nil
        var tenant: Int64? = nil
        var customFields: [String: JSONValue]? = nil

        enum CodingKeys: String, CodingKey {
            case name, slug, status, description, latitude, longitude, region, group, tenant
            case timeZone = "time_zone"
            case physicalAddress = "physical_address"
            case shippingAddress = "shipping_address"
            case customFields = "custom_fields"
        }

        static func slug(from name: String) -> String {
            let lowered = name.lowercased()
            let dashed = lowered.replacingOccurrences(of: " ", with: "-")
            return dashed.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

enum NetBoxWriteJSON {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
