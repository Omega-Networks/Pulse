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

typealias NodeID = Int64

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
    @State private var isHovering: Bool = false
    var siteId: Int64
    var isInPopover: Bool
    
    @Query var devices: [Device]
    @Binding var selectedDevice: Device?
    
    @State private var imageCentres: [Int64: CGPoint] = [:]
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
        }, animation: .bouncy.speed(0.1))
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
        }, animation: .bouncy.speed(0.1))
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
                    #if os(macOS)
                        .background()
                        .onTapGesture {
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
                        .onContinuousHover{ phase in
                            switch phase {
                            case .active:
                                isHovering = true
                            case .ended:
                                isHovering = false
                            }
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
            Task { await computeEdges() }
        }
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
        .animation(.easeInOut, value: computedEdges)
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

