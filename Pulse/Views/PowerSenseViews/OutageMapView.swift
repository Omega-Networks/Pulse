//
//  OutageMapView.swift
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
import MapKit
import CoreLocation
import OSLog

/// SwiftUI view for displaying PowerSense outage polygons on a map
struct OutageMapView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var powerSenseDevices: [PowerSenseDevice]
    @Query private var powerSenseEvents: [PowerSenseEvent]

    @State private var viewModel: HeatMapViewModel
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedPolygon: OutagePolygon?
    @State private var showingPolygonDetails = false
    @State private var selectedPolygonId: UUID?
    @State private var hoveredPolygonId: UUID?
    @State private var hoverLocation: CGPoint = .zero

    // TEST ONLY: Device circle rendering (easily removable)
    @State private var showTestDeviceCircles = true // Set to false to disable

    private let logger = Logger(subsystem: "powersense", category: "outageMap")

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self._viewModel = State(initialValue: HeatMapViewModel(modelContext: modelContext))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                mapView
                overlayContent
                confidenceHoverOverlay
            }
            .navigationTitle("PowerSense Outages")
#if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
#if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    refreshButton
                }
                ToolbarItem(placement: .navigation) {
                    performanceIndicator
                }
#else
                ToolbarItem(placement: .topBarTrailing) {
                    refreshButton
                }
                ToolbarItem(placement: .topBarLeading) {
                    performanceIndicator
                }
