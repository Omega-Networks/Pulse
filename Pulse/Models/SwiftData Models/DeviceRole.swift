//
//  DeviceRole.swift
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
import SwiftData
import OSLog
import UniformTypeIdentifiers
import SwiftUI

@Model
final class DeviceRole {
    @Attribute(.unique) var id: Int64
    var name: String? = ""
    var created: Date?
    var lastUpdated: Date?
    var colour: String?
    
    @Relationship(inverse: \Device.deviceRole)
        var devices: [Device]?
    
    init(id: Int64) {
        self.id = id
    }

    var allowedDeviceTypes: [String] {
        var allowedDeviceTypesArray: [String] = []
        
        for device in devices ?? [] {
            if let deviceType = device.deviceType {
                if let display = deviceType.model {
                    allowedDeviceTypesArray.append(display)
                }
            }
        }
        let uniqueAllowedDeviceTypes = Array(Set(allowedDeviceTypesArray)).sorted()
        return uniqueAllowedDeviceTypes
    }
    
    #if os(macOS)
    var record: DeviceRoleRecord {
        DeviceRoleRecord(deviceRole: self)
    }
    #endif

}

#if os(macOS)
struct DeviceRoleRecord: Codable, Transferable {
    let id: Int64
    let name: String
    let created: Date
    let lastUpdated: Date
    let allowedDeviceTypes: [String]
    
    init(deviceRole: DeviceRole) {
        self.id = deviceRole.id
        self.name = deviceRole.name ?? ""
        self.created = deviceRole.created ?? Date()
        self.lastUpdated = deviceRole.lastUpdated ?? Date()
        self.allowedDeviceTypes = deviceRole.allowedDeviceTypes
    }
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .deviceRoleRecord)
    }
}

extension UTType {
    static var deviceRoleRecord: UTType {
        UTType(exportedAs: "omega-networks.Pulse.DeviceRoleRecord")
    }
}

#endif

