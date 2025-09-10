//
//  Layout.swift
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
import SwiftData
import SwiftUI

struct Layout {
    let id: UUID
    let name: String
    var positions: [Int64: CGPoint]
    let isHorizontal: Bool
}

/// Actor responsible for executing the Sugiyama algorithm and managing layouts
actor LayoutManager {
    private var calculatedLayouts: [Int64: Layout] = [:]
    
    var modelContainer: ModelContainer
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }
    
    /**
     Retrieves or calculates a layout for a given site.
     
     - Parameters:
     - site: The site for which to get or calculate the layout.
     - isHorizontalLayout: Boolean indicating if the layout should be horizontal.
     
     - Returns: A Layout object containing the positions of devices for the site.
     */
    func getLayout(for siteID: Int64, isHorizontalLayout: Bool, userDefinedPositions: [Int64: CGPoint]) async -> Layout {
        let modelContext = ModelContext(modelContainer)
        
        // Fetch the site using the ID
        guard let site = try? modelContext.fetch(FetchDescriptor<Site>(predicate: #Predicate { $0.id == siteID })).first else {
            return Layout(id: UUID(), name: "Unknown", positions: [:], isHorizontal: isHorizontalLayout)
        }
        
        // Check if we have a valid cached layout
        if let existingLayout = calculatedLayouts[site.id],
           existingLayout.isHorizontal == isHorizontalLayout,
           !needsRecalculation(for: site) {
            return existingLayout
        }
        // Calculate and return a new layout if needed
        return await calculateLayout(for: site, isHorizontalLayout: isHorizontalLayout, userDefinedPositions: userDefinedPositions)
    }
    
    /**
     Determines if a site's layout needs recalculation.
     
     - Parameter site: The site to check for recalculation need.
     
     - Returns: Boolean indicating if recalculation is needed.
     */
    private func needsRecalculation(for site: Site) -> Bool {
        guard let devices = site.devices, !devices.isEmpty else { return false }
        
        // If there's only one device, check if it needs adjustment
        if devices.count == 1, let device = devices.first {
            return device.x == 0 && device.y == 0 || device.x ?? 0 < 0 || device.y ?? 0 < 0
        }
        
        // For multiple devices, check if any need recalculation
        return devices.contains { device in
            device.x == 0 && device.y == 0 || device.x ?? 0 < 0 || device.y ?? 0 < 0
        }
    }
    
    /**
     Calculates a new layout for a given site.
     
     - Parameters:
     - site: The site for which to calculate the layout.
     - isHorizontalLayout: Boolean indicating if the layout should be horizontal.
     
     - Returns: A new Layout object with calculated device positions.
     */
    private func calculateLayout(for site: Site, isHorizontalLayout: Bool, userDefinedPositions: [Int64: CGPoint]) async -> Layout {
        guard let devices = site.devices, !devices.isEmpty else {
            // Return an empty layout if there are no devices
            return Layout(id: UUID(), name: site.name, positions: [:], isHorizontal: isHorizontalLayout)
        }
        
        // Handle single device case
        if devices.count == 1, let device = devices.first {
            let position = CGPoint(x: max(device.x ?? 150, 150), y: max(device.y ?? 150, 150))
            let positions = [device.id: position]
            return Layout(id: UUID(), name: site.name, positions: positions, isHorizontal: isHorizontalLayout)
        }
        
        // Proceed with full layout calculation for multiple devices
        let graph = await createGraph(site: site)
        let layerMap = await assignLayers(graph: graph)
        let layers = await reduceCrossings(graph: graph, layerMap: layerMap)
        let spacing: CGFloat = 150
        var coordinates = await assignCoordinates(layers: layers, spacing: spacing, isHorizontalLayout: isHorizontalLayout)
        
        // Apply user-defined positions
        for (deviceId, position) in userDefinedPositions {
            coordinates[deviceId] = position
        }
        
        let layout = Layout(id: UUID(), name: site.name, positions: coordinates, isHorizontal: isHorizontalLayout)
        calculatedLayouts[site.id] = layout
        
        return layout
    }
    
    /**
     Creates a graph representation of the site's devices and their connections.
     
     - Parameter site: The site for which to create the graph.
     
     - Returns: A Graph object representing the site's topology.
     */
    private func createGraph(site: Site) async -> Graph {
        guard let devices = site.devices else {
            return Graph(devices: [], connections: [])
        }
        
        var connections: [Edge] = []
        
        // Create edges for each connected interface
        for device in devices {
            let interfaces = await InterfaceCache.shared.getInterfaces(forDeviceId: device.id)
            for interface in interfaces {
                if let connectedEndpointId = interface.connectedEndpointId,
                   let connectedEndpoint = await getInterface(id: connectedEndpointId) {
                    let edge = Edge(start: interface, end: connectedEndpoint)
                    connections.append(edge)
                }
            }
        }
        
        return Graph(devices: Array(devices), connections: connections)
    }
    
    private func getInterface(id: Int64) async -> Interface? {
        return await InterfaceCache.shared.getInterface(withId: id)
    }

    
    /**
     Assigns layers to nodes based on their device roles.
     
     - Parameter graph: The graph representation of the site.
     
     - Returns: A dictionary mapping node IDs to their assigned layer numbers.
     */
    func assignLayers(graph: Graph) async -> [NodeID: Int] {
        let roleHierarchy = [
            ["Core Firewall", "Firewall"],
            ["Security Router"],
            ["Provider Edge", "Router"],
            ["Core Switch"],
            ["Distribution Switch"],
            ["Access Switch"],
            ["Server"],
            ["Wireless Bridge", "Wireless AP", "Camera", "Digital Display", "Edge Node"],
            ["Management Switch", "Terminal Server"],
            ["Management Firewall"],
            ["Other"]
        ]
        
        var layerMap: [NodeID: Int] = [:]
        var roleIndices: [Int: [NodeID]] = [:]
        
        // Assign nodes to layers based on their role
        for (nodeID, device) in graph.nodes {
            if let role = device.deviceRole?.name,
               let roleIndex = roleHierarchy.firstIndex(where: { $0.contains(role) }) {
                roleIndices[roleIndex, default: []].append(nodeID)
            }
        }
        
        // Sort roles and assign layer numbers
        let sortedRoleIndices = roleIndices.sorted { $0.key < $1.key }
        for (layer, roleIndex) in sortedRoleIndices.enumerated() {
            for nodeID in roleIndex.value {
                layerMap[nodeID] = layer
            }
        }
        
        // Sort roles and assign layer numbers
        let unknownLayer = sortedRoleIndices.count
        for (nodeID, _) in graph.nodes {
            if layerMap[nodeID] == nil {
                layerMap[nodeID] = unknownLayer
            }
        }
        
        return layerMap
    }
    
    /**
     Reduces edge crossings between layers.
     
     - Parameters:
     - graph: The graph representation of the site.
     - layerMap: A dictionary mapping node IDs to their assigned layers.
     
     - Returns: A dictionary of layers with their arranged nodes.
     */
    func reduceCrossings(graph: Graph, layerMap: [NodeID: Int]) async -> [Int: [NodeID]] {
        var layers: [Int: [NodeID]] = [:]
        
        // Group nodes by layers
        for (nodeID, layer) in layerMap {
            layers[layer, default: []].append(nodeID)
        }
        
        return layers
    }
    
    /**
     Calculates barycenters for nodes to aid in crossing reduction.
     
     - Parameters:
     - graph: The graph representation of the site.
     - nodes: The nodes to calculate barycenters for.
     - layerMap: A dictionary mapping node IDs to their assigned layers.
     
     - Returns: A dictionary of node IDs to their calculated barycenter values.
     */
    func calculateBarycenters(graph: Graph, nodes: [NodeID], layerMap: [NodeID: Int]) async -> [NodeID: Double] {
        var barycenters: [NodeID: Double] = [:]
        
        for node in nodes {
            let incomingNodes = graph.adjacencyList.filter { $0.value.contains(node) }.keys
            let sum = incomingNodes.reduce(0.0) { $0 + Double(layerMap[$1]!) }
            let count = Double(incomingNodes.count)
            barycenters[node] = count > 0 ? sum / count : Double(layerMap[node]!)
        }
        
        return barycenters
    }
    
    /**
     Assigns coordinates to nodes based on their layers and positions within layers.
     
     - Parameters:
     - layers: A dictionary of layers with their arranged nodes.
     - spacing: The spacing between nodes and layers.
     - isHorizontalLayout: Boolean indicating if the layout should be horizontal.
     
     - Returns: A dictionary mapping node IDs to their assigned coordinates.
     */
    func assignCoordinates(layers: [Int: [NodeID]], spacing: CGFloat, isHorizontalLayout: Bool) async -> [NodeID: CGPoint] {
        var coordinates: [NodeID: CGPoint] = [:]
        
        let buffer: CGFloat = 150 // Buffer from the edges
        let layerSpacing: CGFloat = spacing * 2 // Increased spacing between layers
        
        // Find the layer with the most devices for centering
        let maxNodeCount = layers.values.map { $0.count }.max() ?? 0
        let maxLayerDimension = CGFloat(maxNodeCount - 1) * spacing
        
        for (layerIndex, nodes) in layers {
            if nodes.isEmpty {
                continue // Skip empty layers
            }
            
            let nodeCount = nodes.count
            let totalDimension = CGFloat(nodeCount - 1) * spacing
            let startPosition = (maxLayerDimension - totalDimension) / 2 + buffer
            
            for (index, node) in nodes.enumerated() {
                let position = startPosition + CGFloat(index) * spacing
                let layerPosition = CGFloat(layerIndex) * layerSpacing + buffer
                
                // Assign coordinates based on layout orientation
                if isHorizontalLayout {
                    coordinates[node] = CGPoint(x: layerPosition, y: position)
                } else {
                    coordinates[node] = CGPoint(x: position, y: layerPosition)
                }
            }
        }
        
        return coordinates
    }
}
