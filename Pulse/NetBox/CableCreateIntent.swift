//
//  CableCreateIntent.swift
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

/// POST `/api/dcim/cables/` between two interfaces. The ghost is the
/// edge the site graph already draws. `perform` calls the engine's
/// cable path, which calls `send`.
struct CableCreateIntent: NetBoxWriteIntent {
    static var kind: NetBoxChangeKind { .cable }

    var body: NetBoxWriteBody.CableCreate
    var siteId: Int64
    var ends: Edge

    var aInterfaceID: Int64? { Self.interfaceID(body.aTerminations) }
    var bInterfaceID: Int64? { Self.interfaceID(body.bTerminations) }

    func ghost(token: WriteToken) -> Edge { ends }

    func send(
        through writer: NetBoxWriteService
    ) async throws -> (record: NetBoxRecord.Cable, raw: Data) {
        try await writer.createCable(body)
    }

    func perform(on engine: NetBoxSyncEngine, token: WriteToken) async throws {
        try await engine.runCableCreate(self, token: token)
    }

    private static func interfaceID(
        _ terminations: [NetBoxWriteBody.Termination]
    ) -> Int64? {
        guard terminations.count == 1, terminations[0].objectType == "dcim.interface" else {
            return nil
        }
        return terminations[0].objectID
    }
}
