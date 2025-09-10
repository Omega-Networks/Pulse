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
    @State private var isPopoverShown = false
    @State private var selectedEvent: Event?
    @Query private var devices: [Device]
    
    //Properties for the table
    @State private var sortOrder = [KeyPathComparator(\Event.formattedClock)]
    @State private var sortedEvents: [Event] = []
    @State private var selection = Set<Event.ID>()
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }
#else
    private let isCompact = false
#endif
    
    //Old solution for getting all events within a Site (still could cause problems)
    var events: [Event] {
        let events = self.devices.compactMap { device in
            device.events
        }
            .flatMap { $0 }
            .sorted(by: { $0.formattedClock > $1.formattedClock })  // sort in descending order
        
        return events
    }
    
    var selectedEvents: [Event] {
        let selectedEventIDs = selection.map { $0 }
        return events.filter { selectedEventIDs.contains($0.id) }
    }
    
    //MARK: Initialisation body
    init(site: Site) {
        self.site = site
        self.isPopoverShown = isPopoverShown
        self.selectedEvent = selectedEvent
        
        // Applying predication to devices and events
        let siteId = site.id
        self._devices = Query(filter: #Predicate<Device> { device in
            device.site?.id == siteId})
    }
    
    var body: some View {
        VStack {
            //TODO: Determine how to enable multi-selection in iOS
            Table(events, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Time", value: \.formattedClock) { value in
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
                .width(isCompact ? nil: 135)
                
                TableColumn("Severity", value: \.severityString) { value in
                    SeverityCell(severityString: value.severityString, severityColor: value.severityColor, state: value.state)
                }.width(105)
                
                TableColumn("Status", value: \.state) { value in
                    StatusCell(state: value.state, stateColor: value.stateColor)
                }.width(100)
                
                TableColumn("Device") { value in
                    Text(value.device?.name ?? "Unknown")
                }
                .width(min: 80, ideal: 100, max: 200)
                
                TableColumn("Description", value: \.name)
                    .width(min:150, ideal: 300, max: .infinity)
                
                TableColumn("Duration", value: \.timeTillResolvedOrNow)
                    .width(90)
                
                TableColumn("Ack", value: \.acknowledgedString) { value in
                    AcknowledgedCell(selectedEvents: [value], acknowledgedString: value.acknowledgedString, acknowledgedColor: value.acknowledgedColor)
                }.width(25)
            }
            .onChange(of: sortOrder) { newValue, _ in
                sortedEvents = events.sorted(using: newValue)
            }
            TableToolbar(selectedEvents: selectedEvents, events: events)
                .padding()
        }
        .onChange(of: selectedEvents) {
            print("Changes in selectedEvents detected.")
            for event in selectedEvents {
                print("Event ID: \(event.eventId)")
            }
        }
    }
}

#Preview("Event Table", traits: .modifier(PreviewData())) {
    @Previewable @Query(filter: #Predicate<Site> { $0.id == 1 }) var sites: [Site]
    
    if let previewSite = sites.first {
        EventTable(site: previewSite)
            .frame(width: 600, height: 400) // Good size for table preview
    }
}
