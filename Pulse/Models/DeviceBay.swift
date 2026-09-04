//
//  DeviceBay.swift
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

/// Persisted NetBox device bay. `deviceId` is the shelf (owner) and is
/// indexed. `installedDeviceId` is the occupant when one is seated.
/// Optional reference ids are nil, never 0.
@Model
final class DeviceBay {
    #Index<DeviceBay>([\.deviceId])

    @Attribute(.unique) var id: Int64
    var name: String?
    var display: String?
    var label: String?
    var created: Date?
    var lastUpdated: Date?

    /// Denormalized shelf device id. Indexed. Set before insert.
    var deviceId: Int64 = 0
    var deviceName: String?
    var installedDeviceId: Int64?
    var installedDeviceName: String?

    // Inverse declared on `Device.deviceBays`. Cascade from the shelf.
    var device: Device?

    init(id: Int64) {
        self.id = id
    }
}

extension DeviceBay: Identifiable {}
