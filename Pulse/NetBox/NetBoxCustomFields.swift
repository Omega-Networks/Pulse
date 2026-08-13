//
//  NetBoxCustomFields.swift
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
import OpenAPIRuntime

/// Typed accessors over NetBox `custom_fields` (untyped in the schema).
/// Pulse uses exactly four keys. Writes (P4) must send only changed keys.
enum NetBoxCustomFields {
    static let coordinateX = "coordinate_x"
    static let coordinateY = "coordinate_y"
    static let zabbixID = "zabbix_id"
    static let zabbixInstance = "zabbix_instance"

    static func double(from container: OpenAPIValueContainer?) -> Double? {
        guard let value = container?.value else { return nil }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? Int64 { return Double(number) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func int64(from container: OpenAPIValueContainer?) -> Int64? {
        guard let value = container?.value else { return nil }
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? Double { return Int64(number) }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func pulseFields(from fields: [String: OpenAPIValueContainer]?) -> (
        x: Double,
        y: Double,
        zabbixID: Int64,
        zabbixInstance: Int64
    ) {
        let fields = fields ?? [:]
        return (
            x: double(from: fields[coordinateX]) ?? 0,
            y: double(from: fields[coordinateY]) ?? 0,
            zabbixID: int64(from: fields[zabbixID]) ?? 0,
            zabbixInstance: int64(from: fields[zabbixInstance]) ?? 0
        )
    }
}
