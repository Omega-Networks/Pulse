//
//  ChartPicker.swift
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
import Charts
import SwiftData

struct SelectedChart: View {
    @Environment(\.modelContext) private var modelContext
    
    let deviceId: Int64
    let itemId: String
    
    @State private var item: Item?
    @State private var displayMode: DisplayMode = .text
    @State private var hoverLocation: CGPoint = .zero
    @State private var selectedDate: Date?
    @State private var isHovering = false
    @State private var historyData: [Date: String] = [:]
    @State private var volumeData: [Date: Double] = [:]
    @State private var isLoading = false
    
    @State private var debounceTask: Task<Void, Never>?
    
    @Binding var selectedPeriod: String
    
    // Add processor
    private let dataProcessor = ChartDataProcessor()
    
    private var processedData: [Date: String] {
        dataProcessor.processData(historyData: historyData, period: selectedPeriod, item: item)
    }
    
    // Computed properties based on the historyValues
    var periodMin: Double? {
        return processedData.values.compactMap { Double($0) }.min()
    }
    
    var periodAverage: Double? {
        let values = processedData.values.compactMap { Double($0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
    
    var periodMax: Double? {
        return processedData.values.compactMap { Double($0) }.max()
    }
    
    private var canShowGraph: Bool {
        guard let unit = item?.units else { return false }
        return ["%" ,"bps", "s"].contains(unit)
    }
    
#if os(macOS)
    private let hoverColour: Color = Color.cyan
#endif
    
    private var foregroundColor: Color {
#if os(macOS)
        return isHovering ? hoverColour : .green
#else
        return .green
#endif
    }
    
    init(deviceId: Int64, itemId: String, selectedPeriod: Binding<String>) {
        self.deviceId = deviceId
        self.itemId = itemId
        self._selectedPeriod = selectedPeriod
    }
    
    //MARK: Chart view
    private var chart: some View {
        Chart {
            let historyArray = processedData.sorted(by: { $0.key < $1.key })
            
            // Existing line and area marks
            ForEach(historyArray, id: \.key) { (date, value) in
                if let originalValue = Double(value) {
                    let unit = item?.units ?? ""
                    let displayValue = getDisplayValue(for: originalValue, with: unit)
                    
                    LineMark(
                        x: .value("Date", date),
                        y: .value("Value", displayValue)
                    )
                    .foregroundStyle(foregroundColor)
                    
                    AreaMark(
                        x: .value("Date", date),
                        y: .value("Value", displayValue)
                    )
                    .foregroundStyle(LinearGradient(
                        gradient: Gradient(colors: [foregroundColor, .clear]),
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                }
            }
            
            // Single point mark for hover state
            if isHovering, let selectedDate = selectedDate,
               let interpolatedValue = interpolateValue(at: selectedDate, from: historyArray) {
                PointMark(
                    x: .value("Date", selectedDate),
                    y: .value("Value", interpolatedValue)
                )
                #if os(macOS)
                .foregroundStyle(hoverColour)
                #endif
                .symbolSize(110)
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartPlotStyle { chartPlotStyle($0) }
        .chartYAxis {
            switch item?.units {
            case "%":
                AxisMarks(
                    format: Decimal.FormatStyle.Percent.percent.scale(1)
                )
            case "bps":
                AxisMarks(
                    format: Decimal.FormatStyle()
                )
            default:
                AxisMarks(
                    format: Decimal.FormatStyle()
                )
            }
        }
        .applyDomain(item?.units == "%") {
            $0.chartYScale(domain: [0, 100])
        }
        .chartYScale(domain: .automatic)
#if os(macOS)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let frame = geometry[plotFrame]
                    ZStack {
                        
                        if let selectedDate = selectedDate {
                            let unit = item?.units ?? ""
                            let closestDate = historyData.keys.min(by: { abs($0.timeIntervalSince(selectedDate)) < abs($1.timeIntervalSince(selectedDate)) })
                            
                            if let closestDate = closestDate, let value = historyData[closestDate] {
                                let displayValue = getDisplayValue(for: Double(value) ?? 0, with: unit)
                                displayText(for: displayValue, unit: unit)
                                    .fontWeight(.medium)
                                    .foregroundColor(.cyan)
                                    .position(x: hoverLocation.x, y: (frame.minY + 10))
                            }
                        }
                        
                        Rectangle()
                            .fill(hoverColour)
                            .frame(width: 1, height: frame.height)
                            .position(x: hoverLocation.x, y: frame.midY)
                            .opacity(isHovering ? 1 : 0)
                            .allowsHitTesting(false)
                        
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    if location.x >= 0 && location.x <= frame.width {
                                        DispatchQueue.main.async {
                                            hoverLocation = location
                                            isHovering = true
                                            
                                            if let date = proxy.value(atX: hoverLocation.x, as: Date.self) {
                                                let closestDate = historyData.keys.min(by: { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) })
                                                selectedDate = closestDate
                                            }
                                        }
                                    }
                                case .ended:
                                    isHovering = false
                                    selectedDate = nil
                                }
                            }
                    }
                    .drawingGroup()
                    .frame(width: geometry.size.width, height: (geometry.size.height + 20) )
                }
            }
        }
#endif
    }
    
    //MARK: - Main body view of ItemChart
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            Text("\(item?.name ?? "N/A")")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.vertical)
            
