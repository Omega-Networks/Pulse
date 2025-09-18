//
//  PowerSenseStatisticsOverlay.swift
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
import Charts

/// Statistical overlay displaying real-time KPIs for PowerSense monitoring
///
/// **PRIVACY**: All statistics are based on aggregated data only
struct PowerSenseStatisticsOverlay: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var recentEvents: [PowerSenseEvent]

    @State private var totalAffected: Int = 0
    @State private var restorationRate: Double = 0
    @State private var averageOutageDuration: TimeInterval = 0
    @State private var trendDirection: TrendDirection = .stable
    @State private var confidenceLevel: Double = 0
    @State private var lastUpdated = Date()

    @State private var isExpanded = false
    @State private var selectedTimeRange: TimeRange = .hour1

    enum TrendDirection {
        case improving, worsening, stable

        var icon: String {
            switch self {
            case .improving: return "arrow.down.circle.fill"
            case .worsening: return "arrow.up.circle.fill"
            case .stable: return "equal.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .improving: return .green
            case .worsening: return .red
            case .stable: return .orange
            }
        }
    }

    enum TimeRange: String, CaseIterable {
        case minute15 = "15m"
        case minute30 = "30m"
        case hour1 = "1h"
        case hour6 = "6h"
        case hour24 = "24h"

        var seconds: TimeInterval {
            switch self {
            case .minute15: return 900
            case .minute30: return 1800
            case .hour1: return 3600
            case .hour6: return 21600
            case .hour24: return 86400
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Compact header
            compactHeader

            // Main KPIs
            if isExpanded {
                expandedKPIs
                Divider()
                trendChart
                Divider()
                confidenceIndicator
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 4)
        .frame(maxWidth: isExpanded ? 400 : 300)
        .animation(.easeInOut, value: isExpanded)
        .task {
            await updateStatistics()
        }
        .refreshable {
            await updateStatistics()
        }
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        HStack {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .overlay {
                    Circle()
                        .stroke(Color.white, lineWidth: 1)
                }
                .animation(.easeInOut(duration: 1).repeatForever(), value: lastUpdated)

            Text("PowerSense Monitor")
                .font(.headline)

            Spacer()

            // Trend indicator
            Image(systemName: trendDirection.icon)
                .foregroundStyle(trendDirection.color)
                .font(.system(size: 14))

            // Expand/collapse button
            Button(action: { isExpanded.toggle() }) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12))
            }
        }

        // Quick stats in compact mode
        if !isExpanded {
            HStack(spacing: 16) {
                quickStat("Affected", value: totalAffected.formatted())
                quickStat("Rate", value: "\(Int(restorationRate * 100))%")
                quickStat("MTTR", value: formatDuration(averageOutageDuration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Expanded KPIs

    private var expandedKPIs: some View {
        VStack(spacing: 12) {
            // Time range selector
            Picker("Time Range", selection: $selectedTimeRange) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedTimeRange) { _, _ in
                Task { await updateStatistics() }
            }

            // KPI Grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                kpiCard(
                    title: "Total Affected",
                    value: totalAffected.formatted(),
                    icon: "bolt.slash.fill",
                    color: .red
                )

                kpiCard(
                    title: "Restoration Rate",
                    value: "\(Int(restorationRate * 100))%",
                    icon: "arrow.clockwise",
                    color: .green
                )

                kpiCard(
                    title: "Avg Duration",
                    value: formatDuration(averageOutageDuration),
                    icon: "clock.fill",
                    color: .orange
                )

                kpiCard(
                    title: "Active Outages",
                    value: countActiveOutages().formatted(),
                    icon: "exclamationmark.triangle.fill",
                    color: .yellow
                )
            }
        }
    }

    // MARK: - KPI Card

    private func kpiCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Quick Stat

    private func quickStat(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundStyle(.tertiary)
            Text(value)
                .fontWeight(.medium)
        }
    }

    // MARK: - Trend Chart

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Outage Trend")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(generateTrendData(), id: \.time) { dataPoint in
                    LineMark(
                        x: .value("Time", dataPoint.time),
                        y: .value("Outages", dataPoint.count)
                    )
                    .foregroundStyle(.red.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", dataPoint.time),
                        y: .value("Outages", dataPoint.count)
                    )
                    .foregroundStyle(.red.opacity(0.1).gradient)
                    .interpolationMethod(.catmullRom)
                }
            }
            .frame(height: 80)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3))
            }
        }
    }

    // MARK: - Confidence Indicator

    private var confidenceIndicator: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Data Confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int(confidenceLevel * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(confidenceGradient)
                        .frame(width: geometry.size.width * confidenceLevel, height: 4)
                }
            }
            .frame(height: 4)

            Text(confidenceDescription)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Computed Properties

    private var statusColor: Color {
        switch totalAffected {
        case 0: return .green
        case 1..<100: return .yellow
        case 100..<1000: return .orange
        default: return .red
        }
    }

    private var confidenceGradient: LinearGradient {
        LinearGradient(
            colors: [.red, .orange, .yellow, .green],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var confidenceDescription: String {
        switch confidenceLevel {
        case 0..<0.3: return "Low confidence - limited data available"
        case 0.3..<0.7: return "Moderate confidence - partial coverage"
        case 0.7..<0.9: return "Good confidence - most areas covered"
        default: return "High confidence - comprehensive coverage"
        }
    }

    // MARK: - Data Methods

    private func updateStatistics() async {
        // Calculate statistics from recent events
        let cutoffTime = Date().addingTimeInterval(-selectedTimeRange.seconds)

        // Filter recent events
        let relevantEvents = recentEvents.filter { $0.timestamp > cutoffTime }

        // Calculate KPIs
        await MainActor.run {
            // Total affected (unique devices with power lost events)
            let affectedDevices = Set(relevantEvents
                .filter { $0.eventType == .powerLost }
                .compactMap { $0.device?.deviceId })
            totalAffected = affectedDevices.count

            // Restoration rate
            let restoredCount = relevantEvents.filter { $0.resolvedAt != nil }.count
            let lostCount = relevantEvents.filter { $0.eventType == .powerLost }.count
            restorationRate = lostCount > 0 ? Double(restoredCount) / Double(lostCount) : 0

            // Average outage duration
            let durations = relevantEvents.compactMap { $0.outageDuration }
            averageOutageDuration = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)

            // Trend calculation
            updateTrend(relevantEvents)

            // Confidence level (based on data completeness)
            confidenceLevel = calculateConfidence(relevantEvents)

            lastUpdated = Date()
        }
    }

    private func countActiveOutages() -> Int {
        recentEvents.filter { $0.isActiveOutage }.count
    }

    private func updateTrend(_ events: [PowerSenseEvent]) {
        // Compare recent vs older events to determine trend
        let midPoint = Date().addingTimeInterval(-selectedTimeRange.seconds / 2)
        let recentEvents = events.filter { $0.timestamp > midPoint }
        let olderEvents = events.filter { $0.timestamp <= midPoint }

        let recentOutages = recentEvents.filter { $0.eventType == .powerLost }.count
        let olderOutages = olderEvents.filter { $0.eventType == .powerLost }.count

        if recentOutages < olderOutages {
            trendDirection = .improving
        } else if recentOutages > olderOutages {
            trendDirection = .worsening
        } else {
            trendDirection = .stable
        }
    }

    private func calculateConfidence(_ events: [PowerSenseEvent]) -> Double {
        // Simple confidence based on data volume and recency
        let expectedEventsPerHour = 100.0 // Adjust based on system scale
        let actualEvents = Double(events.count)
        let expectedEvents = expectedEventsPerHour * (selectedTimeRange.seconds / 3600)

        return min(1.0, actualEvents / expectedEvents)
    }

    private func generateTrendData() -> [TrendDataPoint] {
        // Generate time series data for chart
        var dataPoints: [TrendDataPoint] = []
        let interval = selectedTimeRange.seconds / 10 // 10 data points
        let now = Date()

        for i in 0..<10 {
            let time = now.addingTimeInterval(-selectedTimeRange.seconds + (interval * Double(i)))
            let eventsInWindow = recentEvents.filter {
                abs($0.timestamp.timeIntervalSince(time)) < interval / 2 &&
                $0.eventType == .powerLost
            }.count

            dataPoints.append(TrendDataPoint(time: time, count: eventsInWindow))
        }

        return dataPoints
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return "\(Int(duration))s"
        } else if duration < 3600 {
            return "\(Int(duration / 60))m"
        } else {
            return String(format: "%.1fh", duration / 3600)
        }
    }

    // MARK: - Data Models

    struct TrendDataPoint {
        let time: Date
        let count: Int
    }
}

// MARK: - Preview

struct PowerSenseStatisticsOverlay_Previews: PreviewProvider {
    static var previews: some View {
        PowerSenseStatisticsOverlay()
            .padding()
            .background(Color.gray.opacity(0.1))
    }
}