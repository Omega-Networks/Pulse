//
//  PowerSenseDashboardView.swift
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

/// Main PowerSense dashboard with overview
///
/// This dashboard provides municipal authorities with comprehensive power outage
/// visibility while maintaining strict privacy controls through data aggregation.
struct PowerSenseDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var dataService: PowerSenseDataService

    init(modelContext: ModelContext) {
        self._dataService = StateObject(wrappedValue: PowerSenseDataService(modelContext: modelContext))
    }

    var body: some View {
        PowerSenseOverviewView(modelContext: modelContext)
        .navigationTitle("PowerSense")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                powerSenseStatusIndicator

                Menu("Actions") {
                    Button("Sync Now") {
                        Task {
                            await dataService.performSync()
                        }
                    }
                    .disabled(dataService.syncStatus == .syncing)

                    Divider()

                    if dataService.isEnabled {
                        Button("Disable PowerSense") {
                            Task {
                                await dataService.disable()
                            }
                        }
                    } else {
                        Button("Enable PowerSense") {
                            Task {
                                await dataService.enable()
                            }
                        }
                    }

                    if dataService.deviceCount > 0 || dataService.eventCount > 0 {
                        Divider()

                        Button("Clear Data", role: .destructive) {
                            Task {
                                await dataService.clearAllPowerSenseData()
                            }
                        }
                    }
                }
            }
        }
        .environmentObject(dataService)
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var powerSenseStatusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        if !dataService.isEnabled {
            return .gray
        }

        switch dataService.syncStatus {
        case .idle: return .green
        case .syncing: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        if !dataService.isEnabled {
            return "Disabled"
        }

        switch dataService.syncStatus {
        case .idle: return "Ready"
        case .syncing: return "Syncing"
        case .completed: return "Online"
        case .failed: return "Error"
        }
    }
}

// MARK: - Integration Extension

extension PowerSenseDashboardView {
    /// Create PowerSense dashboard wrapped for integration with main app
    static func integrated(modelContext: ModelContext) -> some View {
        NavigationView {
            PowerSenseDashboardView(modelContext: modelContext)
        }
    }
}

// MARK: - Availability Check

extension PowerSenseDashboardView {
    /// Check if PowerSense should be available in the main app
    static func shouldBeAvailable(modelContext: ModelContext) async -> Bool {
        let config = await Configuration.shared
        let isEnabled = await config.isPowerSenseEnabled()
        let isConfigured = await config.isPowerSenseConfigured()
        return isEnabled && isConfigured
    }
}

#Preview {
    let container = try! ModelContainer(for: PowerSenseDevice.self, PowerSenseEvent.self)
    return PowerSenseDashboardView(modelContext: container.mainContext)
}