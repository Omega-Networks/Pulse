//
//  DeviceView.swift
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

import Foundation
import SwiftUI
//import OmegaPlayer

/**
 A view that represents a network device with interactive elements and status indicators.
 
 DeviceView provides:
 - Hover interactions with delayed feedback
 - Device selection functionality
 - Status indicators for device events
 - Conditional display of device details
 - Platform-specific implementations for macOS and iOS
 
 The view uses delayed hover interactions to prevent accidental triggers when
 attempting to click the device icon.
 */
struct DeviceView: View {
    @State var device: Device
    
    /// Current gesture location state
    @GestureState var locationState: CGPoint
    
    /// Current location of the device view
    @State var location: CGPoint
    @Binding var selectedDevice: Device?
    
    /// Binding to track the device's position
    @Binding var position: CGPoint
    
    //Introducing delay to hover gesture (for both ICMP ping graph and device details
    @State private var shouldShowDetails: Bool = false
    
    @State private var shouldShowHover: Bool = false {
        didSet {
#if os(macOS)
            showPopover = shouldShowHover && !enableGestures && !rackEdit.isEditing
            shouldShowDetails = shouldShowHover
#endif
        }
    }
    
    @State private var hoverTimer: Timer?
    
    // Toggle from SiteView for setting labels visable
    @Binding var labelsEnabled: Bool
    
    /**
     The action to perform when the device is tapped.
     This closure is invoked when the user taps the device icon.
     */
    var action: () -> Void
    
    /// Controls visibility of device labels
    @Binding var enableGestures: Bool
    
    /// Tracks primary hover state
    @State var isHovering: Bool
    
    /// Tracks secondary hover state
    @State var isHoveringSub: Bool
    
    @State private var isAnimating = false
    @State private var showPopover = false
    
    @State private var isTapped: Bool = false

    /// Environment handle for opening the SSH terminal window via
    /// the device-node context menu. Declared on `DeviceView`
    /// directly because the environment value does not propagate
    /// from `SiteGraphView`'s `@Environment(\.openWindow)` into the
    /// closure scope of a child view's `.contextMenu` button.
    @Environment(\.openWindow) private var openWindow
    @Environment(RackEditSession.self) private var rackEdit
    @Environment(LicenseSeatStore.self) private var seats
    @Environment(RolePresentationStore.self) private var rolePresentation

    /**
     Initializes a new DeviceView with the specified device and bindings.
     
     - Parameters:
     - device: The network device to display
     - selectedDevice: Binding to the currently selected device
     - position: Binding to track the device's position
     - labelsEnabled: Binding controlling visibility of all device labels
     - enableGestures: Binding controlling whether gestures are enabled
     - action: Closure to execute when the device is tapped
     */
    init(device: Device, selectedDevice: Binding<Device?>, position: Binding<CGPoint>, labelsEnabled: Binding<Bool>, enableGestures: Binding<Bool>, action: @escaping () -> Void) {
        self.device = device
        _locationState = GestureState(initialValue: CGPoint(x: device.x ?? 69, y: device.y ?? 69))
        _location = State(initialValue: CGPoint(x: device.x ?? 69, y: device.y ?? 69))
        _selectedDevice = selectedDevice
        _position = position  // Initialize the position binding
        _labelsEnabled = labelsEnabled
        _enableGestures = enableGestures
        _isHovering = State(initialValue: false)
        _isHoveringSub = State(initialValue: false)
        
        self.action = action
        self.isTapped = false
    }
    
    var isSelected: Bool {
        return device == selectedDevice
    }
    
    //TODO: Refine logic with showing resolved event squares
    /**
     Determines the system image name and resolution state based on event count.
     
     This function handles the visual representation of event counts:
     - For counts > 50: Shows an exclamation mark
     - For resolved events: Shows a checkmark
     - For other cases: Shows the numeric count of unresolved events
     
     - Parameters:
     - count: The number of events to represent
     - events: Array of events to check for resolution status
     - Returns: A tuple containing the system image name and whether all events are resolved
     */
    func imageName(for count: Int, events: [Event]) -> (name: String, isResolved: Bool) {
        // First check if we have any events
        guard !events.isEmpty else {
            return ("\(count).square.fill", false)
        }
        
        // If ANY event is resolved, show the checkmark
        let hasResolvedEvent = events.contains { $0.state == "RESOLVED" }
        
        if hasResolvedEvent {
            return ("checkmark.square.fill", true)
        }
        
        // Handle overflow case
        if count > 50 {
            return ("exclamationmark.square.fill", false)
        }

        return ("\(count).square.fill", false)
    }
    
