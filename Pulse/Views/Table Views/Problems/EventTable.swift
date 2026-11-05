//
//  ProblemTable.swift
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
    @State private var sortOrder = [KeyPathComparator(\Event.clock, order: .reverse)]
    @State private var selection = Set<Event.ID>()
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }
#else
    private let isCompact = false
#endif
    
    /// Delete All invalidates rows this query still holds. A persisted
    /// property read on those rows traps, so every column reads this list.
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
        VStack {
            //TODO: Determine how to enable multi-selection in iOS
            Table(storedEvents.sorted(using: sortOrder), selection: seatedSelection, sortOrder: $sortOrder) {
                TableColumn("Time", value: \.clock) { value in
                    Group {
                    if isCompact {
                        HStack {
                            VStack (alignment: .leading) {
                                Text(value.device?.name ?? "Unknown")
                                    .foregroundColor(.primary)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                Text(value.name)
                                    .foregroundColor(.primary)
                                    .font(.caption)
                            }
                            Spacer()
                            
                            VStack (alignment: .trailing) {
                                Text(value.severityString)
                                    .font(.caption)
                                    .foregroundColor(value.severityColor)
                                
                                Text(value.formattedClock)
                                    .font(.caption)
                            }
                        }
                    } else {
                    #if os(macOS)
                        TimeCell(event: value)
                    #elseif os(iOS)
                        HStack {
                            VStack (alignment: .leading) {
                                Text(value.device?.name ?? "Unknown")
                                    .foregroundColor(.primary)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                Text(value.name)
                                    .foregroundColor(.primary)
                                    .font(.caption)
                            }
                            Spacer()
                            
                            VStack (alignment: .trailing) {
                                Text(value.severityString)
                                    .font(.caption)
                                    .foregroundColor(value.severityColor)
                                
                                Text(value.formattedClock)
                                    .font(.caption)
                            }
                        }
                    #endif
                    }
                    }
                    .problemAsk(pending[value.eventId]?.state)
                }
                .width(isCompact ? nil: 135)
                
                TableColumn("Severity", value: \.severityString) { value in
                    severityCell(value, pending: pending)
                }.width(105)
                
                TableColumn("Status", value: \.state) { value in
                    StatusCell(state: value.state, stateColor: value.stateColor)
                        .problemAsk(pending[value.eventId]?.state)
                }.width(100)
                
                TableColumn("Device") { value in
                    Group {
                        if isSeated(value) {
                            Text(value.device?.name ?? "Unknown")
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(value.device?.name ?? "Unknown")
                                    .foregroundStyle(.secondary)
                                SubscribeToResumeLabel()
                                    .font(.caption)
                            }
                        }
                    }
                    .problemAsk(pending[value.eventId]?.state)
                }
                .width(min: 80, ideal: 100, max: 200)
                
                TableColumn("Description", value: \.name) { value in
                    Text(value.name)
                        .problemAsk(pending[value.eventId]?.state)
                }
                .width(min:150, ideal: 300, max: .infinity)
                
                TableColumn("Duration", value: \.timeTillResolvedOrNow) { value in
                    Text(value.timeTillResolvedOrNow)
                        .problemAsk(pending[value.eventId]?.state)
                }
                .width(90)
                
                TableColumn("Ack", value: \.acknowledgedString) { value in
                    ackCell(value, pending: pending)
                }.width(25)
            }
            TableToolbar(selectedEvents: selectedEvents, events: storedEvents)
                .padding()
        }
    }

    private func isSeated(_ event: Event) -> Bool {
        guard let deviceID = event.device?.id else { return false }
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
        _ event: Event,
        item: PendingGhost<ProblemUpdateGhost>?
    ) -> (text: String, color: Color) {
        if item?.ghost.acknowledges == true {
            return ("Yes", .green)
        }
        if item?.ghost.unacknowledges == true {
            return ("No", .red)
        }
        return (event.acknowledgedString, event.acknowledgedColor)
    }

    @ViewBuilder
    private func ackCell(
        _ event: Event,
        pending: [String: PendingGhost<ProblemUpdateGhost>]
    ) -> some View {
        let item = pending[event.eventId]
        let shown = ackPresentation(event, item: item)
        shaded(
            AcknowledgedCell(
                selectedEvents: [event],
                acknowledgedString: shown.text,
                acknowledgedColor: shown.color,
                allowsUpdate: isSeated(event)
            ),
            item: item,
            fallbackHelp: isSeated(event) ? "Update event" : "Subscribe to resume"
        )
    }

    @ViewBuilder
    private func severityCell(
        _ event: Event,
        pending: [String: PendingGhost<ProblemUpdateGhost>]
    ) -> some View {
        let item = pending[event.eventId]
        let severity = item?.ghost.severity
        let name = severity.map(severityName) ?? event.severityString
        let color = severity.map(severityColor) ?? event.severityColor
        shaded(
            SeverityCell(
                severityString: name,
                severityColor: color,
                state: event.state
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

    private func severityName(_ value: Int) -> String {
        switch value {
        case 0: return "Not Classified"
        case 1: return "Information"
        case 2: return "Warning"
        case 3: return "Average"
        case 4: return "High"
        case 5: return "Disaster"
        default: return "Unknown"
        }
    }

    private func severityColor(_ value: Int) -> Color {
        switch value {
        case 0: return .gray
        case 1: return .blue
        case 2: return .yellow
        case 3: return .orange
        case 4: return .red
        case 5: return .black
        default: return .purple
        }
    }

    private var seatedSelection: Binding<Set<Event.ID>> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = Set(
                    storedEvents.filter { newValue.contains($0.id) && isSeated($0) }.map(\.id)
                )
            }
        )
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
