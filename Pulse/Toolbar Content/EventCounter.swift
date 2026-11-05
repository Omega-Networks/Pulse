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

/// Squares for active problems. Severity is the index, 0...5.
/// The store answers: still open, and not suppressed.
struct EventCounter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<Event> { $0.rClock == "0" && $0.suppressed == "0" })
    private var activeEvents: [Event]
    @State private var openDevicesPopover: Bool = false

    /// Same spring as a device row. Reduce Motion holds the squares still.
    private var squareMotion: Animation? {
        reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.32)
    }

    /// One square per severity that has an active problem.
    /// Identity is the severity, so a count change keeps the same square.
    private var squares: [Square] {
        var counts = [0, 0, 0, 0, 0, 0]
        for event in activeEvents where event.isStoreBacked {
            guard let severity = Int(event.severity), (0...5).contains(severity) else { continue }
            counts[severity] += 1
        }
        return (0..<6).compactMap { severity in
            let count = counts[severity]
            guard count > 0 else { return nil }
            return Square(severity: severity, count: count)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(squares) { square in
                Image(systemName: square.symbol)
                    .symbolRenderingMode(.palette)
#if os(macOS)
                    .font(.system(size: 26))
#else
                    .font(.system(size: 20))
#endif
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .transition(.scale(0.86).combined(with: .opacity))
                    .foregroundStyle(Color.primary, severityColor(for: Int64(square.severity)))
#if os(macOS)
                    .frame(width: 23.5, height: 23.5)
#else
                    .frame(width: 17, height: 17)
#endif
            }
        }
        .animation(squareMotion, value: squares)
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

/// One toolbar square. `id` is the severity, so the digit can change
/// without the square being a new view.
private struct Square: Equatable, Identifiable {
    var severity: Int
    var count: Int
    var id: Int { severity }
    var symbol: String {
        count > 50 ? "exclamationmark.square.fill" : "\(count).square.fill"
    }
}

/// Devices that currently have an active problem. Same rule as the toolbar
/// squares, so a resolved row is not listed under that count.
struct DevicePopoverView: View {
    @Query(filter: #Predicate<Event> { $0.rClock == "0" && $0.suppressed == "0" })
    private var activeEvents: [Event]

    var body: some View {
        List(openDevices) { row in
            VStack(alignment: .leading) {
                Text(row.device.name ?? "Unknown Device")
                    .font(.headline)
                    .padding(.bottom, 2)
                ForEach(row.events, id: \.eventId) { event in
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
                    .contentShape(Rectangle())
                }
            }
            .padding()
        }
    }

    private var openDevices: [OpenDevice] {
        var grouped: [PersistentIdentifier: OpenDevice] = [:]
        var order: [PersistentIdentifier] = []
        for event in activeEvents where event.isStoreBacked {
            guard let device = event.device else { continue }
            let id = device.persistentModelID
            if var row = grouped[id] {
                row.events.append(event)
                grouped[id] = row
            } else {
                order.append(id)
                grouped[id] = OpenDevice(device: device, events: [event])
            }
        }
        return order.compactMap { grouped[$0] }.sorted {
            ($0.device.name ?? "") < ($1.device.name ?? "")
        }
    }
}

private struct OpenDevice: Identifiable {
    var device: Device
    var events: [Event]
    var id: PersistentIdentifier { device.persistentModelID }
}

#Preview {
    EventCounter()
}