    var body: some View {
        VStack {
            // First, the main device icon with severity
            ZStack(alignment: .bottomTrailing) {
                deviceIcon
                eventIndicators
            }
            .onHover { isHovering in
                self.isHovering = isHovering

                // Cancel any existing timer
                hoverTimer?.invalidate()

                if isHovering {
                    // Create new timer for 1 second delay
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                        Task { @MainActor in
                            shouldShowHover = true
                            // This will trigger the didSet above
                        }
                    }
                } else {
                    // Reset immediately when hover ends
                    shouldShowHover = false
                }
            }
            .onTapGesture {
                self.selectedDevice = device
            }

            // Device Labels
            deviceLabels
        }
        .contextMenu {
            // Only surface the menu when the device has a routable
            // primary IP. Without one the SSH terminal cannot
            // connect, and surfacing the gesture greyed-out is
            // noise. SwiftUI suppresses the right-click menu
            // entirely when the builder produces no content. Future
            // UI (Open Web UI, Copy IP, etc.) extends this block
            // when there's an operator ask. The id is wrapped in
            // `DeviceWindowTarget` so routing is by type; the
            // matching `id: "ssh-terminal"` is the restoration anchor.
            // See `SSHTerminalScene` doc-comment.
            if let primaryIP = device.primaryIP, !primaryIP.isEmpty {
                Button {
                    openWindow(id: "ssh-terminal", value: DeviceWindowTarget(deviceID: device.id))
                } label: {
                    Label(
                        seats.allowsActions(deviceID: device.id) ? "Open SSH Terminal" : "Subscribe to resume",
                        systemImage: "terminal.fill"
                    )
                }
                .disabled(!seats.allowsActions(deviceID: device.id))
            }

            // Surface the Device Web window only when NetBox declares a
            // web-serving service (WebServiceResolver is the source-of-truth rule).
            if WebServiceResolver.primaryTarget(for: device) != nil {
                Button {
                    // Routed by type via the Device Web scene's own
                    // `DeviceWebWindowTarget` (distinct from the SSH
                    // terminal's `DeviceWindowTarget` so the two scenes don't
                    // share one `WindowGroup(for:)` type and mount twice);
                    // `id: "device-web"` is the restoration anchor.
                    openWindow(id: "device-web", value: DeviceWebWindowTarget(deviceID: device.id))
                } label: {
                    Label(
                        seats.allowsActions(deviceID: device.id) ? "Open Web UI" : "Subscribe to resume",
                        systemImage: "globe"
                    )
                }
                .disabled(!seats.allowsActions(deviceID: device.id))
            }
        }
    }
    
    // MARK: - View Components
    
    /**
     Creates and returns the main device icon view.
     
     This view includes:
     - The device symbol with appropriate styling
     - Shadow effects for depth
     - Hover interaction handling
     - Platform-specific popover presentation
     
     - Returns: A view containing the styled device icon
     */
    private var deviceIcon: some View {
        Image(device.symbolName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(device.graphStrokeColor, device.unacknowledgedSeverityColor)
            .shadow(color: device.graphStrokeColor.opacity(0.7), radius: 2)
            .font(.system(size: 50, weight: .regular))
            .animation(.easeInOut(duration: 0.2), value: device.highestUnacknowledgedSeverityStored)
            .overlay( //MARK: This overlay enables us to compute the bounding rectangle of the Image struct.
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ImageCentrePreferenceKey.self,
                        value: CGPoint(x: geometry.frame(in: .local).midX - 30, y: geometry.frame(in: .local).midY - 45)
                    )
                }
            )
            .popover(isPresented: $showPopover) {
#if os(macOS)
                deviceOverview()
#elseif os(iOS)
                deviceDetailsIOS()
#endif
            }
            .onChange(of: rackEdit.isEditing) {
                if rackEdit.isEditing {
                    showPopover = false
                }
            }
#if os(macOS)
            .rackDeviceDrag(
                id: device.id,
                enabled: rackEdit.isEditing && seats.allowsRackEdit(
                    deviceID: device.id,
                    roleID: device.deviceRole?.id,
                    presentation: rolePresentation.presentation
                ),
                symbol: device.symbolName,
                session: rackEdit
            )
#endif
#if os(iOS)
            .onTapGesture {
                if !rackEdit.isEditing {
                    showPopover = true
                }
            }
#endif
    }
    
    /**
     Creates and returns the event indicator view.
     
     This view displays status indicators for device events, including:
     - Event counts by severity
     - Resolution status
     - Color coding based on severity
     
     - Returns: A view containing the event indicators
     */
    private var eventIndicators: some View {
        HStack(spacing: 0) {
            ForEach(Array(eventsCountBySeverity.keys).sorted(), id: \.self) { key in
                if let eventsForSeverity = device.events?.filter({ $0.severity == key }) {
                    
                    let count = eventsForSeverity.count
                    let symbol = imageName(for: count, events: eventsForSeverity)
                    
                    Image(systemName: symbol.name)
                        .symbolRenderingMode(.palette)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.symbolEffect(.automatic))
                        .font(.system(size: 16.5))
                        .shadow(color: Color.black, radius: 1)
                        .foregroundStyle(Color.primary,
                                         symbol.isResolved ? .green : severitySquareColor(for: Int64(key)))
                        .frame(width: 15, height: 15)
                }
            }
        }
    }
    
    /**
     Creates and returns the device labels view.
     
     This view displays device information including:
     - Device name
     - Model information
     - Additional details when expanded
     
     - Returns: A view containing the device labels
     */
    private var deviceLabels: some View {
        VStack {
            Text(device.name ?? "Error")
                .font(.headline)
                .textSelection(.enabled)
            Text(labelsEnabled || shouldShowDetails || selectedDevice == device ?
                 "Model: \(device.deviceType?.model ?? "Error")" :
                    device.deviceType?.model ?? "Error")
            .font(.caption)
            .textSelection(.enabled)
        }
        .overlay(
            VStack {
                Spacer()
                #if os(macOS)
                if labelsEnabled || shouldShowDetails {
                    deviceDetails()
                }
                #endif
            }
                .padding([.top], 69)
                .background(Color.clear)
        )
    }
}