            // Chart content
            Group {
                if canShowGraph {
                    // Period picker
                    periodPickerView(selectedPeriod: $selectedPeriod)
                    
                    if isLoading {
                        loadingView
                    } else if !historyData.isEmpty {
                        // Main chart
                        chart
                        
                        // Statistics
                        if let min = periodMin,
                           let max = periodMax,
                           let average = periodAverage,
                           let item = item{
                            statisticsView(min: min, max: max, average: average, item: item)
                        }
                        
                    } else {
                        noDataView
                    }
                } else {
                    // Simple text display for non-graphable data
                    if let value = historyData.values.first {
                        Text(value)
                            .font(.body)
                    } else {
                        Text("No data to display")
                    }
                }
            }
        }
        .padding(.top, 30)
        .task {
            await loadItem()
        }
        .onChange(of: itemId) {
            Task.detached(priority: .background) {
                await loadItem()
            }
        }
        .onChange(of: selectedPeriod) {
            Task.detached(priority: .background) {
                if await canShowGraph {  // Only fetch history for graphable data
                    await fetchHistoryData()
                }
            }
        }
    }
    
    //MARK: Supplemental views for the chart
    
    /**
     Creates a chart plot with an overlay style.
     - Parameters:
     - plotStyle: The content of the chart plot.
     - Returns: A View styled with the overlay for the chart plot.
     */
    private func chartPlotStyle(_ plotStyle: ChartPlotContent) -> some View {
        plotStyle
            .frame(height: 200)
            .overlay {
                Rectangle()
                    .foregroundColor(.gray.opacity(0.5))
                    .mask(ZStack {
                        VStack {
                            Rectangle().frame(height: 1)
                        }
                        
                        HStack {
                            Rectangle().frame(width: 0.3)
                        }
                    })
            }
    }
    
    // MARK: - Content Views (either displays a graph or a body of text depending on the display mode)
    
    /**
     * Displays item data as simple text.
     *
     * This view is used for non-graphable data types where a chart would not be appropriate.
     * It shows either the most recent value from the history data or a placeholder message
     * if no data is available.
     */
    @ViewBuilder
    private var textView: some View {
        if let value = historyData.values.first {
            Text(value)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Text("No data to display")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
    
    // MARK: - View Components
    
    @ViewBuilder
    private var loadingView: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .primary))
            .scaleEffect(0.7)
            .frame(maxWidth: .infinity, maxHeight: 200, alignment: .center) // Use specific height that matches chart
    }
    
    @ViewBuilder
    private var noDataView: some View {
        Text("No graph data to show.")
    }
    
    
    //MARK: - Supplemental views for the chart
    /**
     Displays the text for a given value based on its unit.
     - Parameters:
     - value: The numerical value to display.
     - unit: The unit of measurement for the value (e.g. "%", "bps").
     - Returns: A View representing the formatted text based on the given unit.
     */
    private func displayText(for value: Double, unit: String?) -> some View {
        switch unit {
        case "%":
            Text(String(format: "%.2f%%", value))
        case "bps":
            Text(String(format: "%.2f Mbps", value))
        default:
            Text(String(format: "%.2f", value))
        }
    }
    
    //MARK: Helper views (originally part of the body view, now separated to
    
    func periodPickerView(selectedPeriod: Binding<String>) -> some View {
        let periods = ["1H", "3H", "6H", "12H", "1D", "2D", "1W"]
        
        return HStack(alignment: .center) {
#if os(macOS)
            if isHovering, let selectedDate = selectedDate {
                Spacer()
                Text(selectedDate, format: .dateTime)
                    .fontWeight(.medium)
                Spacer()
            } else {
                Picker("", selection: selectedPeriod) {
                    ForEach(periods, id: \.self) { period in
                        Text(period).tag(period)
                            .fontWeight(.bold)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
#else
            Picker("", selection: selectedPeriod) {
                ForEach(periods, id: \.self) { period in
                    Text(period).tag(period)
                        .fontWeight(.bold)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
#endif
        }
        .frame(height: 32)  // Adjust this value to match your desired height
        .padding(.horizontal)  // Consistent horizontal padding
    }
    
    func statisticsView(min: Double, max: Double, average: Double, item: Item) -> some View {
        HStack {
            VStack {
                HStack {
                    Text("High")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formattedDisplayValue(for: max, with: item.units))
                        .fontWeight(.medium)
                }
                .frame(width: 200)
                
                HStack {
                    Text("Low")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formattedDisplayValue(for: min, with: item.units))
                        .fontWeight(.medium)
                }
                .frame(width: 200)
                
                HStack {
                    Text("Avg.")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formattedDisplayValue(for: average, with: item.units))
                        .fontWeight(.medium)
                }
                .frame(width: 200)
            }
        }
    }
    
    //MARK: Helper functions
    
    /**
     Formats the display value of a measurement based on its unit.
     - Parameters:
     - originalValue: The original numerical value.
     - unit: The unit of measurement for the value (e.g. "%", "bps").
     - Returns: A String representing the formatted value based on the given unit.
     */
    private func formattedDisplayValue(for originalValue: Double, with unit: String) -> String {
        switch unit {
        case "%":
            return String(format: "%.2f%%", originalValue)
        case "bps":
            return String(format: "%.2f Mbps", originalValue / 1_000_000)
        default:
            return String(format: "%.2f \(unit)", originalValue)
        }
    }
    
    /**
     Calculates the display value of a measurement based on its unit.
     - Parameters:
     - originalValue: The original numerical value.
     - unit: The unit of measurement for the value (e.g. "%", "bps").
     - Returns: A Double representing the value to display based on the given unit.
     */
    private func getDisplayValue(for originalValue: Double, with unit: String) -> Double {
        switch unit {
//        case "%":
//            return originalValue / 100
        case "bps":
            return originalValue / 1_000_000  // Convert from bits per second to Mbps
        default:
            return originalValue
        }
    }
    
    /**
     Formats a Date object into a string representation.
     - Parameters:
     - date: The date to format.
     - Returns: A String representing the formatted date.
     */
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }
}

