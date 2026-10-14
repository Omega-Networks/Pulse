//
//  SiteMapView.swift
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
import Observation
#if os(macOS)
import AppKit
#endif

typealias NodeID = Int64

#if os(macOS)
private enum CableTetherPhase {
    case tracking
    case locked
    case retracting
}

/// `end` and `opacity` are what the stroke reads. A move does not redraw
/// the nodes.
@MainActor
@Observable
private final class CableTetherState {
    var sourceID: Int64?
    var end = CGPoint.zero
    var opacity = 1.0

    var phase: CableTetherPhase = .tracking
    /// The pointer is on the device the cable started from, or on the X
    /// that sits where that device's plus sits. Flips on enter and leave.
    var overOrigin = false
    @ObservationIgnored var generation = 0
}

/// Owns the pointer while a cable is being drawn. One rectangle, in the
/// diagram's own space. The device nodes are not hit-tested for that time.
/// This layer does not take key focus.
private struct CablePointerOverlay: View {
    var tracking: Bool
    var onMove: (CGPoint) -> Void
    var onLeave: () -> Void
    var onLeftClick: (CGPoint) -> Void
    var onRightClick: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named(siteDiagramCoordinateSpace)) { phase in
                switch phase {
                case .active(let point):
                    guard tracking else { return }
                    onMove(point)
                case .ended:
                    onLeave()
                }
            }
            .onTapGesture(coordinateSpace: .named(siteDiagramCoordinateSpace)) { point in
                guard tracking else { return }
                onLeftClick(point)
            }
            .gesture(CableRightClick(onEnded: onRightClick))
    }
}

/// Secondary click. SwiftUI's tap gesture does not carry the mouse button.
/// Attached with `.gesture`, so it is not a view and not an event monitor.
private struct CableRightClick: NSGestureRecognizerRepresentable {
    var onEnded: () -> Void

    func makeNSGestureRecognizer(context: Context) -> NSClickGestureRecognizer {
        let recognizer = NSClickGestureRecognizer()
        recognizer.buttonMask = 0x2
        return recognizer
    }

    func handleNSGestureRecognizerAction(
        _ recognizer: NSClickGestureRecognizer,
        context: Context
    ) {
        guard recognizer.state == .ended else { return }
        onEnded()
    }
}

/// The plus, drawn as an X, while the pointer is back on the start device.
/// Clicks pass through; the pointer layer tests this control's rect.
private struct CableOriginMark: View {
    var tether: CableTetherState

    var body: some View {
        Image(systemName: "x.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.primary, Color.accentColor)
            .font(.system(size: cableOriginSide))
            .scaleEffect(tether.overOrigin ? 1 : 0.2, anchor: .center)
            .opacity(tether.overOrigin ? 1 : 0)
            .animation(.spring(duration: 0.22, bounce: 0.45), value: tether.overOrigin)
            .allowsHitTesting(false)
    }
}

/// Temporary cable, under the nodes. Tracking draws `end` with a plain
/// path. Retract is a separate shape, so that spring cannot lag a move.
private struct CableTetherLine: View {
    var start: CGPoint
    var tether: CableTetherState

    var body: some View {
        Group {
            if tether.phase == .retracting {
                RetractingCable(start: start, from: tether.end, to: start)
            } else {
                Path { path in
                    path.move(to: start)
                    path.addLine(to: tether.end)
                }
                .stroke(Color.accentColor, style: cableStroke)
            }
        }
        .opacity(tether.opacity)
        .allowsHitTesting(false)
    }
}

private let cableStroke = StrokeStyle(lineWidth: 1.69, lineCap: .round)

/// The plus is 16.5 points, lifted 34 above the icon's bottom-trailing
/// corner. The X uses that same seat.
private let cableOriginSide: CGFloat = 16.5
private let cableOriginLift: CGFloat = 34

/// Springs the free end back to the device the cable started on, then the
/// caller fades the stroke. Tracking never uses this shape.
private struct RetractingCable: View {
    var start: CGPoint
    var from: CGPoint
    var to: CGPoint
    @State private var end: CGPoint
    @State private var started = false

