//
//  ProblemRowVO.swift
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
import SwiftUI

/// One problems-table row. `symptoms` is nil when the row has nothing to
/// disclose: a symptom, or a cause with none.
struct ProblemRowVO: Identifiable, Hashable {
    let id: PersistentIdentifier
    let eventId: String
    let clock: String
    let formattedClock: String
    let severity: String
    let severityString: String
    let state: String
    let deviceName: String
    let deviceID: Int64?
    let name: String
    let opData: String
    let triggerDescription: String
    let acknowledged: String
    let acknowledgedString: String
    let duration: String
    let isSymptom: Bool
    var symptoms: [ProblemRowVO]?

    var symptomCount: Int { symptoms?.count ?? 0 }

    var severityColor: Color {
        Event.severityColor(for: Int(severity) ?? -1)
    }

    var acknowledgedColor: Color {
        switch Int(acknowledged) {
        case 0: return .red
        case 1: return .green
        default: return .purple
        }
    }

    var stateColor: Color {
        switch state {
        case "RESOLVED": return .green
        case "SUPPRESSED": return .primary
        default: return .red
        }
    }

    /// Causes at the root, each with its symptoms. A symptom whose cause
    /// is not in `events` stays at the root and stays a symptom. Two levels
    /// only. Rows Delete All has invalidated are skipped.
    static func tree(
        from events: [Event],
        sortedBy order: [KeyPathComparator<ProblemRowVO>]
    ) -> [ProblemRowVO] {
        let stored = events.filter(\.isStoreBacked)
        var causeIDs = Set<String>()
        var rows: [String: ProblemRowVO] = [:]
        rows.reserveCapacity(stored.count)
        for event in stored {
            rows[event.eventId] = ProblemRowVO(event)
            if !event.isSymptom {
                causeIDs.insert(event.eventId)
            }
        }

        var children: [String: [ProblemRowVO]] = [:]
        var roots: [ProblemRowVO] = []
        roots.reserveCapacity(stored.count)
        for event in stored {
            guard let row = rows[event.eventId] else { continue }
            if event.isSymptom, causeIDs.contains(event.causeEventId) {
                children[event.causeEventId, default: []].append(row)
            } else {
                roots.append(row)
            }
        }

        let nested = roots.map { root in
            var copy = root
            if let kids = children[root.eventId], !kids.isEmpty {
                copy.symptoms = ordered(kids, by: order)
            }
            return copy
        }
        return ordered(nested, by: order)
    }

    private static func ordered(
        _ rows: [ProblemRowVO],
        by order: [KeyPathComparator<ProblemRowVO>]
    ) -> [ProblemRowVO] {
        guard !order.isEmpty else { return rows }
        return rows.sorted(using: order)
    }

    fileprivate init(_ event: Event) {
        id = event.persistentModelID
        eventId = event.eventId
        clock = event.clock
        formattedClock = event.formattedClock
        severity = event.severity
        severityString = event.severityString
        state = event.state
        deviceName = event.device?.name ?? "Unknown"
        deviceID = event.device?.id
        name = event.name
        opData = event.opData
        triggerDescription = event.triggerDescription ?? ""
        acknowledged = event.acknowledged
        acknowledgedString = event.acknowledgedString
        duration = event.timeTillResolvedOrNow
        isSymptom = event.isSymptom
        symptoms = nil
    }
}
