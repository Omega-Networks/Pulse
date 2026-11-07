//
//  UpdateModal.swift
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

import os
import SwiftUI

/// Names and flags copied off the selected rows before the sheet's task
/// starts. The task snapshots the draft. It does not read these again,
/// and it does not hold an `Event`.
private struct ProblemUpdateSubject: Equatable, Sendable {
    var name: String
    var acknowledged: String
    var suppressed: String
}

struct UpdateModal: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zabbixWriteService) private var zabbixWriteService

    private let subjects: [ProblemUpdateSubject]
    @State private var draft: ProblemUpdateDraft

    init(events: [Event] = [], prefill: ProblemUpdateGhost? = nil) {
        if let prefill {
            subjects = []
            _draft = State(initialValue: ProblemUpdateDraft(prefill))
        } else {
            subjects = events.map {
                ProblemUpdateSubject(
                    name: $0.name,
                    acknowledged: $0.acknowledged,
                    suppressed: $0.suppressed
                )
            }
            _draft = State(initialValue: ProblemUpdateDraft(eventIds: events.map(\.eventId)))
        }
    }

    var body: some View {
        ProblemUpdateForm(
            draft: $draft,
            eventTitle: eventTitle,
            showsAcknowledge: showsAcknowledge,
            showsUnacknowledge: showsUnacknowledge,
            showsUnsuppress: showsUnsuppress,
            onUpdate: submit,
            onCancel: { dismiss() }
        )
    }

    private var eventTitle: String {
        if subjects.count == 1 { return subjects[0].name }
        let count = subjects.isEmpty ? draft.eventIds.count : subjects.count
        return "\(count) problems selected"
    }

    /// A fresh sheet follows the rows. Edit of a failed ask has no rows
    /// in hand, so every action stays available and `isValid` rejects a
    /// contradiction.
    private var showsAcknowledge: Bool {
        if subjects.isEmpty { return true }
        return subjects.contains { $0.acknowledged != "1" }
    }

    private var showsUnacknowledge: Bool {
        if subjects.isEmpty { return true }
        return subjects.contains { $0.acknowledged == "1" }
    }

    private var showsUnsuppress: Bool {
        if subjects.isEmpty { return true }
        return subjects.contains { $0.suppressed == "1" }
    }

    /// Stages the ask, then dismisses. `submit` returns once the ask is
    /// on screen. The RPC continues after the sheet is gone. The draft
    /// is a value captured before the task, so the task does not read
    /// this view's state.
    private func submit() {
        let snapshot = draft
        guard let service = zabbixWriteService else {
            Logger(subsystem: "zabbix", category: "write")
                .error("problem update has no write service")
            OperatorNoticeCenter.shared.post(OperatorNotice(
                id: "zabbix.write.unavailable",
                source: .zabbix,
                severity: .failure,
                message: "Problem update is unavailable.",
                occurredAt: Date()
            ))
            dismiss()
            return
        }
        Task {
            _ = await service.submit([ProblemUpdateIntent(draft: snapshot)])
        }
        dismiss()
    }
}
