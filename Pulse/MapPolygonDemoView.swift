import SwiftUI
import MapKit

struct MapPolygonDemoView: View {
    // Enhanced state for more comprehensive styling options
    @State private var opacity: Double = 0.5
    @State private var strokeWidth: CGFloat = 2.0
    @State private var selectedPolygon: Int = 0
    @State private var fillStyle: FillStyle = .solid
    @State private var strokeStyle: StrokePattern = .solid
    @State private var gradientType: GradientType = .linear
    @State private var colorScheme: ColorScheme = .blue
    @State private var showMultiplePolygons: Bool = false
    @State private var animateChanges: Bool = true
    
    // Predefined polygon shapes for testing
    @State private var polygonShapes: [PolygonShape] = [
        PolygonShape(
            name: "Square",
            coordinates: [
                CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                CLLocationCoordinate2D(latitude: 37.7849, longitude: -122.4194),
                CLLocationCoordinate2D(latitude: 37.7849, longitude: -122.4094),
                CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4094)
            ]
        ),
        PolygonShape(
            name: "Triangle",
            coordinates: [
                CLLocationCoordinate2D(latitude: 37.7799, longitude: -122.4144),
                CLLocationCoordinate2D(latitude: 37.7849, longitude: -122.4044),
                CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4044)
            ]
        ),
        PolygonShape(
            name: "Pentagon",
            coordinates: [
                CLLocationCoordinate2D(latitude: 37.7799, longitude: -122.4244),
                CLLocationCoordinate2D(latitude: 37.7839, longitude: -122.4214),
                CLLocationCoordinate2D(latitude: 37.7829, longitude: -122.4174),
                CLLocationCoordinate2D(latitude: 37.7769, longitude: -122.4174),
                CLLocationCoordinate2D(latitude: 37.7759, longitude: -122.4214)
            ]
        )
    ]
    
    // State for map camera position
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7799, longitude: -122.4144),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
    )
    
    // Computed properties for styling
    private var currentFillStyle: AnyShapeStyle {
        let baseColors = colorScheme.colors
        
        switch fillStyle {
        case .solid:
            return AnyShapeStyle(baseColors[0].opacity(opacity))
        case .gradient:
            switch gradientType {
            case .linear:
                return AnyShapeStyle(LinearGradient(
                    colors: baseColors.map { $0.opacity(opacity) },
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            case .radial:
                return AnyShapeStyle(RadialGradient(
                    colors: baseColors.map { $0.opacity(opacity) },
                    center: .center,
                    startRadius: 0,
                    endRadius: 100
                ))
            case .angular:
                return AnyShapeStyle(AngularGradient(
                    colors: baseColors.map { $0.opacity(opacity) },
                    center: .center
                ))
            }
        case .pattern:
            return AnyShapeStyle(baseColors[0].opacity(opacity))
        }
    }
    
    private var currentStrokeStyle: StrokeStyle {
        switch strokeStyle {
        case .solid:
            return StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
        case .dashed:
            return StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round, dash: [10, 5])
        case .dotted:
            return StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round, dash: [2, 3])
        case .dashDot:
            return StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round, dash: [10, 3, 2, 3])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Map with customizable MapPolygon(s)
            Map(position: $cameraPosition) {
                if showMultiplePolygons {
                    // Show all polygon shapes with different styles
                    ForEach(0..<polygonShapes.count, id: \.self) { index in
                        MapPolygon(coordinates: polygonShapes[index].coordinates)
                            .foregroundStyle(getStyleForIndex(index))
                            .stroke(
                                getStrokeColorForIndex(index),
                                style: currentStrokeStyle
                            )
                    }
                } else {
                    // Show single selected polygon
                    MapPolygon(coordinates: polygonShapes[selectedPolygon].coordinates)
                        .foregroundStyle(currentFillStyle)
                        .stroke(
                            colorScheme.strokeColor,
                            style: currentStrokeStyle
                        )
                }
            }
            .mapStyle(.standard)
            .frame(height: 400)
            
            // Enhanced control panel
            ScrollView {
                VStack(spacing: 20) {
                    // Polygon Selection
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Polygon Shape")
                            .font(.headline)
                        
                        Picker("Shape", selection: $selectedPolygon) {
                            ForEach(0..<polygonShapes.count, id: \.self) { index in
                                Text(polygonShapes[index].name).tag(index)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        
                        Toggle("Show Multiple Polygons", isOn: $showMultiplePolygons)
                    }
                    
                    // Fill Style Controls
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Fill Style")
                            .font(.headline)
                        
                        Picker("Fill", selection: $fillStyle) {
                            ForEach(FillStyle.allCases, id: \.self) { style in
                                Text(style.rawValue.capitalized).tag(style)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        
                        if fillStyle == .gradient {
                            Picker("Gradient Type", selection: $gradientType) {
                                ForEach(GradientType.allCases, id: \.self) { type in
                                    Text(type.rawValue.capitalized).tag(type)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Opacity: \(opacity, specifier: "%.1f")")
                            Slider(value: $opacity, in: 0.1...1.0, step: 0.1)
                        }
                    }
                    
                    // Stroke Style Controls
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Stroke Style")
                            .font(.headline)
                        
                        Picker("Pattern", selection: $strokeStyle) {
                            ForEach(StrokePattern.allCases, id: \.self) { pattern in
                                Text(pattern.rawValue.capitalized).tag(pattern)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        
                        VStack(alignment: .leading) {
                            Text("Width: \(strokeWidth, specifier: "%.1f")")
                            Slider(value: $strokeWidth, in: 0.5...8.0, step: 0.5)
                        }
                    }
                    
                    // Color Scheme Controls
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Color Scheme")
                            .font(.headline)
                        
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                            ForEach(ColorScheme.allCases, id: \.self) { scheme in
                                Button(action: {
                                    if animateChanges {
                                        withAnimation(.easeInOut(duration: 0.5)) {
                                            colorScheme = scheme
                                        }
                                    } else {
                                        colorScheme = scheme
                                    }
                                }) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(LinearGradient(
                                            colors: scheme.colors,
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ))
                                        .frame(height: 30)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(colorScheme == scheme ? Color.primary : Color.clear, lineWidth: 2)
                                        )
                                }
                            }
                        }
                    }
                    
                    // Animation Controls
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Animation")
                            .font(.headline)
                        
                        Toggle("Animate Changes", isOn: $animateChanges)
                        
                        HStack {
                            Button("Reset to Defaults") {
                                let animation = animateChanges ? Animation.easeInOut(duration: 0.8) : nil
                                withAnimation(animation) {
                                    opacity = 0.5
                                    strokeWidth = 2.0
                                    fillStyle = .solid
                                    strokeStyle = .solid
                                    gradientType = .linear
                                    colorScheme = .blue
                                    selectedPolygon = 0
                                    showMultiplePolygons = false
                                }
                            }
                            
                            Spacer()
                            
                            Button("Random Style") {
                                let animation = animateChanges ? Animation.easeInOut(duration: 0.8) : nil
                                withAnimation(animation) {
                                    opacity = Double.random(in: 0.3...0.9)
                                    strokeWidth = CGFloat.random(in: 1.0...6.0)
                                    fillStyle = FillStyle.allCases.randomElement()!
                                    strokeStyle = StrokePattern.allCases.randomElement()!
                                    gradientType = GradientType.allCases.randomElement()!
                                    colorScheme = ColorScheme.allCases.randomElement()!
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }
    
    // Helper functions
    private func getStyleForIndex(_ index: Int) -> AnyShapeStyle {
        let schemes = ColorScheme.allCases
        let scheme = schemes[index % schemes.count]
        return AnyShapeStyle(scheme.colors[0].opacity(opacity * 0.7))
    }
    
    private func getStrokeColorForIndex(_ index: Int) -> Color {
        let schemes = ColorScheme.allCases
        let scheme = schemes[index % schemes.count]
        return scheme.strokeColor
    }
}

// Supporting types and enums
struct PolygonShape {
    let name: String
    let coordinates: [CLLocationCoordinate2D]
}

enum FillStyle: String, CaseIterable {
    case solid, gradient, pattern
}

enum StrokePattern: String, CaseIterable {
    case solid, dashed, dotted, dashDot
}

enum GradientType: String, CaseIterable {
    case linear, radial, angular
}

enum ColorScheme: CaseIterable {
    case blue, red, green, purple, orange, teal, pink, indigo
    
    var colors: [Color] {
        switch self {
        case .blue: return [.blue, .cyan]
        case .red: return [.red, .pink]
        case .green: return [.green, .mint]
        case .purple: return [.purple, .indigo]
        case .orange: return [.orange, .yellow]
        case .teal: return [.teal, .blue]
        case .pink: return [.pink, .purple]
        case .indigo: return [.indigo, .blue]
        }
    }
    
    var strokeColor: Color {
        switch self {
        case .blue: return .blue
        case .red: return .red
        case .green: return .green
        case .purple: return .purple
        case .orange: return .orange
        case .teal: return .teal
        case .pink: return .pink
        case .indigo: return .indigo
        }
    }
}

#Preview {
    MapPolygonDemoView()
}
