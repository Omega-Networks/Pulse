//
//  ZabbixWriteIntent.swift
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

/// The Zabbix refinement. `submit` on `ZabbixWriteService` requires it.
protocol ZabbixWriteIntent: WriteIntent {
    func send(through service: ZabbixWriteService) async throws -> [String]
    func perform(on service: ZabbixWriteService, token: WriteToken) async throws
}

extension ZabbixWriteIntent {
    static var provider: WriteProvider { .zabbix }
}

/// What the problems table shades for events whose update Zabbix has not
/// answered. `message` and `unsuppresses` are here so Edit can rebuild the
/// ask the operator typed.
struct ProblemUpdateGhost: Equatable, Sendable, Identifiable {
    var token: WriteToken
    var eventIds: Set<String>
    var acknowledges: Bool
    var unacknowledges: Bool
    var closes: Bool
    var message: String
    var severity: Int?
    var suppression: ProblemUpdateDraft.Suppression
    var unsuppresses: Bool

    var id: WriteToken { token }
}

struct ProblemUpdateIntent: ZabbixWriteIntent {
    static let kindName = "problem.update"

    let draft: ProblemUpdateDraft

    var scope: WriteScope { .events(Set(draft.eventIds)) }

    func ghost(token: WriteToken) -> ProblemUpdateGhost {
        ProblemUpdateGhost(
            token: token,
            eventIds: Set(draft.eventIds),
            acknowledges: draft.acknowledges,
            unacknowledges: draft.unacknowledges,
            closes: draft.closes,
            message: draft.message,
            severity: draft.severity,
            suppression: draft.suppression,
            unsuppresses: draft.unsuppresses
        )
    }

    func send(through service: ZabbixWriteService) async throws -> [String] {
        try await service.acknowledge(draft)
    }

    func perform(on service: ZabbixWriteService, token: WriteToken) async throws {
        try await service.runProblemUpdate(self, token: token)
    }
}