#endif
            }
            .sheet(isPresented: $showingPolygonDetails) {
                polygonDetailsSheet
            }
        }
        .onAppear {
            viewModel.setupDataObservation()
        }
        .onChange(of: powerSenseEvents) { _, _ in
            viewModel.refreshPolygons()
        }
        .onChange(of: powerSenseDevices) { _, _ in
            viewModel.refreshPolygons()
        }
        .onChange(of: selectedPolygonId) { _, newId in
            if let polygonId = newId,
               let polygon = viewModel.outagePolygons.first(where: { $0.id == polygonId }) {
                handlePolygonSelection(polygon)
            }
        }
    }

    // MARK: - Map View

    private var mapView: some View {
        Map(position: $mapPosition, selection: $selectedPolygonId) {
            // Render outage polygons with selection support
            ForEach(viewModel.outagePolygons, id: \.id) { polygon in
                MapPolygon(coordinates: polygon.coordinates)
                    .foregroundStyle(polygonForegroundStyle(for: polygon))
                    .tag(polygon.id)
            }

            // TEST ONLY: Individual device circles for debugging (easily removable)
            if showTestDeviceCircles {
                ForEach(powerSenseDevices.filter { $0.canAggregate }, id: \.deviceId) { device in
                    MapCircle(center: CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude), radius: 50)
                        .foregroundStyle(testDeviceColor(for: device).opacity(0.6))
                        .stroke(testDeviceColor(for: device), lineWidth: 2)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange { context in
            handleMapRegionChange(context)
        }
        .animation(Animation.easeInOut(duration: 0.3), value: viewModel.outagePolygons)
#if os(macOS)
        // Add hover detection for macOS through gesture
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                updateHoverState(at: location)
            case .ended:
                hoveredPolygonId = nil
            }
        }
#endif
    }

    // MARK: - Overlay Content

    private var overlayContent: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    outageStatsBadge
                    if viewModel.isCalculating {
                        progressiveLoadingIndicator
                    }
                }
                .padding()
            }
        }
    }

    private var outageStatsBadge: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Outage Areas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(viewModel.polygonCount)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }

            Divider()
                .frame(height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Affected Devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(viewModel.affectedDeviceCount)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(outageColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
    }

    private var progressiveLoadingIndicator: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Generating polygons...")
                    .font(.caption)
            }

            // Progress bar
            if viewModel.loadingProgress > 0.0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(viewModel.loadingProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor)
                                .frame(
                                    width: geometry.size.width * viewModel.loadingProgress,
                                    height: 4
                                )
                                .animation(.easeInOut(duration: 0.3), value: viewModel.loadingProgress)
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(minWidth: 180) // Ensure consistent width
    }

    private var refreshButton: some View {
        Button(action: {
            viewModel.forceRefreshPolygons()
        }) {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(viewModel.isCalculating)
    }

    private var performanceIndicator: some View {
        Button(action: {
            let stats = viewModel.performanceStats
            logger.info("Performance - Calculation: \(String(format: "%.1f", stats.lastCalculationTime * 1000))ms, Polygons: \(stats.polygonCount), Devices: \(stats.affectedDeviceCount)")
        }) {
            Text("\(String(format: "%.1f", viewModel.lastCalculationTime * 1000))ms")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Design-Compliant Polygon Styling

    /// Simplified gradient with 4-stop gradient for MapKit compatibility (Phase 1 fix)
    private func polygonForegroundStyle(for polygon: OutagePolygon) -> some ShapeStyle {
        let opacities = polygon.simplifiedGradientOpacities

        let colors = opacities.map { opacity in
            polygon.confidenceColor.opacity(opacity)
        }

        return RadialGradient(
            colors: colors,
            center: .center,
            startRadius: 0,
            endRadius: 120 // Reduced from 250 for better MapKit rendering
        )
    }


    private var outageColor: Color {
        viewModel.affectedDeviceCount > 0 ? .red : .green
    }

    // TEST ONLY: Device status color helper (easily removable)
    private func testDeviceColor(for device: PowerSenseDevice) -> Color {
        switch device.isOffline {
        case true: return .red      // Device is offline/down
        case false: return .green   // Device is online/up
        case nil: return .blue      // Status unknown
        }
    }

    // MARK: - Event Handling

    private func handlePolygonSelection(_ polygon: OutagePolygon) {
        selectedPolygon = polygon
        showingPolygonDetails = true
        logger.debug("Polygon selected: confidence=\(polygon.confidence), devices=\(polygon.affectedDeviceCount)")
    }

    private func handleMapRegionChange(_ context: MapCameraUpdateContext) {
        // Update view model region for viewport filtering
        let region = context.region
        viewModel.updateMapRegion(region)
    }

#if os(macOS)
    /// Update hover state based on mouse location (simplified implementation)
    private func updateHoverState(at location: CGPoint) {
        // For now, we'll use selection-based interaction instead of complex hover detection
        // This would require complex coordinate transformation from screen to map coordinates
        // Simplified approach: use the selection mechanism instead
        return
    }
#endif

    // MARK: - Polygon Details Sheet

    private var polygonDetailsSheet: some View {
        NavigationStack {
            if let polygon = selectedPolygon {
                PolygonDetailsView(polygon: polygon)
            } else {
                Text("No polygon selected")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Confidence Hover Overlay

    private var confidenceHoverOverlay: some View {
        VStack {
            HStack {
                Spacer()
                // Show confidence tooltip for selected polygon
                if let selectedPolygonId = selectedPolygonId,
                   let selectedPolygon = viewModel.outagePolygons.first(where: { $0.id == selectedPolygonId }) {
                    confidenceTooltip(for: selectedPolygon)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                // Fallback: show for hovered polygon if implemented
                else if let hoveredPolygonId = hoveredPolygonId,
                   let hoveredPolygon = viewModel.outagePolygons.first(where: { $0.id == hoveredPolygonId }) {
                    confidenceTooltip(for: hoveredPolygon)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Spacer()
        }
        .allowsHitTesting(false) // Allow map interactions through overlay
        .animation(.easeInOut(duration: 0.2), value: selectedPolygonId ?? hoveredPolygonId)
    }

    private func confidenceTooltip(for polygon: OutagePolygon) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Confidence indicator circle
                Circle()
                    .fill(confidenceIndicatorColor(for: polygon.confidence))
                    .frame(width: 12, height: 12)

                Text("Confidence: \(Int(polygon.confidence * 100))%")
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Affected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(polygon.affectedDeviceCount)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(polygon.isMergedPolygon ? polygon.aggregatedOutageDuration : polygon.outageDuration)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                if polygon.isMergedPolygon {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Merged")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(polygon.contributingPolygonCount)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                }
            }

            if polygon.isMergedPolygon {
                Text("Aggregated: \(polygon.aggregatedDeviceCount) devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(confidenceIndicatorColor(for: polygon.confidence), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private func confidenceIndicatorColor(for confidence: Double) -> Color {
        switch confidence {
        case 0.8...1.0:
            return .green
        case 0.6..<0.8:
            return .yellow
        case 0.4..<0.6:
            return .orange
        default:
            return .red
        }
    }

}

// MARK: - Polygon Details View

private struct PolygonDetailsView: View {
    let polygon: OutagePolygon

    var body: some View {
        List {
            Section("Outage Details") {
                DetailRow(title: "Confidence Level", value: "\(Int(polygon.confidence * 100))%")
                DetailRow(title: "Affected Devices", value: "\(polygon.recentOutageDevices)/\(polygon.affectedDeviceCount)")
                DetailRow(title: "Duration", value: polygon.outageDuration)
                DetailRow(title: "Started", value: polygon.outageStartDate.formatted(.dateTime))
                DetailRow(title: "Center Location", value: coordinateString)
                DetailRow(title: "Area Radius", value: "\(Int(polygon.boundingRadius))m")
            }

            // Show aggregated polygon information if available
            if polygon.isMergedPolygon {
                Section("Aggregation Details") {
                    DetailRow(title: "Merged Polygons", value: "\(polygon.contributingPolygonCount)")
                    DetailRow(title: "Total Devices", value: "\(polygon.aggregatedDeviceCount)")
                    DetailRow(title: "Weighted Confidence", value: "\(Int(polygon.aggregatedConfidence * 100))%")
                    DetailRow(title: "Earliest Outage", value: polygon.earliestOutageStartDate.formatted(.dateTime))
                    DetailRow(title: "Overlap Factor", value: "\(Int(polygon.overlapCoefficient * 100))%")
                    DetailRow(title: "Aggregated Duration", value: polygon.aggregatedOutageDuration)
                }

                Section("Contributing Polygons") {
                    ForEach(Array(polygon.individualConfidences.enumerated()), id: \.offset) { index, confidence in
                        HStack {
                            Text("Polygon \(index + 1)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(polygon.individualDeviceCounts[index]) devices")
                                    .fontWeight(.medium)
                                Text("\(Int(confidence * 100))% confidence")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Response Information") {
                if polygon.confidence >= 0.8 {
                    Label("High confidence outage - immediate investigation recommended", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if polygon.confidence >= 0.5 {
                    Label("Moderate confidence - monitor for pattern development", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Label("Low confidence - routine monitoring sufficient", systemImage: "info.circle")
                        .foregroundStyle(.blue)
                }
            }
        }
        .navigationTitle("Outage Area")
#if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var coordinateString: String {
        String(format: "%.4f, %.4f", polygon.center.latitude, polygon.center.longitude)
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Preview

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: PowerSenseDevice.self, PowerSenseEvent.self, configurations: config)

    // Add sample data with enough devices for polygon generation
    let context = container.mainContext

    // Create cluster of offline devices in Wellington CBD
    let baseDevices = [
        PowerSenseDevice(deviceId: "ONT001", latitude: -41.2865, longitude: 174.7762),
        PowerSenseDevice(deviceId: "ONT002", latitude: -41.2875, longitude: 174.7772),
        PowerSenseDevice(deviceId: "ONT003", latitude: -41.2870, longitude: 174.7758),
        PowerSenseDevice(deviceId: "ONT004", latitude: -41.2868, longitude: 174.7765),
        PowerSenseDevice(deviceId: "ONT005", latitude: -41.2872, longitude: 174.7768),
        PowerSenseDevice(deviceId: "ONT006", latitude: -41.2867, longitude: 174.7760),
        PowerSenseDevice(deviceId: "ONT007", latitude: -41.2871, longitude: 174.7764)
    ]

    for (index, device) in baseDevices.enumerated() {
        device.name = device.deviceId
        device.isMonitored = true
        context.insert(device)

        // Create power events for some devices to simulate outages
        if index < 5 { // First 5 devices are offline
            let event = PowerSenseEvent(eventId: "evt_\(device.deviceId)", timestamp: Date().addingTimeInterval(-3600))
            event.device = device
            event.eventDescription = "Power Off Event: \(device.deviceId)"
            event.severity = 4
            context.insert(event)
        }
    }

    // Add another cluster in Lower Hutt
    let huttDevices = [
        PowerSenseDevice(deviceId: "ONT008", latitude: -41.2090, longitude: 174.9080),
        PowerSenseDevice(deviceId: "ONT009", latitude: -41.2095, longitude: 174.9085),
        PowerSenseDevice(deviceId: "ONT010", latitude: -41.2085, longitude: 174.9075),
        PowerSenseDevice(deviceId: "ONT011", latitude: -41.2092, longitude: 174.9088)
    ]

    for device in huttDevices {
        device.name = device.deviceId
        device.isMonitored = true
        context.insert(device)

        // All devices in this cluster are offline
        let event = PowerSenseEvent(eventId: "evt_\(device.deviceId)", timestamp: Date().addingTimeInterval(-1800))
        event.device = device
        event.eventDescription = "Power Off Event: \(device.deviceId)"
        event.severity = 5
        context.insert(event)
    }

    try! context.save()

    return OutageMapView(modelContext: context)
}