    init(start: CGPoint, from: CGPoint, to: CGPoint) {
        self.start = start
        self.from = from
        self.to = to
        _end = State(initialValue: from)
    }

    var body: some View {
        CableRetractShape(start: start, end: end)
            .stroke(Color.accentColor, style: cableStroke)
            .onAppear {
                guard !started else { return }
                started = true
                withAnimation(.spring(duration: 0.22, bounce: 0.2)) {
                    end = to
                }
            }
    }
}

private struct CableRetractShape: Shape {
    var start: CGPoint
    var end: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(start.x, start.y),
                AnimatablePair(end.x, end.y)
            )
        }
        set {
            start = CGPoint(x: newValue.first.first, y: newValue.first.second)
            end = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }
}
#endif

struct Graph {
    var nodes: [NodeID: Device]
    var edges: [Edge]
    var adjacencyList: [NodeID: [NodeID]]
    
    init(devices: [Device], connections: [Edge]) {
        let groupedDevices = Dictionary(grouping: devices, by: { $0.id })
        nodes = Dictionary(uniqueKeysWithValues: groupedDevices.compactMap {
            ($0.key, $0.value.first) as? (NodeID, Device)
        })
        edges = connections
        adjacencyList = [:]
        
        // Build adjacency list from edges
        for edge in edges {
            if let startDeviceId = edge.start.deviceId,
               let endDeviceId = edge.end.deviceId {
                adjacencyList[startDeviceId, default: []].append(endDeviceId)
            }
        }
    }
}

@MainActor
struct SiteGraphView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) var openWindow
    @Environment(RolePresentationStore.self) private var rolePresentation
    var siteId: Int64
    var isInPopover: Bool
    
    @Query var devices: [Device]
    @Binding var selectedDevice: Device?
    
    @State private var imageCentres: [Int64: CGPoint] = [:]
    @State private var iconFrames: [Int64: CGRect] = [:]
    @State private var draggingNodeID: Int64?
    @State private var nodeToDrag: (device: Device, offset: CGSize)? = nil
    @State private var nodeBoundingRect: CGRect = .zero
    @State private var originalPositions: [Int64: CGPoint] = [:]
    
    //Properties for zooming in and out
    @State private var currentZoom: CGFloat = 0.0
    @State private var totalZoom: CGFloat = 1.0
    @State private var finalPosition: CGSize = .zero
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }
    
    //Properties for dragging
    @GestureState private var dragOffset: CGSize = .zero
    
    //Prevents the user from zooming in too far out or in
    let maxZoom: CGFloat = 3.0
    let minZoom: CGFloat = 0.5
    
    //Property for dragging around the view
    private var dragGesture: some Gesture {
        DragGesture()
            .updating($dragOffset) { (value, state, _) in
                // Update drag offset with animation
                withAnimation(.smooth) {
                    state = value.translation // Track drag offset
                }
            }
            .onEnded { value in
                // Smoothly update the final position when the drag ends
                finalPosition.width += value.translation.width
                finalPosition.height += value.translation.height
            }
    }
    
    //Property for zooming in and out of the view
    // Updated property for zooming in and out of the view
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Calculate the potential new zoom level based on the current gesture scale
                let deltaZoom = value.magnification - 1
                let newZoom = totalZoom + deltaZoom
                
                // Adjust currentZoom without animation here since it's continuously updated
                if newZoom > maxZoom {
                    currentZoom = maxZoom - totalZoom
                } else if newZoom < minZoom {
                    currentZoom = minZoom - totalZoom
                } else {
                    currentZoom = deltaZoom
                }
            }
            .onEnded { _ in
                // Smoothly adjust to the final zoom level
                totalZoom = min(max(totalZoom + currentZoom, minZoom), maxZoom)
                currentZoom = 0 // Reset currentZoom for the next gesture
            }
    }
    
    //TODO: Determine how to enable, disable gestures based on enableGestures, isInPopover
    // You might want to combine this gesture with the dragGesture to allow both dragging and pinching
    private var combinedGestures: some Gesture {
        // Combine gestures with simultaneousGesture to allow both at the same time
        dragGesture.simultaneously(with: magnifyGesture)
    }
