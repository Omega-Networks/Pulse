//
//  WriteIntent.swift
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

/// Identity of one ask. The owning engine or service mints it. Views pass it back to discard.
struct WriteToken: Hashable, Sendable {
    let id: UUID

    init() {
        id = UUID()
    }
}

/// Which system an ask goes to. Drives the notice id and source.
enum WriteProvider: String, Sendable, Equatable {
    case netbox
    case zabbix

    var noticeSource: OperatorNotice.Source {
        switch self {
        case .netbox: return .netbox
        case .zabbix: return .zabbix
        }
    }
}

/// What a surface filters on. A site graph asks for `.site`. A problems
/// table asks for `.events`. A kind matches one scope shape.
enum WriteScope: Hashable, Sendable {
    case site(Int64)
    case events(Set<String>)

    /// True when `other` is inside this scope. `.events` matches on any shared id.
    func overlaps(_ other: WriteScope) -> Bool {
        switch (self, other) {
        case (.site(let a), .site(let b)):
            return a == b
        case (.events(let a), .events(let b)):
            return !a.isDisjoint(with: b)
        default:
            return false
        }
    }
}

/// The provider's own sentence for a refused ask. The store and the
/// modifier never see the provider's error type.
struct WriteFailure: Equatable, Sendable {
    var provider: WriteProvider
    var message: String
}

/// Where an ask is. `.committed` still holds the ghost until the owner's
/// next store-did-apply. `.failed` holds it until Discard.
enum WriteState: Equatable, Sendable {
    case posting
    case committed(id: Int64)
    case failed(WriteFailure)
}

/// One shape for every ask, whatever it goes to. The store keys on these.
protocol WriteIntent: Sendable {
    associatedtype Ghost: Sendable

    static var provider: WriteProvider { get }
    /// Stable per kind, used only to filter ghosts and to log.
    static var kindName: String { get }
    var scope: WriteScope { get }

    func ghost(token: WriteToken) -> Ghost
}

/// One ask a view can draw. `ghost` is the kind's own value.
struct PendingGhost<Ghost: Sendable>: Identifiable, Sendable {
    var token: WriteToken
    var ghost: Ghost
    var state: WriteState

    var id: WriteToken { token }
}

/// In-memory asks for this session, every provider. Not SwiftData, and not
/// replayed after launch. A crash drops the ask. The owning engine or service
/// is the only mutator.
/// Interim: a site draft in build mode replaces it. See ADR 0003,
/// "Why the pending layer is here, and what comes next".
@MainActor
@Observable
final class PendingWrites {
    private var entries: [WriteToken: Entry] = [:]
    private var nextSequence: UInt64 = 0

    nonisolated init() {}

    func stage<I: WriteIntent>(_ pairs: [(token: WriteToken, intent: I)]) {
        for pair in pairs {
            nextSequence += 1
            entries[pair.token] = Entry(
                token: pair.token,
                provider: I.provider,
                kindName: I.kindName,
                scope: pair.intent.scope,
                state: .posting,
                sequence: nextSequence,
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
        OperatorNoticeCenter.shared.clear(id: Self.noticeID(entry.provider, token))
    }

    /// Keeps the entry until Discard. A repeat for a token that has
    /// already left `.posting` does nothing, so a late error cannot
    /// cover a commit.
    @discardableResult
    func fail(token: WriteToken, failure: WriteFailure) -> Bool {
        guard var entry = entries[token] else { return false }
        guard case .posting = entry.state else { return false }
        entry.state = .failed(failure)
        entries[token] = entry
        OperatorNoticeCenter.shared.post(
            OperatorNotice(
                id: Self.noticeID(entry.provider, token),
                source: entry.provider.noticeSource,
                severity: .failure,
                message: failure.message,
                occurredAt: Date()
            )
        )
        return true
    }

    @discardableResult
    func discard(token: WriteToken) -> Bool {
        guard let entry = entries.removeValue(forKey: token) else { return false }
        OperatorNoticeCenter.shared.clear(id: Self.noticeID(entry.provider, token))
        return true
    }

    /// Drops committed asks for one provider. Failed asks stay. A NetBox
    /// apply must not retire a Zabbix ask that is still waiting on its re-fetch.
    func retireCommitted(provider: WriteProvider) {
        entries = entries.filter { _, entry in
            if entry.provider == provider, case .committed = entry.state { return false }
            return true
        }
    }

    /// Oldest first. The sequence is assigned in `stage` and is not a UUID,
    /// so a row that keeps one ask per event can keep the last.
    func ghosts<I: WriteIntent>(of type: I.Type, in scope: WriteScope) -> [PendingGhost<I.Ghost>] {
        entries.values
            .filter { $0.provider == I.provider && $0.kindName == I.kindName && $0.scope.overlaps(scope) }
            .sorted { $0.sequence < $1.sequence }
            .compactMap { entry in
                guard let ghost = entry.ghost as? I.Ghost else { return nil }
                return PendingGhost(token: entry.token, ghost: ghost, state: entry.state)
            }
    }

    nonisolated static func noticeID(_ provider: WriteProvider, _ token: WriteToken) -> String {
        "\(provider.rawValue).write.\(token.id.uuidString)"
    }

    private struct Entry {
        var token: WriteToken
        var provider: WriteProvider
        var kindName: String
        var scope: WriteScope
        var state: WriteState
        var sequence: UInt64
        var ghost: any Sendable
    }
}
