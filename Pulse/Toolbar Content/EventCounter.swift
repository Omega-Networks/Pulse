//
//  EventCounter.swift
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

//MARK: New Event Counter view
struct EventCounter: View {
    @Query private var devices: [Device]
    @Query private var events: [Event]
    @State private var openDevicesPopover: Bool = false
    
    private var eventsCountBySeverity: [String: Int] {
        let severityCounts = events.reduce(into: [String: Int]()) { counts, event in
            // Increment the count for the event's severity
            counts[event.severity, default: 0] += 1
        }
        return severityCounts
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Iterating over the sorted keys of the eventsCountBySeverity dictionary.
            ForEach(Array(eventsCountBySeverity.keys).sorted(), id: \.self) { severity in
                // Optional binding to check if there is a value associated with the key and the value is greater than 0.
                if let count = eventsCountBySeverity[severity], count > 0 {
                    let imageName = self.imageName(for: count)
                    
                    Image(systemName: imageName)
                        .symbolRenderingMode(.palette)
                    // Numberical count transition effect
                        .contentTransition(.symbolEffect(.replace))
                    // Appear and Disapper effect
                        .transition(.symbolEffect(.automatic))
                    // Set the font size for the image.
#if os(macOS)
                        .font(.system(size: 26))
#else
                        .font(.system(size: 20))
#endif
                    // Apply the foreground color based on the severity.
                        .foregroundStyle(Color.primary, severityColor(for: Int64(severity) ?? 0))
                    // Explicitly set the frame size for the image.
#if os(macOS)
                        .frame(width: 23.5, height: 23.5)
#else
                        .frame(width: 17, height: 17)
#endif
                }
            }
        }
        .onTapGesture {
            openDevicesPopover = true
        }
        .popover(isPresented: $openDevicesPopover, arrowEdge: .bottom) {
            DevicePopoverView()
            #if os(macOS)
                .frame(width: 300, height: 400)
            #endif
        }
    }
    
    private func imageName(for count: Int) -> String {
        // Replace with your logic to determine the image name based on count
        return count > 50 ? "exclamationmark.square.fill" : "\(count).square.fill"
    }
    
    private func severityColor(for value: Int64?) -> Color {
        guard let value = value else {
            return .indigo
        }
        
        switch value {
        case 0:
            return .gray
        case 1:
            return .blue
        case 2:
            return .yellow
        case 3:
            return .orange
        case 4:
            return .red
        case 5:
            return .black
        case -1:
            return .white
        default:
            return .indigo
        }
    }
}

// New view for the popover content
struct DevicePopoverView: View {
    @Query private var devices: [Device]
    
    var body: some View {
        List(devices.filter { $0.events?.count ?? 0 > 0 }, id: \.id) { device in
            VStack(alignment: .leading) {
                Text(device.name ?? "Unknown Device")
                    .font(.headline)
                    .padding(.bottom, 2)
                // Events are now presented in an animated List for better organization.
                ForEach(device.events ?? [], id: \.eventId) { event in
                    HStack {
                        Text(event.name)
                            .foregroundColor(.primary)
                            .font(.caption)
                        Spacer()
                        Text(event.severityString)
                            .font(.caption)
                            .foregroundColor(event.severityColor)
                            .padding(.trailing, 8)
                    }
                    .padding(.vertical, 4)
                    // Apply animations and transitions to this row.
                    .animation(.easeInOut, value: event)
                    .transition(.slide)
                    .contentShape(Rectangle()) // Makes the entire row tappable.
                }
            }
            .padding()
        }
    }
}

#Preview {
    EventCounter()
}
