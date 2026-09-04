//
//  FrontPort.swift
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

/// Persisted NetBox front port. `deviceId` is indexed so a panel
/// elevation can load ports without walking `device.frontPorts`.
/// Optional reference ids are nil, never 0.
@Model
final class FrontPort {
    #Index<FrontPort>([\.deviceId], [\.siteId])

    @Attribute(.unique) var id: Int64
    var name: String = ""
    var display: String?
    var label: String?
    var type: String?
    var colour: String?
    var created: Date?
    var lastUpdated: Date?
    var occupied: Bool = false
    var cableId: Int64?
    var connectedEndpointId: Int64?
    var connectedEndpointName: String?
    var connectedEndpointType: String?

    /// Denormalized owner device id. Indexed. Set before insert.
    var deviceId: Int64 = 0
    var deviceName: String?
    /// Denormalized site of the owner device. Indexed. 0 when unknown.
    var siteId: Int64 = 0

    var device: Device?

    init(id: Int64) {
        self.id = id
    }

    var isCabled: Bool {
        occupied || cableId != nil
    }
}

extension FrontPort: Identifiable {}

/// Patch-panel layout is positional: index 0 is port 1. Sort by the last
/// number in the NetBox name (`"12"`, `"Port 12"`, `"Gi0/12"`) so empty
/// labels cannot shuffle the row. Tie-break on the stem, then id.
enum PortNameOrder {
    static func lessThan(
        _ leftName: String,
        id leftID: Int64,
        _ rightName: String,
        id rightID: Int64
    ) -> Bool {
        let left = parts(leftName)
        let right = parts(rightName)
        switch (left.number, right.number) {
        case let (l?, r?) where l != r:
            return l < r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if left.stem != right.stem {
            return left.stem.localizedStandardCompare(right.stem) == .orderedAscending
        }
        return leftID < rightID
    }

    /// Tiny faceplate text. `"7/1"` and `"Port 12"` become `"1"` / `"12"`
    /// so an 8-point cell does not render `"7..."`.
    static func faceplateLabel(_ name: String, fallback: Int64) -> String {
        if let number = parts(name).number {
            return String(number)
        }
        return String(fallback)
    }

    private static func parts(_ name: String) -> (stem: String, number: Int64?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var digitsStart = trimmed.endIndex
        while digitsStart > trimmed.startIndex {
            let previous = trimmed.index(before: digitsStart)
            if trimmed[previous].isNumber {
                digitsStart = previous
            } else {
                break
            }
        }
        guard digitsStart < trimmed.endIndex, let number = Int64(trimmed[digitsStart...]) else {
            return (trimmed, nil)
        }
        return (String(trimmed[..<digitsStart]), number)
    }
}
