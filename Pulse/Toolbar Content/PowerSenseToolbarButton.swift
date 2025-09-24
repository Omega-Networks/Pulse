//
//  PowerSenseToolbarButton.swift
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

/// Toolbar button for accessing PowerSense dashboard
///
/// This button provides access to the PowerSense dashboard and displays
/// the current PowerSense status in the main application toolbar.
struct PowerSenseToolbarButton: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @State private var isPowerSenseEnabled = false
    @State private var isPowerSenseConfigured = false
    @State private var showingDashboard = false

    var body: some View {
        Group {
#if os(macOS)
            Button(action: {
                openWindow(id: "PowerSense")
            }) {
                Image(systemName: powerSenseIcon)
                    .foregroundStyle(powerSenseColor)
                    .help("Open PowerSense Dashboard")
            }
            .disabled(!isPowerSenseConfigured)
#else
            Button(action: {
                showingDashboard = true
            }) {
                Image(systemName: powerSenseIcon)
                    .foregroundStyle(powerSenseColor)
            }
            .disabled(!isPowerSenseConfigured)
            .sheet(isPresented: $showingDashboard) {
                PowerSenseDashboardView.integrated(modelContext: modelContext)
            }
#endif
        }
        .task {
            await loadPowerSenseStatus()
        }
        .onChange(of: isPowerSenseEnabled) { _, _ in
            Task {
                await loadPowerSenseStatus()
            }
        }
    }

    // MARK: - Status Properties

    private var powerSenseIcon: String {
        if !isPowerSenseConfigured {
            return "power.dotted"
        } else if isPowerSenseEnabled {
            return "power"
        } else {
            return "power.off"
        }
    }

    private var powerSenseColor: Color {
        if !isPowerSenseConfigured {
            return .gray
        } else if isPowerSenseEnabled {
            return .blue
        } else {
            return .orange
        }
    }

    // MARK: - Status Loading

    private func loadPowerSenseStatus() async {
        let config = await Configuration.shared
        let enabled = await config.isPowerSenseEnabled()
        let configured = await config.isPowerSenseConfigured()

        await MainActor.run {
            self.isPowerSenseEnabled = enabled
            self.isPowerSenseConfigured = configured
        }
    }
}

#Preview {
    PowerSenseToolbarButton()
}