#endif
    
    // Toggle from SiteView for setting labels visable
    @Binding var labelsEnabled: Bool
    
    // Toggle from SiteView for enabling gestures
    @Binding var enableGestures: Bool
    
    @State private var computedEdges: [Edge] = []
    @State private var needsEdgeUpdate = true  // New state to trigger updates
        
    //Property for saving Devices' coordinates and pushing to NetBox
    @Binding var saveCoordinates: Bool
    
    @Binding var isHorizontalLayout: Bool
    
    let fontSize: CGFloat = 50
    @State private var currentLayout: Layout?
    
    @State private var userDefinedPositions: [Int64: CGPoint] = [:]

    #if os(macOS)
    @Environment(LicenseSeatStore.self) private var seats
    @State private var cableTether = CableTetherState()
    @State private var cablePair: CableDevicePair?
    #endif

    @State private var isCalculatingLayout: Bool = false
#if os(iOS)
    init(site: Site,
         selectedDevice: Binding<Device?>,
         enableGestures: Binding<Bool>,
         isInPopover: Bool,
         labelsEnabled: Binding<Bool>,
         saveCoordinates: Binding<Bool>,
         isHorizontalLayout: Binding<Bool>) {
        // iOS-specific initialization
        self.siteId = site.id
        self._selectedDevice = selectedDevice
        self.isInPopover = isInPopover
        self._labelsEnabled = labelsEnabled
        self._enableGestures = enableGestures
        self._saveCoordinates = saveCoordinates
        self._isHorizontalLayout = isHorizontalLayout
        
        self._devices = Query(filter: #Predicate<Device> { device in
            device.siteId == siteId
        }, animation: .easeInOut(duration: 0.15))
    }
#endif
    
    
    // macOS-specific initialization
#if os(macOS)
    init(siteId: Int64,
         selectedDevice: Binding<Device?>,
         enableGestures: Binding<Bool>,
         isInPopover: Bool,
         labelsEnabled: Binding<Bool>,
         saveCoordinates: Binding<Bool>,
         isHorizontalLayout: Binding<Bool>) {
        
        self.siteId = siteId
        self._selectedDevice = selectedDevice
        self.isInPopover = isInPopover
        self._labelsEnabled = labelsEnabled
        self._enableGestures = enableGestures
        self._saveCoordinates = saveCoordinates
        self._isHorizontalLayout = isHorizontalLayout
        
        self._devices = Query(filter: #Predicate<Device> { device in
            device.siteId == siteId
        }, animation: .easeInOut(duration: 0.15))
    }
