//
//  ClusterDetailView.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
import MapKit

/// Detail view displayed when user taps a cluster polygon
struct ClusterDetailView: View {
    let cluster: DeviceCluster
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Confidence Rating Section
                    confidenceSection

                    Divider()

                    // Device Count Section
                    deviceCountSection

                    Divider()

                    // Outage Timing Section
                    if let startTime = cluster.outageStartTime {
                        outageTimingSection(startTime: startTime)
                        Divider()
                    }

                    // Severity Section
                    severitySection

                    Divider()

                    // Geographic Bounds
                    geographicBoundsSection
                }
                .padding()
            }
            .navigationTitle("Outage Cluster #\(cluster.clusterId)")
            #if os(MasOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var confidenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confidence Rating")
                .font(.headline)

            HStack(spacing: 12) {
                // Visual confidence meter
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 20)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(confidenceColor)
                        .frame(width: CGFloat(cluster.confidenceRating) * 200, height: 20)
                }
                .frame(width: 200)

                Text("\(Int(cluster.confidenceRating * 100))%")
                    .font(.title3.bold())
                    .foregroundColor(confidenceColor)
            }

            Text(confidenceDescription)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var deviceCountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Affected Devices")
                .font(.headline)

            HStack(spacing: 16) {
                Label("\(cluster.devices.count)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.title2.bold())
                    .foregroundColor(.red)

                if cluster.totalDevicesInArea > cluster.devices.count {
                    Text("(\(cluster.totalDevicesInArea) in area)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func outageTimingSection(startTime: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Outage Duration")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "clock")
                    Text("Started: \(startTime, style: .date) at \(startTime, style: .time)")
                }
                .font(.body)

                HStack {
                    Image(systemName: "hourglass")
                    Text("Duration: \(formatDuration(cluster.outageDuration))")
                }
                .font(.body)
                .foregroundColor(durationColor)
            }
        }
    }

    private var severitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Severity")
                .font(.headline)

            HStack {
                severityBadge
                Text(severityDescription)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var geographicBoundsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Geographic Area")
                .font(.headline)

            if !cluster.hullVertices.isEmpty {
                let lats = cluster.hullVertices.map { $0.latitude }
                let lons = cluster.hullVertices.map { $0.longitude }

                if let minLat = lats.min(), let maxLat = lats.max(),
                   let minLon = lons.min(), let maxLon = lons.max() {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bounds:")
                            .font(.caption.bold())
                        Text("  Latitude: \(String(format: "%.4f", minLat)) to \(String(format: "%.4f", maxLat))")
                            .font(.caption)
                            .monospaced()
                        Text("  Longitude: \(String(format: "%.4f", minLon)) to \(String(format: "%.4f", maxLon))")
                            .font(.caption)
                            .monospaced()
                        Text("  Hull vertices: \(cluster.hullVertices.count)")
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Helper Properties

    private var confidenceColor: Color {
        if cluster.confidenceRating < 0.2 {
            return .yellow
        } else if cluster.confidenceRating > 0.7 {
            return .red
        } else {
            return .orange
        }
    }

    private var confidenceDescription: String {
        let percentage = Int(cluster.confidenceRating * 100)
        if percentage < 30 {
            return "Low confidence - scattered outage pattern"
        } else if percentage < 70 {
            return "Moderate confidence - mixed outage and online devices"
        } else {
            return "High confidence - dense outage cluster"
        }
    }

    private var durationColor: Color {
        if cluster.outageDuration < 3600 {
            return .orange // < 1 hour
        } else if cluster.outageDuration < 86400 {
            return .red // < 1 day
        } else {
            return .purple // > 1 day
        }
    }

    private var severityBadge: some View {
        Text(cluster.severity.description.uppercased())
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(severityColor.opacity(0.2))
            .foregroundColor(severityColor)
            .cornerRadius(4)
    }

    private var severityColor: Color {
        switch cluster.severity {
        case .minor: return .blue
        case .moderate: return .yellow
        case .major: return .orange
        case .critical: return .red
        }
    }

    private var severityDescription: String {
        switch cluster.severity {
        case .minor: return "3-9 devices affected"
        case .moderate: return "10-49 devices affected"
        case .major: return "50-199 devices affected"
        case .critical: return "200+ devices affected"
        }
    }

    // MARK: - Helper Methods

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration / 3600)
        let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours == 0 {
            return "\(minutes) minutes"
        } else if hours < 24 {
            return "\(hours) hours, \(minutes) minutes"
        } else {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(days) days, \(remainingHours) hours"
        }
    }
}

// MARK: - ClusterSeverity Description

extension DeviceCluster.ClusterSeverity: CustomStringConvertible {
    public var description: String {
        switch self {
        case .minor: return "Minor"
        case .moderate: return "Moderate"
        case .major: return "Major"
        case .critical: return "Critical"
        }
    }
}