extension SelectedChart {
    /**
     * Fetches only the most recent value for text-only display.
     *
     * This optimized fetch function is used for non-graphable items where
     * only the latest value is needed. It:
     * 1. Fetches a minimal amount of history
     * 2. Extracts the most recent value
     * 3. Updates the UI with just that value
     *
     * This approach prevents unnecessary data loading and processing for text-only items.
     */
    private func fetchLatestValue() async {
        guard let item = item else { return }
        
        let historyFetcher = HistoryFetcher(modelContainer: modelContext.container)
        let (fetchedData, _) = await historyFetcher.getHistories(
            deviceId: deviceId,
            itemId: item.itemId,
            selectedPeriod: "1H", // Just fetch most recent
            valueType: item.valueType
        )
        
        await MainActor.run {
            // Only keep the most recent value for text display
            if let mostRecent = fetchedData.max(by: { $0.key < $1.key }) {
                self.historyData = [mostRecent.key: mostRecent.value]
            }
        }
    }
    
    /**
     * Fetches complete historical data for chart display.
     *
     * This function handles the full data loading process for chartable items:
     * 1. Fetches initial data for immediate display
     * 2. Updates the UI with available data
     * 3. If partial data was returned, initiates a background task to fetch complete data
     * 4. Updates the UI again when complete data is available
     *
     * The function ensures responsive UI updates while maintaining data completeness.
     */
    private func fetchHistoryData() async {
        guard let item = item else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        let historyFetcher = HistoryFetcher(modelContainer: modelContext.container)
        let (fetchedData, isPartialData) = await historyFetcher.getHistories(
            deviceId: deviceId,
            itemId: item.itemId,
            selectedPeriod: selectedPeriod,
            valueType: item.valueType
        )
        
        await MainActor.run {
            historyData = fetchedData
        }
        
        if isPartialData {
            Task.detached(priority: .background) {
                let (completeData, _) = await historyFetcher.getHistories(
                    deviceId: deviceId,
                    itemId: item.itemId,
                    selectedPeriod: selectedPeriod,
                    valueType: item.valueType
                )
                await MainActor.run {
                    self.historyData = completeData
                }
            }
        }
    }
    