#endif
    
    private func computeEdges() async {
        let vos = (try? SiteTopologyEdges.fetchVOs(siteId: siteId, in: modelContext)) ?? []
        let visible = Set(
            devices
                .filter { !rolePresentation.policy(for: $0.deviceRole?.id).hideFromGraph }
                .map(\.id)
        )
        let newEdges = SiteTopologyEdges.derive(from: vos).filter { edge in
            guard let start = edge.start.deviceId, let end = edge.end.deviceId else {
                return false
            }
            return visible.contains(start) && visible.contains(end)
        }
        await MainActor.run {
            self.computedEdges = newEdges
            self.needsEdgeUpdate = false
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .drawingGroup()
                .contentShape(Rectangle()) // Makes the entire area tappable/draggable, not just where the content is.
                #if os(iOS)
                .gesture(enableGestures ? combinedGestures : nil)
                #endif
                .overlay(
                    ZStack {
                        GridLayerView()
                        
                        EdgesLayer()

                        #if os(macOS)
                        if let sourceID = cableTether.sourceID {
                            CableTetherLine(start: anchor(for: sourceID), tether: cableTether)
                                .zIndex(1)
                                .allowsHitTesting(false)
                            CablePointerOverlay(
                                tracking: cableTether.phase == .tracking,
                                onMove: { moveCable($0) },
                                onLeave: { cableTether.overOrigin = false },
                                onLeftClick: { finishCable(at: $0) },
                                onRightClick: { retractCable() }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .zIndex(40)
                            if cableTether.phase == .tracking, let icon = iconFrames[sourceID] {
                                CableOriginMark(tether: cableTether)
                                    .position(originMarkCentre(icon))
                                    .allowsHitTesting(false)
                                    .zIndex(50)
                            }
                        }
                        #endif
                        
                        ForEach(devices.filter { !rolePresentation.policy(for: $0.deviceRole?.id).hideFromGraph }) { device in
                            let deviceId = device.id
                            
                            DeviceView(device: device,
                                       selectedDevice: $selectedDevice,
                                       position: positionBinding(for: deviceId),
                                       labelsEnabled: $labelsEnabled,
                                       enableGestures: $enableGestures,
                                       action: { cableAction(for: device)() },
                                       drawingCable: drawingCable,
                                       dragging: draggingNodeID == deviceId)
                            .position(positionBinding(for: deviceId).wrappedValue)
                            .zIndex(selectedDevice?.id == deviceId ? 20 : 5)
                            .allowsHitTesting(!drawingCable)
                            .onPreferenceChange(ImageCentrePreferenceKey.self) { center in
                                guard let center, imageCentres[deviceId] != center else { return }
                                imageCentres[deviceId] = center
                            }
                            .onPreferenceChange(IconFramePreferenceKey.self) { rect in
                                guard let rect, rect.width > 1, rect.height > 1, rect.width < 400, rect.height < 400 else { return }
                                guard iconFrames[deviceId] != rect else { return }
                                iconFrames[deviceId] = rect
                            }
                            .id(deviceId)
                            #if os (macOS)
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        guard enableGestures, cableTether.sourceID == nil else {
                                            if draggingNodeID == deviceId { draggingNodeID = nil }
                                            return
                                        }
                                        if draggingNodeID != deviceId {
                                            draggingNodeID = deviceId
                                        }
                                        userDefinedPositions[deviceId] = CGPoint(x: value.location.x, y: value.location.y)
                                    }
                                    .onEnded { _ in
                                        if draggingNodeID == deviceId {
                                            draggingNodeID = nil
                                        }
                                    },
                                including: enableGestures ? .all : .none
                            )
                            #endif
                        }
                    }
                    .coordinateSpace(name: siteDiagramCoordinateSpace)
                    #if os(macOS)
                        .background()
                        .onTapGesture {
                            #if os(macOS)
                            if cableTether.sourceID != nil {
                                return
                            }
                            #endif
                            if isInPopover {
                                // Wrap the id in `SiteWindowTarget` so
                                // this routes to the Site View scene by
                                // type, not by the Int64 registration
                                // order it once shared with the terminal
                                // scene; see SSHTerminalScene
                                // doc-comment for the routing rationale.
                                openWindow(id: "site-view", value: SiteWindowTarget(siteID: siteId))
                            }
                            selectedDevice = nil
                        }
                    #elseif os(iOS)
                        .offset(x: finalPosition.width + dragOffset.width, y: finalPosition.height + dragOffset.height)
                        .scaleEffect(currentZoom + totalZoom)
                    #endif
                        .task {
                            // Initial layout and edge computation
                            await MainActor.run {
                                isCalculatingLayout = true
                            }
                            
                            let container = modelContext.container
                            let actor = LayoutManager(modelContainer: container)
                            let layout = await actor.getLayout(for: siteId,
                                                               isHorizontalLayout: isHorizontalLayout,
                                                               userDefinedPositions: userDefinedPositions)
                            
                            // Compute edges right after layout
                            if needsEdgeUpdate {
                                await computeEdges()
                            }
                            
                            await MainActor.run {
                                self.currentLayout = layout
                                self.isCalculatingLayout = false
                            }
                        }
                        .onChange(of: isHorizontalLayout) {
                            Task.detached(priority: .background) {
                                //TODO: Conform to Swift 6 standards
                                await recalculateLayout()
                                await computeEdges()
                            }
                            try? modelContext.save()
                        }
                        .onChange(of: saveCoordinates) {
                            if saveCoordinates == true {
                                Task.detached(priority: .background) {
                                    await saveDevicePositions()
                                }
                                // Reset saveCoordinates to false after saving
                                saveCoordinates = false
                            }
                        }
                )
        }
        .task(id: siteId) {
            await computeEdges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .netBoxStoreDidApply)) { _ in
            Task { await computeEdges() }
        }
        .onChange(of: rolePresentation.presentation) {
            iconFrames = [:]
            Task { await computeEdges() }
        }
        #if os(macOS)
        .onChange(of: enableGestures) { _, enabled in
            if !enabled {
                cablePair = nil
                retractCable()
            }
        }
        .onDisappear {
            if cablePair == nil {
                resetCableTether()
            }
        }
        .sheet(item: $cablePair) { pair in
            CablePairSheet(pair: pair, onCancel: {
                cablePair = nil
                retractCable()
            }, onCreated: {
                cablePair = nil
                dissolveCable()
            })
        }
        #endif
    }
}

