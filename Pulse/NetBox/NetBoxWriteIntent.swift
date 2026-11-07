//
//  NetBoxWriteIntent.swift
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
import Observation

/// Identity of one ask. The engine mints it. Views pass it back to discard.
struct WriteToken: Hashable, Sendable {
    let id: UUID

    init() {
        id = UUID()
    }
}

/// Where an ask is. `.committed` still holds the ghost until the engine's
/// next store-did-apply. `.failed` holds it until Discard.
enum WriteState: Equatable, Sendable {
    case posting
    case committed(id: Int64)
    case failed(NetBoxSyncError)
}

/// One shape for every NetBox write. `submit` does not switch on kind.
/// `perform` marks the ask committed once NetBox answers the POST, then
/// stores the object from the response body without a second GET.
protocol NetBoxWriteIntent: Sendable {
    associatedtype Body: Encodable & Sendable
    associatedtype Record: Decodable & Sendable
    associatedtype Ghost: Sendable

    static var kind: NetBoxChangeKind { get }
    var body: Body { get }
    var siteId: Int64 { get }

    func ghost(token: WriteToken) -> Ghost
    func send(through writer: NetBoxWriteService) async throws -> (record: Record, raw: Data)
    func perform(on engine: NetBoxSyncEngine, token: WriteToken) async throws
}

/// One ask a view can draw. `ghost` is the kind's own value.
struct PendingGhost<Ghost: Sendable>: Identifiable, Sendable {
    var token: WriteToken
    var ghost: Ghost
    var state: WriteState

    var id: WriteToken { token }
}

/// In-memory asks for this session. Not SwiftData, and not replayed
/// after launch. A crash drops the ask. The engine is the only mutator.
/// Interim: a site draft in build mode replaces it. See ADR 0003,
/// "Why the pending layer is here, and what comes next".
@MainActor
@Observable
final class PendingWrites {
    private var entries: [WriteToken: Entry] = [:]

    nonisolated init() {}

    func stage<I: NetBoxWriteIntent>(_ pairs: [(token: WriteToken, intent: I)]) {
        for pair in pairs {
            entries[pair.token] = Entry(
                token: pair.token,
                siteID: pair.intent.siteId,
                kind: I.kind,
                state: .posting,
                ghost: pair.intent.ghost(token: pair.token)
            )
        }
    }

    func state(of token: WriteToken) -> WriteState? {
        entries[token]?.state
    }

    func markCommitted(token: WriteToken, id: Int64) {
        guard var entry = entries[token] else { return }
        guard case .posting = entry.state else { return }
        entry.state = .committed(id: id)
        entries[token] = entry
        OperatorNoticeCenter.shared.clear(id: Self.noticeID(token))
    }

    /// Keeps the entry until Discard. A repeat for a token that has
    /// already left `.posting` does nothing, so a late error cannot
    /// cover a commit.
    @discardableResult
    func fail(token: WriteToken, error: NetBoxSyncError) -> Bool {
        guard var entry = entries[token] else { return false }
        guard case .posting = entry.state else { return false }
        entry.state = .failed(error)
        entries[token] = entry
        OperatorNoticeCenter.shared.post(
            OperatorNotice(
                id: Self.noticeID(token),
                source: .netbox,
                severity: .failure,
                message: error.noticeMessage,
                occurredAt: Date()
            )
        )
        return true
    }

    @discardableResult
    func discard(token: WriteToken) -> Bool {
        guard entries.removeValue(forKey: token) != nil else { return false }
        OperatorNoticeCenter.shared.clear(id: Self.noticeID(token))
        return true
    }

    /// Drops every committed ask. Failed asks stay.
    func retireCommitted() {
        entries = entries.filter { _, entry in
            if case .committed = entry.state { return false }
            return true
        }
    }

    func ghosts<I: NetBoxWriteIntent>(of type: I.Type, at siteID: Int64) -> [PendingGhost<I.Ghost>] {
        entries.values
            .filter { $0.kind == I.kind && $0.siteID == siteID }
            .sorted { $0.token.id.uuidString < $1.token.id.uuidString }
            .compactMap { entry in
                guard let ghost = entry.ghost as? I.Ghost else { return nil }
                return PendingGhost(token: entry.token, ghost: ghost, state: entry.state)
            }
    }

    nonisolated static func noticeID(_ token: WriteToken) -> String {
        "netbox.write.\(token.id.uuidString)"
    }

    private struct Entry {
        var token: WriteToken
        var siteID: Int64
        var kind: NetBoxChangeKind
        var state: WriteState
        var ghost: any Sendable
    }
}