#if os(macOS)
private extension View {
    func rackDeviceDrag(id: Int64, enabled: Bool, symbol: String, session: RackEditSession) -> some View {
        modifier(RackDeviceDragModifier(id: id, enabled: enabled, symbol: symbol, session: session))
    }
}

/// Same modifier type whether armed or not, so toggling edit does not
/// replace graph nodes. `.draggable` is only present in edit mode so
/// the finger tool can still move nodes.
private struct RackDeviceDragModifier: ViewModifier {
    let id: Int64
    let enabled: Bool
    let symbol: String
    let session: RackEditSession

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                session.beginDrag(id: id)
                return NSItemProvider(object: NSString(string: String(id)))
            }
        } else {
            content
        }
    }
}
#endif

extension DeviceView {
    private var eventsCountBySeverity: [String: Int] {
        // Use the persisted summary instead of computing from @Transient array
        device.eventCountBySeverity
    }
    
    /**
     Determines the display color for a given severity level.
     
     Maps severity levels to their corresponding visual representation:
     - 0: Information (Gray)
     - 1: Warning (Blue)
     - 2: Minor (Yellow)
     - 3: Major (Orange)
     - 4: Critical (Red)
     - 5: Fatal (Black)
     - -1: Not Applicable (White)
     - nil: Unknown (Indigo)
     
     - Parameter value: The severity level to map to a color
     - Returns: The corresponding Color for the severity level
     */
    func severitySquareColor(for value: Int64?) -> Color {
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
    
    /**
     Constructs and returns a view displaying the details of a device.
     
     This view includes the device's serial number, primary IP address, and role, presented in a vertical stack. Each piece of information is displayed in a caption font with the option for text selection enabled.
     If any of these details are unavailable, "Error" is displayed as a fallback.
     
     The view includes a transition effect for its appearance and disappearance, using the default symbol effect.
     
     - Returns: A view containing the device's serial number, primary IP, and role.
     */
    private func deviceDetails() -> some View {
        VStack {
            Text("Serial: \(self.device.serial ?? "Error")")
                .font(.caption)
                .textSelection(.enabled)
            Text("IP: \(self.device.primaryIP ?? "Error")")
                .font(.caption)
                .textSelection(.enabled)
            Text("Role: \(self.device.deviceRole?.name ?? "Error")")
                .font(.caption)
                .textSelection(.enabled)
        }
        .transition(.symbolEffect(.automatic))
    }
    
#if os(macOS)
    /**
     Creates and returns a view displaying device overview information for macOS.
     
     - Returns: A DeviceOverviewView configured for the current device
     */
    private func deviceOverview() -> some View {
        // Add the DeviceGraphsView
        DeviceOverviewView(deviceId: device.zabbixId)
    }
    
#elseif os(iOS)
    
    /**
     Creates and returns a view displaying device details for iOS.
     
     This view includes:
     - Device information
     - Camera feed (if applicable)
     - Performance charts
     - Device-specific metrics
     
     - Returns: A ScrollView containing device details and metrics
     */
    private func deviceDetailsIOS() -> some View {
        ScrollView {
            LazyVStack(alignment: .center, spacing: 20) {
                // Header section
                Text(device.name ?? "N/A")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.top, 30)
                
                deviceDetails()
                    .padding(.horizontal)
                
                // Charts and data section
                VStack(spacing: 20) {
                    DeviceOverviewView(deviceId: device.zabbixId)
                        .padding(.horizontal)
                    
                    if device.deviceRole?.name ?? "" == "Security Router" {
                        ItemChart(deviceId: device.id, item: "CPU usage")
                            .padding(.horizontal)
                        
                        ItemChart(deviceId: device.id, item: "Memory usage")
                            .padding(.horizontal)
                    }
                    
                    DeviceChartSelector(deviceId: device.id)
                        .padding(.horizontal)
                }
            }
        }
    }
    
    
#endif
}

//MARK: Extension and Struct for centering the edges around the Image
extension CGRect {
    var center: CGPoint {
        return CGPoint(x: midX, y: midY)
    }
}

/**
 PreferenceKey for managing device icon center point coordinates.
 
 This preference key enables passing the bounding rectangle of the DeviceView's
 image component back to its parent GraphLayerView, allowing proper edge centering
 around the image rather than the entire view.
 */
struct ImageCentrePreferenceKey: PreferenceKey {
    static let defaultValue: CGPoint? = nil
    
    /**
     Combines multiple preference values into a single value.
     
     - Parameters:
     - value: The current preference value
     - nextValue: A closure that returns the next preference value
     */
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        value = value ?? nextValue()
    }
}
