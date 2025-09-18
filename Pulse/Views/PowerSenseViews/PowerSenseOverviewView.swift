//
//  PowerSenseOverviewView.swift
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

/// Overview of PowerSense outage status with privacy-compliant aggregation
///
/// This view demonstrates the privacy-first aggregation logic while providing
/// meaningful insights into power outage patterns across the monitored area.
struct PowerSenseOverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var dataService: PowerSenseDataService
    @StateObject private var aggregationService: PowerSenseAggregationService

    @State private var outageOverview: PowerSenseOutageOverview?
    @State private var gridCells: [PowerSenseGridCell] = []
    @State private var timeWindows: [PowerSenseTimeWindow] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(modelContext: ModelContext) {
        self._dataService = StateObject(wrappedValue: PowerSenseDataService(modelContext: modelContext))
        self._aggregationService = StateObject(wrappedValue: PowerSenseAggregationService(modelContext: modelContext))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if isLoading {
                    ProgressView("Loading PowerSense data...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = errorMessage {
                    ContentUnavailableView(
                        "PowerSense Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if !dataService.isEnabled {
                    ContentUnavailableView(
                        "PowerSense Disabled",
                        systemImage: "power",
                        description: Text("Enable PowerSense in Settings to view outage data")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // System Status Overview
                            if let overview = outageOverview {
                                systemStatusCard(overview)
                            }

                            // Recent Activity Grid
                            if !gridCells.isEmpty {
                                gridCellsSection
                            }

                            // Time-based Analysis
                            if !timeWindows.isEmpty {
                                timeWindowsSection
                            }

                            // Data Service Status
                            dataServiceStatusCard
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("PowerSense Overview")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") {
                        Task {
                            await refreshData()
                        }
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await refreshData()
            }
        }
    }

    // MARK: - System Status Card

    @ViewBuilder
    private func systemStatusCard(_ overview: PowerSenseOutageOverview) -> some View {
        GroupBox("System Status") {
            VStack(spacing: 12) {
                HStack {
                    Label(overview.systemStatus.rawValue, systemImage: "power")
                        .foregroundStyle(Color(overview.systemStatus.color))
                        .font(.headline)

                    Spacer()

                    Text("\(Int(overview.overallOutageRate * 100))% outage rate")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    statusMetric("Total Devices", value: "\(overview.totalMonitoredDevices)")
                    statusMetric("With Power", value: "\(overview.devicesWithPower)", color: .green)
                    statusMetric("Without Power", value: "\(overview.devicesWithoutPower)", color: .red)
                    statusMetric("Affected Areas", value: "\(overview.affectedGridCells)")
                }

                if overview.recentActivityDevices > 0 {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.orange)
                        Text("\(overview.recentActivityDevices) devices affected in last hour")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusMetric(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Grid Cells Section

    @ViewBuilder
    private var gridCellsSection: some View {
        GroupBox("Affected Areas") {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(gridCells.prefix(6)) { cell in
                    gridCellCard(cell)
                }
            }

            if gridCells.count > 6 {
                Text("Showing 6 of \(gridCells.count) affected areas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func gridCellCard(_ cell: PowerSenseGridCell) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grid \(cell.cellId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(cell.statusSummary)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        cell.outageRate > 0.5 ? Color.red.opacity(0.2) :
                        cell.outageRate > 0.1 ? Color.orange.opacity(0.2) :
                        Color.green.opacity(0.2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(cell.totalDevices)")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(cell.devicesWithoutPower)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(cell.devicesWithoutPower > 0 ? .red : .primary)
                    Text("without power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if cell.hasRecentActivity {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Recent activity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Time Windows Section

    @ViewBuilder
    private var timeWindowsSection: some View {
        GroupBox("Recent Activity") {
            VStack(spacing: 12) {
                ForEach(timeWindows.prefix(5)) { window in
                    timeWindowRow(window)
                }
            }
        }
    }

    @ViewBuilder
    private func timeWindowRow(_ window: PowerSenseTimeWindow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(window.windowStart, style: .time)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("1 hour window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                if window.powerLostEvents > 0 {
                    Label("\(window.powerLostEvents)", systemImage: "power")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if window.powerRestoredEvents > 0 {
                    Label("\(window.powerRestoredEvents)", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                Text("\(window.affectedDeviceCount) devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Circle()
                .fill(Color(window.activityLevel.color))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Data Service Status

    @ViewBuilder
    private var dataServiceStatusCard: some View {
        GroupBox("Data Service") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Status: \(dataService.syncStatus.displayName)")
                        .font(.subheadline)

                    Spacer()

                    if let lastSync = dataService.lastSyncTime {
                        Text("Last sync: \(lastSync, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("\(dataService.deviceCount) devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text("\(dataService.eventCount) events")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if dataService.syncStatus == .syncing {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func refreshData() async {
        isLoading = true
        errorMessage = nil

        do {
            // Load aggregated data
            async let overview = aggregationService.getCurrentOutageOverview()
            async let cells = aggregationService.aggregateDevicesIntoGridCells()
            async let windows = aggregationService.aggregateEventsIntoTimeWindows()

            self.outageOverview = try await overview
            self.gridCells = try await cells
            self.timeWindows = try await windows

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

#Preview {
    PowerSenseOverviewView(modelContext: ModelContext(try! ModelContainer(for: PowerSenseDevice.self, PowerSenseEvent.self)))
}