extension CGPoint {
    static func +(lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        return CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
}

///Extension containing helper methods for the SiteGraphView
extension SiteGraphView {
    
    private func saveDevicePositions() async {
        do {
            try modelContext.save()
        } catch {
            print("Error: \(error)")
        }
        
    }
    
    private func positionLabel(edge: Edge, points: (start: CGPoint, end: CGPoint), ratio: CGFloat) -> CGPoint {
        let labelX = points.start.x + (points.end.x - points.start.x) * ratio
        let labelY = points.start.y + (points.end.y - points.start.y) * ratio - 15
        return CGPoint(x: labelX, y: labelY)
    }
    
    /**
     Computes the position of the EdgeView's start and end points to be centred to the Image component of DeviceView, rather than the entire DeviceView itself.
     */
    private func adjustPoints(edge: Edge) -> (start: CGPoint, end: CGPoint)? {
        guard let imageCentreStart = imageCentres[edge.start.deviceId ?? 0],
              let imageCentreEnd = imageCentres[edge.end.deviceId ?? 0] else {
            return nil
        }
        
        let startPosition = positionBinding(for: edge.start.deviceId ?? 0).wrappedValue
        let endPosition = positionBinding(for: edge.end.deviceId ?? 0).wrappedValue
        
        let adjustedStart = CGPoint(x: startPosition.x + imageCentreStart.x,
                                   y: startPosition.y + imageCentreStart.y)
        let adjustedEnd = CGPoint(x: endPosition.x + imageCentreEnd.x,
                                 y: endPosition.y + imageCentreEnd.y)
        
        return (start: adjustedStart, end: adjustedEnd)
    }
    
    //TODO: Refactor to Swift 6 standards
    private func loadLayout() async {
        await MainActor.run { isCalculatingLayout = true }
        
        let container = modelContext.container
        let actor = LayoutManager(modelContainer: container)
        
        let isHorizontal = isHorizontalLayout
        
        let layout = await actor.getLayout(for: siteId, isHorizontalLayout: isHorizontal, userDefinedPositions: userDefinedPositions)
        
        await MainActor.run {
            self.currentLayout = layout
            isCalculatingLayout = false
        }
    }
    
