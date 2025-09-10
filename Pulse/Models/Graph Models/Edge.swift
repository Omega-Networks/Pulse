//
//  Edge.swift
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

/**
 A proxy for two Interface entities hat represent a network connection between two devices.
 A few things to take note of:
 - The source is the Device the Interface is connecting from.
 - The destination is the Device of the Interface's connected endpoint.
 */
struct Edge: Equatable, Identifiable, Hashable {
    var id = UUID()
    var start: Interface
    var end: Interface
    
    // Since Interface is now a struct, we can rely on default Equatable
    static func == (lhs: Edge, rhs: Edge) -> Bool {
        return (lhs.start.id == rhs.start.id && lhs.end.id == rhs.end.id) ||
               (lhs.start.id == rhs.end.id && lhs.end.id == rhs.start.id)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
