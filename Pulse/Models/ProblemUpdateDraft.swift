//
//  ProblemUpdateDraft.swift
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

/// What the operator asked for on one or more problems. Pure value: the
/// bitmask and the suppress rules are here, so they are unit-tested
/// without SwiftUI. Mirrors `event.acknowledge` `action` bits:
/// 1 close, 2 acknowledge, 4 message, 8 severity, 16 unacknowledge,
/// 32 suppress, 64 unsuppress. A message counts only when it is not blank.
struct ProblemUpdateDraft: Equatable, Sendable {
    enum Suppression: Equatable, Sendable {
        case none
        case indefinitely
        case until(Date)
    }

    var eventIds: [String]
    var closes = false
    var acknowledges = false
    var unacknowledges = false
    var message = ""
    var severity: Int? = nil
    var suppression: Suppression = .none
    var unsuppresses = false

    var action: Int {
        var value = 0
        if closes { value += 1 }
        if acknowledges { value += 2 }
        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value += 4 }
        if severity != nil { value += 8 }
        if unacknowledges { value += 16 }
        if suppression != .none { value += 32 }
        if unsuppresses { value += 64 }
        return value
    }

    /// `"0"` means indefinite. A chosen time is unix seconds. Nil when
    /// this ask does not suppress. Zabbix refuses a timestamp that is not
    /// in the future; `isValid` keeps that call from being sent.
    var suppressUntil: String? {
        switch suppression {
        case .none:
            return nil
        case .indefinitely:
            return "0"
        case .until(let date):
            return String(Int(date.timeIntervalSince1970))
        }
    }

    /// Why Update is disabled. Nil when the ask is one Zabbix will accept.
    var invalidReason: String? {
        if action == 0 { return "Choose at least one action" }
        if suppression != .none && unsuppresses { return "Suppress and Unsuppress cannot both be set" }
        if acknowledges && unacknowledges { return "Acknowledge and Unacknowledge cannot both be set" }
        if case .until(let date) = suppression, date <= .now { return "Suppress-until must be later than now" }
        return nil
    }

    var isValid: Bool { invalidReason == nil }

    /// `event.acknowledge` params. `action` and `suppress_until` are
    /// numbers. `0` is the number zero, which is indefinite. Nil fields
    /// are omitted so the body does not send JSON null.
    var requestBody: [String: Any] {
        var body: [String: Any] = [
            "eventids": eventIds,
            "action": action
        ]
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            body["message"] = trimmed
        }
        if let severity {
            body["severity"] = severity
        }
        switch suppression {
        case .none:
            break
        case .indefinitely:
            body["suppress_until"] = 0
        case .until(let date):
            body["suppress_until"] = Int(date.timeIntervalSince1970)
        }
        return body
    }

    init(eventIds: [String]) {
        self.eventIds = eventIds
    }

    init(_ ghost: ProblemUpdateGhost) {
        eventIds = ghost.eventIds.sorted()
        closes = ghost.closes
        acknowledges = ghost.acknowledges
        unacknowledges = ghost.unacknowledges
        message = ghost.message
        severity = ghost.severity
        suppression = ghost.suppression
        unsuppresses = ghost.unsuppresses
    }
}
