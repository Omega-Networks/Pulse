//
//  NetBoxGeo.swift
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

/// Site-create pin hygiene. NetBox `physical_address` is 200 chars;
/// latitude is 8 significant digits, longitude 9.
enum NetBoxGeo {
    static let addressLimit = 200

    static func physicalAddress(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(addressLimit))
    }

    static func latitude(_ value: Double) -> Double { rounded(value, places: 5) }

    static func longitude(_ value: Double) -> Double { rounded(value, places: 5) }

    /// Longest region name that appears in the address, case-insensitive.
    static func suggestedRegionID(
        regions: [(id: Int64, name: String)],
        address: String
    ) -> Int64? {
        let hay = address.lowercased()
        let hits = regions.filter { region in
            let name = region.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && hay.contains(name.lowercased())
        }
        return hits.max(by: { $0.name.count < $1.name.count })?.id
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }
}
