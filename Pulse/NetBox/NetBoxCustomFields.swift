//
//  NetBoxCustomFields.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