    private func recalculateLayout() async {
        await MainActor.run { isCalculatingLayout = true }
        
        let container = modelContext.container
        let actor = LayoutManager(modelContainer: container)
        
        // Capture the current value of isHorizontalLayout
        let isHorizontal = isHorizontalLayout
        
        let newLayout = await actor.getLayout(for: siteId, isHorizontalLayout: isHorizontal, userDefinedPositions: userDefinedPositions)
        
        await MainActor.run {
            self.currentLayout = newLayout
            isCalculatingLayout = false
        }
    }

    /// Image centre in the diagram, the same sum drawn edges use.
    /// Falls back to the node origin until the preference key reports.
    private func anchor(for deviceId: Int64) -> CGPoint {
        let origin = positionBinding(for: deviceId).wrappedValue
        guard let centre = imageCentres[deviceId] else { return origin }
        return CGPoint(x: origin.x + centre.x, y: origin.y + centre.y)
    }

    private var drawingCable: Bool {
        #if os(macOS)
        cableTether.sourceID != nil
        #else
        false
        #endif
    }

    private func cableAction(for device: Device) -> () -> Void {
        #if os(macOS)
        return { handleCableTap(device) }
        #else
        _ = device
        return {}
        #endif
    }

    #if os(macOS)
    /// The icon under the pointer, ignoring the label. A move walks this
    /// site's icon frames once, about 200.
    private func iconHit(at point: CGPoint, excluding sourceID: Int64?) -> Int64? {
        var best: (Int64, CGFloat)?
        for (id, rect) in iconFrames {
            guard id != sourceID, rect.contains(point), seats.allowsActions(deviceID: id) else { continue }
            let centre = anchor(for: id)
            let distance = hypot(centre.x - point.x, centre.y - point.y)
            if let current = best {
                if distance < current.1 { best = (id, distance) }
            } else {
                best = (id, distance)
            }
        }
        return best?.0
    }

    private func snapAnchor(near point: CGPoint, excluding sourceID: Int64) -> CGPoint? {
        guard let id = iconHit(at: point, excluding: sourceID) else { return nil }
        return anchor(for: id)
    }

    private func device(near point: CGPoint, excluding sourceID: Int64? = nil) -> Device? {
        guard let id = iconHit(at: point, excluding: sourceID) else { return nil }
        return devices.first { $0.id == id }
    }

    private func finishCable(at point: CGPoint) {
        if cableTether.overOrigin,
           let sourceID = cableTether.sourceID,
           let icon = iconFrames[sourceID],
           originMarkRect(icon).contains(point) {
            retractCable()
            return
        }
        guard let device = device(near: point, excluding: cableTether.sourceID) else { return }
        handleCableTap(device)
    }

    private func handleCableTap(_ device: Device) {
        guard enableGestures else { return }
        guard seats.allowsActions(deviceID: device.id) else { return }
        if cableTether.sourceID == nil {
            cableTether.generation += 1
            cableTether.phase = .tracking
            cableTether.opacity = 1
            cableTether.sourceID = device.id
            cableTether.end = anchor(for: device.id)
            return
        }
        guard cableTether.phase == .tracking else { return }
        guard let sourceID = cableTether.sourceID,
              seats.allowsLink(a: sourceID, b: device.id) else {
            return
        }
        lockCable(to: device)
    }

    /// The sheet is up, and the write that follows. The stroke stays on
    /// the two devices. The pointer no longer moves it.
    private func lockCable(to device: Device) {
        guard let sourceID = cableTether.sourceID else { return }
        cableTether.phase = .locked
        cableTether.end = anchor(for: device.id)
        cablePair = CableDevicePair(
            sourceID: sourceID,
            sourceName: devices.first { $0.id == sourceID }?.name ?? "Device",
            targetID: device.id,
            targetName: device.name ?? "Device"
        )
    }