    // MARK: - Data Loading
    
    /**
     * Loads and initializes item data asynchronously.
     *
     * This function handles the complete item loading process:
     * 1. Fetches the item from cache
     * 2. Determines the appropriate display mode
     * 3. Triggers the appropriate data loading strategy (chart or text)
     *
     * The function manages loading state and ensures proper error handling.
     */
    private func loadItem() async {
        isLoading = true
        defer { isLoading = false }
        
        if let cachedItem = await ItemCache.shared.getItemById(itemId) {
            print("Found item: \(cachedItem.name) with ID: \(cachedItem.itemId)")
            await MainActor.run {
                self.item = cachedItem
            }
            
            if canShowGraph {
                await fetchHistoryData()
            } else {
                // For non-graphable data, just fetch the latest value
                let historyFetcher = HistoryFetcher(modelContainer: modelContext.container)
                let (fetchedData, _) = await historyFetcher.getHistories(
                    deviceId: deviceId,
                    itemId: cachedItem.itemId,
                    selectedPeriod: "1H",  // Just fetch recent data
                    valueType: cachedItem.valueType
                )
                
                await MainActor.run {
                    if let mostRecent = fetchedData.max(by: { $0.key < $1.key }) {
                        self.historyData = [mostRecent.key: mostRecent.value]
                    }
                }
            }
        } else {
            print("No item found for ID: \(itemId)")
        }
    }
    
    /**
    * Interpolates a value for a given date between two known data points.
    *
    * This function performs linear interpolation between the two closest data points
    * to provide smooth hover value display. When exact interpolation isn't possible,
    * it falls back to the nearest available value.
    *
    * @param date The target date to interpolate a value for
    * @param data Array of date-value pairs to interpolate between
    * @return The interpolated value converted to display units, or nil if interpolation fails
    */
    private func interpolateValue(at date: Date, from data: [(key: Date, value: String)]) -> Double? {
        // Find the two closest points
        guard let beforeIndex = data.lastIndex(where: { $0.key <= date }),
              beforeIndex + 1 < data.count else {
            // If we can't interpolate, return the closest point's value
            return data.min(by: { abs($0.key.timeIntervalSince(date)) < abs($1.key.timeIntervalSince(date)) })
                .flatMap { Double($0.value) }
                .map { getDisplayValue(for: $0, with: item?.units ?? "") }
        }
        
        let before = data[beforeIndex]
        let after = data[beforeIndex + 1]
        
        guard let beforeValue = Double(before.value),
              let afterValue = Double(after.value) else {
            return nil
        }
        
        // Calculate the interpolation factor (0 to 1)
        let totalTime = after.key.timeIntervalSince(before.key)
        let currentTime = date.timeIntervalSince(before.key)
        let factor = totalTime > 0 ? currentTime / totalTime : 0
        
        // Linear interpolation between the two points
        let interpolatedRawValue = beforeValue + (afterValue - beforeValue) * factor
        return getDisplayValue(for: interpolatedRawValue, with: item?.units ?? "")
    }
    
    private func handleHover(location: CGPoint, date: Date?, frame: CGRect) {
        if location.x >= 0 && location.x <= frame.width {
            hoverLocation = location
            isHovering = true
            selectedDate = date
        }
    }
}

extension View {
    /**
     Applies the domain given the unit is a %.
     */
    @ViewBuilder
    func applyDomain<T: View>(_ condition: Bool, apply: (Self) -> T) -> some View {
        if condition {
            apply(self)
        } else {
            self
        }
    }
}

//#Preview {
//    ItemChart(itemId: "0", startDate: Binding<.now>)
//}
