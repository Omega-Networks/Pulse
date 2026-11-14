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
    @State private var plusHeld = false
    @State private var plusReturn: Task<Void, Never>?
    
    // Toggle from SiteView for setting labels visable
    @Binding var labelsEnabled: Bool
    
    /// Build mode: the plus starts a cable. A tap on the icon selects the device.
    var action: () -> Void

    /// A cable tether is in progress. The plus stays hidden.
    var drawingCable: Bool

    /// This node is being repositioned. The plus stays hidden through the
    /// drag and a short pause after the pointer is released.
    var dragging: Bool = false

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
    init(device: Device, selectedDevice: Binding<Device?>, position: Binding<CGPoint>, labelsEnabled: Binding<Bool>, enableGestures: Binding<Bool>, action: @escaping () -> Void, drawingCable: Bool = false, dragging: Bool = false) {
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
        self.drawingCable = drawingCable
        self.dragging = dragging
        self.isTapped = false
    }
    
    var isSelected: Bool {
        return device == selectedDevice
    }
    
    /// Hover shows it, a press sinks it, and a drag keeps it away.
    private var plusPresented: Bool {
        enableGestures && isHovering && !drawingCable && !plusHeld && !dragging && seats.allowsActions(deviceID: device.id)
    }
    
    var body: some View {
        VStack {
            ZStack(alignment: .bottomTrailing) {
                deviceIcon
                    .onTapGesture {
                        self.selectedDevice = device
                    }
                eventIndicators
            }
            .overlay(alignment: .bottomTrailing) {
                #if os(macOS)
                if enableGestures && seats.allowsActions(deviceID: device.id) {
                    CablePlusButton(presented: plusPresented, action: action)
                }
                #endif
            }
            .onChange(of: dragging) { _, dragging in
                plusReturn?.cancel()
                guard dragging else {
                    plusReturn = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        plusHeld = false
                    }
                    return
                }
                plusHeld = true
            }
            .onHover { hovering in
                isHovering = hovering

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
            .animation(.easeInOut(duration: 1), value: iconPaint)
            .overlay( //MARK: This overlay enables us to compute the bounding rectangle of the Image struct.
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key: ImageCentrePreferenceKey.self,
                            value: CGPoint(x: geometry.frame(in: .local).midX - 30, y: geometry.frame(in: .local).midY - 45)
                        )
                        .preference(
                            key: IconFramePreferenceKey.self,
                            value: geometry.frame(in: .named(siteDiagramCoordinateSpace))
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
    
    /// Active-problem squares for this device. The spring is on this row only.
    private var eventIndicators: some View {
        let squares = problemSquares
        return HStack(spacing: 0) {
            ForEach(squares) { square in
                ProblemCountGlyph(
                    symbol: square.symbol,
                    fill: severitySquareColor(for: Int64(square.severity)),
                    fontSize: 18.5,
                    numberTransition: .symbolEffect(.replace)
                )
                .transition(.symbolEffect(.automatic))
                .frame(width: 17, height: 17)
            }
        }
        .animation(.spring(duration: 0.55, bounce: 0.32), value: squares)
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

private struct IconPaint: Equatable {
    var stroke: Color
    var fill: Color
}

private struct ProblemSquare: Equatable, Identifiable {
    var severity: String
    var symbol: String
    var id: String { severity }
}

extension DeviceView {
    /// Stroke and fill of the icon. The one-second ease is attached to
    /// this, not to the site graph's device query, so one device can
    /// change colour without springing every node.
    private var iconPaint: IconPaint {
        IconPaint(stroke: device.graphStrokeColor, fill: device.unacknowledgedSeverityColor)
    }

    /// One square per severity with an active problem. The number is the
    /// stored count. Over 50 is the exclamation glyph. Identity is the
    /// severity, so a count change rolls the glyph and an added or
    /// removed severity slides its neighbours.
    private var problemSquares: [ProblemSquare] {
        let counts = device.activeCountsBySeverity
        return (0..<6).compactMap { severity in
            let count = severity < counts.count ? counts[severity] : 0
            guard count > 0 else { return nil }
            let symbol = count > 50
                ? "exclamationmark.square.fill"
                : "\(count).square.fill"
            return ProblemSquare(severity: String(severity), symbol: symbol)
        }
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
                        ItemChart(deviceId: device.zabbixId, item: "CPU usage")
                            .padding(.horizontal)
                        
                        ItemChart(deviceId: device.zabbixId, item: "Memory usage")
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
#if os(macOS)
/// Build-mode plus. Scale stays on the button's own centre; the offset is
/// constant, so the pop does not travel.
private struct CablePlusButton: View {
    var presented: Bool
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: "plus.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.primary, Color.accentColor)
            .font(.system(size: 16.5))
            .scaleEffect(presented ? (pressed ? 0.84 : 1) : 0.2, anchor: .center)
            .opacity(presented ? 1 : 0)
            .animation(.spring(duration: 0.22, bounce: 0.45), value: presented)
            .offset(y: -34)
            .allowsHitTesting(presented)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard presented, !pressed else { return }
                        withAnimation(.spring(duration: 0.12, bounce: 0.15)) {
                            pressed = true
                        }
                    }
                    .onEnded { _ in
                        let wasPressed = pressed
                        withAnimation(.spring(duration: 0.12, bounce: 0.15)) {
                            pressed = false
                        }
                        if wasPressed, presented { action() }
                    }
            )
            .onChange(of: presented) { _, show in
                if !show { pressed = false }
            }
    }
}
#endif

/// Diagram coordinate space shared by the site graph and the cable pointer.
let siteDiagramCoordinateSpace = "diagram"

/// The device icon's frame in `siteDiagramCoordinateSpace`. The label is not included.
struct IconFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

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