    /// Right-click, the X on the start device, a cancelled sheet, or leaving
    /// build mode.
    /// The end springs back to the start, then the stroke fades.
    /// `end` stays put so the retract shape can leave from where the pointer
    /// was. A sheet that is still up owns the stroke; its cancel clears the
    /// pair first.
    private func retractCable() {
        guard cablePair == nil else { return }
        guard cableTether.sourceID != nil else { return }
        guard cableTether.phase == .tracking || cableTether.phase == .locked else { return }
        cableTether.phase = .retracting
        cableTether.generation += 1
        let token = cableTether.generation
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard cableTether.generation == token else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                cableTether.opacity = 0
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard cableTether.generation == token else { return }
            resetCableTether()
        }
    }

    /// The write landed. The temporary stroke fades over the stored edge.
    private func dissolveCable() {
        guard cableTether.sourceID != nil else { return }
        cableTether.phase = .locked
        cableTether.generation += 1
        let token = cableTether.generation
        withAnimation(.easeOut(duration: 0.28)) {
            cableTether.opacity = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard cableTether.generation == token else { return }
            resetCableTether()
        }
    }

    private func resetCableTether() {
        cableTether.sourceID = nil
        cableTether.phase = .tracking
        cableTether.opacity = 1
        cableTether.overOrigin = false
    }

    /// The overlay calls this on each move. The stroke reads `end`.
    /// `overOrigin` flips only when the pointer enters or leaves the start device.
    private func moveCable(_ location: CGPoint) {
        guard cableTether.phase == .tracking, let sourceID = cableTether.sourceID else { return }
        let over = iconFrames[sourceID].map { pointerOnOrigin($0, location) } ?? false
        if cableTether.overOrigin != over {
            cableTether.overOrigin = over
        }
        let point = snapAnchor(near: location, excluding: sourceID) ?? location
        guard cableTether.end != point else { return }
        cableTether.end = point
    }

    /// Same seat as the plus: bottom-trailing of the icon, lifted 34 points.
    private func originMarkCentre(_ icon: CGRect) -> CGPoint {
        CGPoint(
            x: icon.maxX - cableOriginSide / 2,
            y: icon.maxY - cableOriginSide / 2 - cableOriginLift
        )
    }

    private func originMarkRect(_ icon: CGRect) -> CGRect {
        let centre = originMarkCentre(icon)
        return CGRect(
            x: centre.x - cableOriginSide / 2,
            y: centre.y - cableOriginSide / 2,
            width: cableOriginSide,
            height: cableOriginSide
        )
    }

    private func pointerOnOrigin(_ icon: CGRect, _ point: CGPoint) -> Bool {
        icon.contains(point) || originMarkRect(icon).contains(point)
    }
    #endif

    private func positionBinding(for deviceId: Int64) -> Binding<CGPoint> {
        Binding(
            get: {
                userDefinedPositions[deviceId]
                    ?? currentLayout?.positions[deviceId]
                    ?? CGPoint(x: 150, y: 150)
            },
            set: { newValue in
                userDefinedPositions[deviceId] = newValue
            }
        )
    }
    
    /**
     Calculates the final position to center the view based on the average position of devices.
     - Parameter geometry: The geometry proxy to calculate the relative size and position.
     - Note: This method calculates the average X and Y coordinates of all devices and adjusts the final position based on the view's geometry.
     */
    private func calculateFinalPosition(geometry: GeometryProxy) {
        let padding: CGFloat = 50 // Add some padding around the graph
        
        let minX = devices.map { $0.x ?? 0.0 }.min() ?? 0
        let minY = devices.map { $0.y ?? 0.0 }.min() ?? 0
        let maxX = devices.map { $0.x ?? 0.0 }.max() ?? 0
        let maxY = devices.map { $0.y ?? 0.0 }.max() ?? 0
        
        let graphWidth = maxX - minX
        let graphHeight = maxY - minY
        
        let viewWidth = geometry.size.width
        let viewHeight = geometry.size.height
        
        let scaleX = (viewWidth - 2 * padding) / CGFloat(graphWidth)
        let scaleY = (viewHeight - 2 * padding) / CGFloat(graphHeight)
        
        let scale = min(scaleX, scaleY)
        
        let offsetX = (viewWidth - scale * CGFloat(graphWidth)) / 2
        let offsetY = (viewHeight - scale * CGFloat(graphHeight)) / 2
        
        finalPosition.width = offsetX
        finalPosition.height = offsetY
    }
    
