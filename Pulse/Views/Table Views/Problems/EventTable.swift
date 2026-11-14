//
//  EventTable.swift
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



import SwiftUI
import SwiftData

struct EventTable: View {
    var site: Site
    @Query private var events: [Event]
    @Environment(LicenseSeatStore.self) private var seats
    @Environment(PendingWrites.self) private var pendingWrites
    @Environment(\.zabbixWriteService) private var zabbixWriteService
    @Environment(\.problemGhostEdit) private var problemGhostEdit

    /// `clock` is a unix-seconds string of fixed width, so string order is
    /// time order. The cell still draws `formattedClock`.
    @State private var sortOrder = [KeyPathComparator(\ProblemRowVO.clock, order: .reverse)]
    @State private var selection = Set<Event.ID>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Delete All invalidates rows this query still holds. The tree is
    /// built from this list, so a column never reads a deleted row.
    private var storedEvents: [Event] {
        events.filter(\.isStoreBacked)
    }

    var selectedEvents: [Event] {
        let selectedEventIDs = selection.map { $0 }
        return storedEvents.filter { selectedEventIDs.contains($0.id) }
    }
    
    //MARK: Initialisation body
    init(site: Site) {
        self.site = site

        let siteId = site.id
        self._events = Query(
            filter: #Predicate<Event> { $0.siteId == siteId },
            sort: [SortDescriptor(\Event.clock, order: .reverse)]
        )
    }
    
    var body: some View {
        let pending = pendingByEvent
        let rows = ProblemRowVO.tree(from: storedEvents, sortedBy: sortOrder)
        let eventsByID = Dictionary(
            storedEvents.map { ($0.persistentModelID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        VStack {
            Table(rows, children: \.symptoms, selection: seatedSelection, sortOrder: $sortOrder) {
                TableColumn("Time", value: \.clock) { row in
                    ProblemTimeCell(row: row, event: eventsByID[row.id], reduceMotion: reduceMotion)
                        .problemAsk(pending[row.eventId]?.state)
                }
                .width(135)

                TableColumn("Severity", value: \.severityString) { row in
                    severityCell(row, pending: pending)
                }.width(105)

                TableColumn("Status", value: \.state) { row in
                    StatusCell(state: row.state, stateColor: row.stateColor)
                        .problemAsk(pending[row.eventId]?.state)
                }.width(100)

                TableColumn("Device", value: \.deviceName) { row in
                    Group {
                        if isSeated(row) {
                            Text(row.deviceName)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.deviceName)
                                    .foregroundStyle(.secondary)
                                SubscribeToResumeLabel()
                                    .font(.caption)
                            }
                        }
                    }
                    .problemAsk(pending[row.eventId]?.state)
                }
                .width(min: 80, ideal: 100, max: 200)

                TableColumn("Description", value: \.name) { row in
                    ProblemDetailButton(
                        name: row.name,
                        opData: row.opData,
                        descriptionText: row.triggerDescription
                    )
                    .problemAsk(pending[row.eventId]?.state)
                }
                .width(min: 150, ideal: 300, max: .infinity)

                TableColumn("Duration", value: \.duration) { row in
                    Text(row.duration)
                        .problemAsk(pending[row.eventId]?.state)
                }
                .width(90)

                TableColumn("Ack", value: \.acknowledgedString) { row in
                    ackCell(row, event: eventsByID[row.id], pending: pending)
                }.width(25)
            }
            TableToolbar(selectedEvents: selectedEvents, problemCount: rows.count)
                .padding()
        }
    }

    private func isSeated(_ row: ProblemRowVO) -> Bool {
        guard let deviceID = row.deviceID else { return false }
        return seats.allowsActions(deviceID: deviceID)
    }

    /// Asks whose events are on this table. Built once per render from the
    /// in-memory store. O(pending). It does not fetch SwiftData.
    /// `ghosts` is oldest first, so the last ask that names an event is the
    /// one the row draws.
    private var pendingByEvent: [String: PendingGhost<ProblemUpdateGhost>] {
        let ids = Set(storedEvents.map(\.eventId))
        guard !ids.isEmpty else { return [:] }
        let pending = pendingWrites.ghosts(of: ProblemUpdateIntent.self, in: .events(ids))
        var byEvent: [String: PendingGhost<ProblemUpdateGhost>] = [:]
        byEvent.reserveCapacity(pending.count)
        for item in pending {
            for id in item.ghost.eventIds where ids.contains(id) {
                byEvent[id] = item
            }
        }
        return byEvent
    }

    private func ackPresentation(
        _ row: ProblemRowVO,
        item: PendingGhost<ProblemUpdateGhost>?
    ) -> (text: String, color: Color) {
        if item?.ghost.acknowledges == true {
            return ("Yes", .green)
        }
        if item?.ghost.unacknowledges == true {
            return ("No", .red)
        }
        return (row.acknowledgedString, row.acknowledgedColor)
    }

    @ViewBuilder
    private func ackCell(
        _ row: ProblemRowVO,
        event: Event?,
        pending: [String: PendingGhost<ProblemUpdateGhost>]
    ) -> some View {
        let item = pending[row.eventId]
        let shown = ackPresentation(row, item: item)
        let seated = isSeated(row) && event != nil
        shaded(
            AcknowledgedCell(
                selectedEvents: event.map { [$0] } ?? [],
                acknowledgedString: shown.text,
                acknowledgedColor: shown.color,
                allowsUpdate: seated
            ),
            item: item,
            fallbackHelp: seated ? "Update event" : "Subscribe to resume"
        )
    }

    @ViewBuilder
    private func severityCell(
        _ row: ProblemRowVO,
        pending: [String: PendingGhost<ProblemUpdateGhost>]
    ) -> some View {
        let item = pending[row.eventId]
        let severity = item?.ghost.severity
        let name = severity.map(Event.severityName) ?? row.severityString
        let color = severity.map { Event.severityColor(for: $0) } ?? row.severityColor
        shaded(
            SeverityCell(
                severityString: name,
                severityColor: color,
                state: row.state
            ),
            item: item,
            fallbackHelp: name
        )
    }

    /// The phase modifier stays mounted across the ask. The non-failed
    /// branches are one view, so retiring the ask does not replace the
    /// cell. Edit and Discard appear only once it has failed.
    /// Replacing the cell with `ghosted` snapped.
    @ViewBuilder
    private func shaded<Content: View>(
        _ cell: Content,
        item: PendingGhost<ProblemUpdateGhost>?,
        fallbackHelp: String
    ) -> some View {
        asked(cell, item: item, fallbackHelp: fallbackHelp)
            .problemAsk(item?.state)
    }

    @ViewBuilder
    private func asked<Content: View>(
        _ cell: Content,
        item: PendingGhost<ProblemUpdateGhost>?,
        fallbackHelp: String
    ) -> some View {
        if let item, case .failed = item.state {
            cell
                .help(failureMessage(item.state) ?? fallbackHelp)
                .contextMenu {
                    Button("Edit") {
                        problemGhostEdit.open(item.ghost)
                    }
                    Button("Discard") {
                        let token = item.token
                        Task { await zabbixWriteService?.discard(token) }
                    }
                }
        } else {
            cell.help(fallbackHelp)
        }
    }

    private func failureMessage(_ state: WriteState?) -> String? {
        if case .failed(let failure) = state { return failure.message }
        return nil
    }

    private var seatedSelection: Binding<Set<Event.ID>> {
        Binding(
            get: { selection },
            set: { newValue in
                let seated = Set(storedEvents.compactMap { event -> Event.ID? in
                    guard let deviceID = event.device?.id, seats.allowsActions(deviceID: deviceID) else {
                        return nil
                    }
                    return event.id
                })
                selection = newValue.intersection(seated)
            }
        )
    }
}

/// Clock, the symptom glyph, and the cause's symptom count. The table's
/// own disclosure is the only expander. `TimeCell` stays for the later
/// problem-detail view.
private struct ProblemTimeCell: View {
    var row: ProblemRowVO
    var event: Event?
    var reduceMotion: Bool

