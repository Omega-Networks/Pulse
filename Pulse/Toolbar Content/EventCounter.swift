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
/// The store answers: open, not suppressed, and not a symptom.
struct EventCounter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: Event.counted)
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
                ProblemCountGlyph(
                    symbol: square.symbol,
                    fill: Event.severityColor(for: square.severity),
                    fontSize: squareFont,
                    numberTransition: .numericText()
                )
                .transition(.scale(0.86).combined(with: .opacity))
                .frame(width: squareSide, height: squareSide)
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

    private var squareSide: CGFloat {
        #if os(macOS)
        23.5
        #else
        17
        #endif
    }

    private var squareFont: CGFloat {
        #if os(macOS)
        26
        #else
        20
        #endif
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

/// Numbered square. One digit, `Color.primary`. The shadow is centred,
/// so it spreads evenly. Its colour is the system text background:
/// white in the light appearance, black in the dark one.
struct ProblemCountGlyph: View {
    var symbol: String
    var fill: Color
    var fontSize: CGFloat
    var numberTransition: ContentTransition

    var body: some View {
        ZStack {
            Image(systemName: "square.fill")
                .font(.system(size: fontSize))
                .foregroundStyle(fill)
                .accessibilityHidden(true)
            digit
                .shadow(color: outline, radius: 1)
        }
    }

    private var digit: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.palette)
            .font(.system(size: fontSize))
            .monospacedDigit()
            .contentTransition(numberTransition)
            .foregroundStyle(Color.primary, Color.clear)
    }

    private var outline: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// Devices that currently have an active problem. Same rule as the toolbar
/// squares, so a resolved row is not listed under that count.
struct DevicePopoverView: View {
    @Query(filter: Event.counted)
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
