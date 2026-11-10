//
//  ProblemsSection.swift
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

import SwiftData
import SwiftUI

#if os(iOS)

/// The site's problems: causes, each with its symptoms. Read-only.
/// The tree is the same one the macOS table uses.
struct ProblemsSection: View {
    @Query private var events: [Event]

    init(siteId: Int64) {
        _events = Query(filter: #Predicate<Event> { $0.siteId == siteId })
    }

    private var rows: [ProblemRowVO] {
        ProblemRowVO.tree(
            from: events,
            sortedBy: [KeyPathComparator(\ProblemRowVO.clock, order: .reverse)]
        )
    }

    var body: some View {
        Section("Problems") {
            OutlineGroup(rows, children: \.symptoms) { row in
                ProblemListRow(row: row)
            }
        }
    }
}

/// One problem on iPhone and iPad. The disclosure is the list's own.
private struct ProblemListRow: View {
    var row: ProblemRowVO

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(row.severityColor)
                .frame(width: 4, height: 28)
                .accessibilityLabel(row.severityString)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.formattedClock)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if row.isSymptom {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Symptom")
                    }
                    ProblemDetailButton(
                        name: row.name,
                        opData: row.opData,
                        descriptionText: row.triggerDescription
                    )
                    if row.symptomCount > 0 {
                        Text(row.symptomCount, format: .number)
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(row.symptomCount) symptoms")
                    }
                }
            }
        }
    }
}

#endif