    var body: some View {
        HStack(spacing: 4) {
            if row.isSymptom {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Symptom")
            }
            if let event {
                TimeCell(event: event)
            } else {
                Text(row.formattedClock)
            }
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

/// Eases one cell of a problem row. The cell stays mounted. Leaving the
/// ask animates the dim back to full. A failed ask ends solid. The
/// sentence is in the help tip.
private struct ProblemRowPhase: ViewModifier {
    var state: WriteState?

    @State private var dimmed = false
    @State private var pulse = false

    private var inFlight: Bool {
        switch state {
        case .posting, .committed:
            return true
        case .failed, nil:
            return false
        }
    }

    private var shownOpacity: Double {
        guard dimmed else { return 1 }
        return pulse ? 0.85 : 0.4
    }

    func body(content: Content) -> some View {
        content
            .opacity(shownOpacity)
            .animation(.easeInOut(duration: 0.9), value: pulse)
            .onChange(of: inFlight, initial: true) { _, flying in
                if flying {
                    dimmed = true
                    pulse = false
                } else if dimmed {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        dimmed = false
                    }
                }
            }
            .task(id: inFlight) {
                guard inFlight else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(900))
                    guard !Task.isCancelled else { return }
                    pulse.toggle()
                }
            }
    }
}

private extension View {
    func problemAsk(_ state: WriteState?) -> some View {
        modifier(ProblemRowPhase(state: state))
    }
}

#if DEBUG
#Preview("Event Table", traits: .modifier(PreviewData())) {
    @Previewable @Query(filter: #Predicate<Site> { $0.id == 1 }) var sites: [Site]
    
    if let previewSite = sites.first {
        EventTable(site: previewSite)
            .environment(LicenseSeatStore())
            .environment(PendingWrites())
            .frame(width: 600, height: 400)
    }
}
#endif