    /**
     Calculates the total zoom needed to fit all devices within the view.
     - Parameter geometry: The geometry proxy to calculate the relative size and position.
     - Note: This method determines the min and max X and Y coordinates of devices and calculates the scale to fit all devices comfortably within the view.
     */
    private func calculateTotalZoom(geometry: GeometryProxy) {
        let padding: CGFloat = 35 // Define a padding to not stick the content to the edges.
        let maxX = devices.map { $0.x ?? 0.0 }.max() ?? 0
        let maxY = devices.map { $0.y ?? 0.0 }.max() ?? 0
        let minX = devices.map { $0.x ?? 0.0 }.min() ?? 0
        let minY = devices.map { $0.y ?? 0.0 }.min() ?? 0
        
        let contentWidth = maxX - minX + padding
        let contentHeight = maxY - minY + padding
        
        let scaleX = (geometry.size.width - padding) / contentWidth
        let scaleY = (geometry.size.height - padding) / contentHeight
        
        let selectedScale = min(scaleX, scaleY)
        
        if maxX == minX && maxY == minY {
            totalZoom = 1.0
        } else {
            // Set a minimum zoom level to ensure content is visible
            let minimumZoomLevel: CGFloat = 0.3
            totalZoom = max(selectedScale, minimumZoomLevel)
        }
    }
    
    /**
     Renders the edges between devices in the site graph.
     This function creates EdgeViews for each computed edge and adds labels if enabled.
     
     - Returns: A view containing all the edges and their labels.
     */
    @ViewBuilder
    private func EdgesLayer() -> some View {
        Group {
            ForEach(computedEdges, id: \.id) { edge in
                if let points = adjustPoints(edge: edge) {
                    EdgeView(start: points.start, end: points.end)
                        .id(edge.id)  // Force unique identity
                        .zIndex(2)
                    
                    if labelsEnabled {
                        let startPos = positionLabel(edge: edge, points: points, ratio: 0.25)
                        let endPos = positionLabel(edge: edge, points: points, ratio: 0.75)
                        
                        EdgeLabel(name: edge.start.name, position: startPos)
                            .zIndex(3)
                        EdgeLabel(name: edge.end.name, position: endPos)
                            .zIndex(3)
                    }
                }
            }
        }
    }
    
    /**
     Renders the persistent devices in the site graph.
     This function creates DeviceViews for each persistent device and handles their positioning and gestures.
     
     - Returns: A view containing all the persistent devices.
     */
    @ViewBuilder
    private func DevicesLayer() -> some View {
        
        ForEach(devices.filter { !rolePresentation.policy(for: $0.deviceRole?.id).hideFromGraph }) { device in
            let deviceId = device.id
            
            DeviceView(device: device,
                       selectedDevice: $selectedDevice,
                       position: positionBinding(for: deviceId),
                       labelsEnabled: $labelsEnabled,
                       enableGestures: $enableGestures,
                       action: {})
            .position(positionBinding(for: deviceId).wrappedValue)
            .zIndex(selectedDevice?.id == deviceId ? 20 : 5)
            .onPreferenceChange(ImageCentrePreferenceKey.self) { center in
                Task { @MainActor in
                    if let center = center {
                        imageCentres[deviceId] = center
                    }
                }
            }
            .id(deviceId)
            #if os (macOS)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard enableGestures else { return }
                        let newPosition = CGPoint(x: value.location.x, y: value.location.y)
                        userDefinedPositions[deviceId] = newPosition
                    },
                including: enableGestures ? .all : .none
            )
            #endif
        }
    }
}

