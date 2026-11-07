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

struct SelectedChart: View {
    let itemId: String

    @State private var item: Item?
    @State private var textValue: String?
    @State private var isLoading = true
    @State private var plotted = PlottedSeries.empty(revision: 0)
    #if os(macOS)
    @State private var hover = GraphHover()
    #endif

    @Binding var selectedPeriod: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Float (0) and unsigned (3). The unit does not decide.
    private var canShowGraph: Bool {
        item?.valueType == "0" || item?.valueType == "3"
    }

    init(itemId: String, selectedPeriod: Binding<String>) {
        self.itemId = itemId
        self._selectedPeriod = selectedPeriod
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item?.name ?? "N/A")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.vertical)

            if canShowGraph {
                periodPickerView(selectedPeriod: $selectedPeriod)

                #if os(macOS)
                SeriesChart(revision: plotted.revision, plotted: plotted, hover: hover)
                    .equatable()
                    .hueRotation(.degrees(hover.visible ? hoverTintDegrees : 0))
                    .animation(nil, value: hover.visible)
                    .animation(chartMotion, value: plotted.revision)
                #else
                SeriesChart(revision: plotted.revision, plotted: plotted)
                    .equatable()
                    .animation(chartMotion, value: plotted.revision)
                #endif

                if let low = plotted.rawMin, let high = plotted.rawMax, let average = plotted.rawAverage {
                    statisticsView(min: low, max: high, average: average, unit: plotted.unit, revision: plotted.revision)
                }
            } else if isLoading {
                loadingView
            } else if let textValue {
                Text(textValue)
                    .font(.body)
            } else {
                Text("No data to display")
            }
        }
        .padding(.top, 30)
        // The chart stays mounted. The next series replaces the window, the scale, and the samples together.
        .task(id: "\(itemId)|\(selectedPeriod)") {
            #if os(macOS)
            hover.end()
            #endif
            await loadItem()
        }
    }

    private var loadingView: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: 200)
    }

    private func periodPickerView(selectedPeriod: Binding<String>) -> some View {
        #if os(macOS)
        GeometryReader { geometry in
            let inset = min(90, geometry.size.width / 2)
            let labelX = min(max(hover.pointerX, inset), max(inset, geometry.size.width - inset))
            ZStack {
                periodPicker(selectedPeriod)
                    .padding(.horizontal)
                    .opacity(hover.visible ? 0 : 1)
                    .scaleEffect(hover.visible ? 0.86 : 1)
                    .animation(hoverMotion, value: hover.visible)
                    .allowsHitTesting(!hover.visible)
                    .accessibilityHidden(hover.visible)
                VStack(spacing: 0) {
                    if let date = hover.sampleDate {
                        Text(date, format: .dateTime)
                    }
                    if !hover.valueLabel.isEmpty {
                        Text(hover.valueLabel)
                            .foregroundStyle(.green)
                            .hueRotation(.degrees(hoverTintDegrees))
                    }
                }
                .fontWeight(.medium)
                .fixedSize()
                .opacity(hover.visible ? 1 : 0)
                .scaleEffect(hover.visible ? 1 : 0.86)
                .animation(hoverMotion, value: hover.visible)
                .position(x: labelX, y: geometry.size.height / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(!hover.visible)
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        #else
        periodPicker(selectedPeriod)
            .frame(height: 32)
            .padding(.horizontal)
        #endif
    }

    private func periodPicker(_ selectedPeriod: Binding<String>) -> some View {
        let periods = ["1H", "3H", "6H", "12H", "1D", "2D", "1W"]
        return Picker("", selection: selectedPeriod) {
            ForEach(periods, id: \.self) { period in
                Text(period).tag(period)
                    .fontWeight(.bold)
            }
        }
        .pickerStyle(.segmented)
    }

    #if os(macOS)
    /// System green sits 58.4° from system cyan. Rotating the drawn plot tints it without rebuilding the line.
    private let hoverTintDegrees = 58.4
    #endif

    private var chartMotion: Animation? {
        reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.22)
    }

    #if os(macOS)
    private var hoverMotion: Animation? {
        reduceMotion ? nil : chartHoverSpring
    }
    #endif

    private func statisticsView(min: Double, max: Double, average: Double, unit: String, revision: Int) -> some View {
        HStack {
            VStack {
                statisticRow("High", raw: max, unit: unit)
                statisticRow("Low", raw: min, unit: unit)
                statisticRow("Avg.", raw: average, unit: unit)
            }
        }
        .animation(chartMotion, value: revision)
    }

    private func statisticRow(_ title: String, raw: Double, unit: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(statisticText(raw, unit: unit))
                .fontWeight(.medium)
                .contentTransition(.numericText(value: shownStatistic(raw, unit: unit)))
        }
        .frame(width: 200)
    }

    private func loadItem() async {
        defer { if !Task.isCancelled { isLoading = false } }

        guard let cachedItem = await ItemCache.shared.getItemById(itemId) else {
            guard !Task.isCancelled else { return }
            item = nil
            textValue = nil
            plotted = PlottedSeries.empty(revision: plotted.revision + 1)
            return
        }
        guard !Task.isCancelled else { return }

        let graphs = cachedItem.valueType == "0" || cachedItem.valueType == "3"
        item = cachedItem
        if graphs, let valueType = Int(cachedItem.valueType) {
            let bounds = chartTimeWindow(for: selectedPeriod)
            let rows = await HistorySeriesStore.shared.catchingUp(
                itemId: cachedItem.itemId,
                valueType: valueType,
                from: bounds.start.timeIntervalSince1970,
                to: bounds.end.timeIntervalSince1970
            )
            if let rows {
                guard !Task.isCancelled else { return }
                showGraph(rows, unit: cachedItem.units)
            }
        }
        let fetched = await HistoryFetcher().getHistories(
            itemId: cachedItem.itemId,
            selectedPeriod: graphs ? selectedPeriod : "1H",
            valueType: cachedItem.valueType
        )
        guard !Task.isCancelled else { return }

        if graphs {
            showGraph(fetched, unit: cachedItem.units)
        } else if let mostRecent = fetched.max(by: { $0.key < $1.key }) {
            textValue = mostRecent.value
        } else {
            textValue = nil
        }
    }

    private func showGraph(_ fetched: [Date: String], unit: String) {
        let series = PlottedSeries.adopt(
            fetched: fetched,
            unit: unit,
            period: selectedPeriod,
            revision: plotted.revision + 1
        )
        plotted = series
        textValue = nil
        #if os(macOS)
        hover.adopt(series.samples, unit: series.unit)
        #endif
    }
}

/// The fetched series. Equality is the revision, so a hover tint does not rebuild the plot.
private struct SeriesChart: View, Equatable {
    let revision: Int
    let plotted: PlottedSeries
    #if os(macOS)
    let hover: GraphHover
    #endif

    nonisolated static func == (lhs: SeriesChart, rhs: SeriesChart) -> Bool {
        lhs.revision == rhs.revision
    }

    var body: some View {
        let seriesColor = Color.green
        let gradient = LinearGradient(colors: [seriesColor, .clear], startPoint: .top, endPoint: .bottom)
        Chart {
            if !plotted.samples.isEmpty {
                AreaPlot(
                    plotted.samples,
                    x: .value("Date", \.date),
                    yStart: .value("Baseline", \.baseline),
                    yEnd: .value("Value", \.display)
                )
                .foregroundStyle(gradient)

                LinePlot(
                    plotted.samples,
                    x: .value("Date", \.date),
                    y: .value("Value", \.display)
                )
                .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .butt, lineJoin: .round))
                .foregroundStyle(seriesColor)
            }

            if plotted.samples.count == 1, let sample = plotted.samples.first {
                PointMark(
                    x: .value("Date", sample.date),
                    y: .value("Value", sample.display)
                )
                .foregroundStyle(seriesColor)
                .symbolSize(36)
            }

            if plotted.samples.isEmpty, let window = plotted.window {
                PointMark(x: .value("Date", window.lowerBound), y: .value("Value", 0))
                    .opacity(0)
                PointMark(x: .value("Date", window.upperBound), y: .value("Value", 0))
                    .opacity(0)
            }
        }
        .chartPlotStyle { plot in
            plot
                .frame(height: 200)
                .clipped()
        }
        .chartYAxis {
            if plotted.emptyY != nil, plotted.unit != "%" {
                AxisMarks(values: [0.0]) { _ in
                    AxisGridLine()
                    AxisValueLabel("0")
                }
            } else {
                switch plotted.unit {
                case "%":
                    AxisMarks(format: Decimal.FormatStyle.Percent.percent.scale(1))
                default:
                    AxisMarks(format: Decimal.FormatStyle())
                }
            }
        }
        .chartYScale(domain: plotted.yDomain)
        .overlay {
            if plotted.emptyY != nil {
                Text("No samples in this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        #if os(macOS)
        .chartOverlay { proxy in
            HoverLayer(proxy: proxy, hover: hover)
        }
        #endif
        .modifier(PeriodTimeline(domain: plotted.window, emptyYDomain: plotted.emptyY))
    }
}

#if os(macOS)
private let chartHoverSpring = Animation.spring(duration: 0.35, bounce: 0.22)

/// Rule, dot, and value. Reads the hover model, so the series marks stay as they were.
private struct HoverMarks: View {
    let proxy: ChartProxy
    var hover: GraphHover
    let frame: CGRect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hoverMotion: Animation? {
        reduceMotion ? nil : chartHoverSpring
    }

    var body: some View {
        let shown = hover.visible
        let ruleX = hover.pointerX
        Rectangle()
            .fill(.green)
            .frame(width: 1, height: frame.height)
            .opacity(shown ? 1 : 0)
            .animation(hoverMotion, value: shown)
            .position(x: ruleX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

        if let date = hover.sampleDate,
           let displayY = hover.displayY,
           let pointX = proxy.position(forX: date),
           let pointY = proxy.position(forY: displayY) {
            Circle()
                .fill(.green)
                .frame(width: 10, height: 10)
                .opacity(shown ? 1 : 0)
                .animation(hoverMotion, value: shown)
                .position(x: pointX, y: pointY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Plot-sized hit target. It records the pointer and does not read the series.
private struct HoverTarget: View {
    let proxy: ChartProxy
    var hover: GraphHover
    let frame: CGRect

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let chartX = frame.minX + location.x
                    hover.arm(chartX: chartX, date: proxy.value(atX: chartX, as: Date.self))
                case .ended:
                    hover.end()
                }
            }
    }
}

private struct HoverLayer: View {
    let proxy: ChartProxy
    var hover: GraphHover

    var body: some View {
        GeometryReader { geometry in
            if let plotFrame = proxy.plotFrame {
                let frame = geometry[plotFrame]
                ZStack {
                    HoverMarks(proxy: proxy, hover: hover, frame: frame)
                    HoverTarget(proxy: proxy, hover: hover, frame: frame)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}

/// Pointer position is applied on the event. The nearest sample is a binary search, and the line is left as drawn.
@MainActor
@Observable
private final class GraphHover {
    var visible = false
    var pointerX: CGFloat = 0
    var sampleDate: Date?
    var displayY: Double?
    var valueLabel = ""

    @ObservationIgnored private var samples: [PlotSample] = []
    @ObservationIgnored private var unit = ""

    func adopt(_ samples: [PlotSample], unit: String) {
        self.samples = samples
        self.unit = unit
        end()
    }

    func arm(chartX: CGFloat, date: Date?) {
        pointerX = chartX
        guard let date, let sample = nearest(to: date) else {
            end()
            return
        }
        guard !visible || sampleDate != sample.date else { return }
        sampleDate = sample.date
        displayY = sample.display
        valueLabel = hoverText(sample.display, unit: unit)
        visible = true
    }

    func end() {
        visible = false
    }

    private func nearest(to date: Date) -> PlotSample? {
        guard !samples.isEmpty else { return nil }
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if samples[mid].date < date {
                lower = mid + 1
            } else {
                upper = mid
            }
        }
        if lower == 0 { return samples[0] }
        if lower == samples.count { return samples[samples.count - 1] }
        let later = samples[lower]
        let earlier = samples[lower - 1]
        let laterGap = later.date.timeIntervalSince(date)
        let earlierGap = date.timeIntervalSince(earlier.date)
        return earlierGap <= laterGap ? earlier : later
    }
}
#endif

private struct PlotSample: Identifiable {
    let date: Date
    let display: Double
    var baseline: Double
    var id: Date { date }
}

/// Samples sorted once, when a fetch is adopted. The chart draws every one of them.
private final class PlottedSeries {
    let samples: [PlotSample]
    let unit: String
    let rawMin: Double?
    let rawMax: Double?
    let rawAverage: Double?
    let window: ClosedRange<Date>?
    let emptyY: ClosedRange<Double>?
    let yDomain: ClosedRange<Double>
    let revision: Int

    init(
        samples: [PlotSample],
        unit: String,
        rawMin: Double?,
        rawMax: Double?,
        rawAverage: Double?,
        window: ClosedRange<Date>?,
        emptyY: ClosedRange<Double>?,
        yDomain: ClosedRange<Double>,
        revision: Int
    ) {
        self.samples = samples
        self.unit = unit
        self.rawMin = rawMin
        self.rawMax = rawMax
        self.rawAverage = rawAverage
        self.window = window
        self.emptyY = emptyY
        self.yDomain = yDomain
        self.revision = revision
    }

    static func empty(revision: Int) -> PlottedSeries {
        PlottedSeries(
            samples: [],
            unit: "",
            rawMin: nil,
            rawMax: nil,
            rawAverage: nil,
            window: nil,
            emptyY: nil,
            yDomain: 0...1,
            revision: revision
        )
    }

    static func adopt(fetched: [Date: String], unit: String, period: String, revision: Int) -> PlottedSeries {
        var samples: [PlotSample] = []
        samples.reserveCapacity(fetched.count)
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        var displayLow = Double.greatestFiniteMagnitude
        var displayHigh = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        for (date, raw) in fetched {
            guard let value = Double(raw) else { continue }
            let shown = displayed(value, unit: unit)
            if value < low { low = value }
            if value > high { high = value }
            if shown < displayLow { displayLow = shown }
            if shown > displayHigh { displayHigh = shown }
            sum += value
            count += 1
            samples.append(PlotSample(date: date, display: shown, baseline: 0))
        }
        samples.sort { $0.date < $1.date }

        let bounds = chartTimeWindow(for: period)
        let window: ClosedRange<Date>? = bounds.start < bounds.end ? bounds.start...bounds.end : nil
        let emptyY: ClosedRange<Double>? = samples.isEmpty && window != nil
            ? (unit == "%" ? 0...100 : 0...1)
            : nil
        let yDomain = valueScale(unit: unit, low: displayLow, high: displayHigh, hasSamples: count > 0)
        let floor = areaFloor(of: yDomain)
        if floor != 0 {
            for index in samples.indices {
                samples[index].baseline = floor
            }
        }
        return PlottedSeries(
            samples: samples,
            unit: unit,
            rawMin: count > 0 ? low : nil,
            rawMax: count > 0 ? high : nil,
            rawAverage: count > 0 ? sum / Double(count) : nil,
            window: window,
            emptyY: emptyY,
            yDomain: yDomain,
            revision: revision
        )
    }
}

/// Pins the time axis to the selected period. An empty series also gets a fixed value scale.
private struct PeriodTimeline: ViewModifier {
    let domain: ClosedRange<Date>?
    let emptyYDomain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain {
            let pinned = content.chartXScale(domain: domain)
            if let emptyYDomain {
                pinned
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4))
                    }
                    .chartYScale(domain: emptyYDomain)
            } else {
                pinned
            }
        } else {
            content
        }
    }
}

private func displayed(_ raw: Double, unit: String) -> Double {
    unit == "bps" ? raw / 1_000_000 : raw
}

/// Percent stays on 0...100. Any other unit keeps the data minimum and leaves 10% of the span above the peak.
private func valueScale(unit: String, low: Double, high: Double, hasSamples: Bool) -> ClosedRange<Double> {
    if unit == "%" { return 0...100 }
    guard hasSamples else { return 0...1 }
    let span = high - low
    let headroom = span > 0 ? span * 0.1 : max(abs(high) * 0.1, 1)
    return low...(high + headroom)
}

/// Zero, when it is on the scale. A tight scale stops at its near edge so the fill stays inside the plot.
private func areaFloor(of domain: ClosedRange<Double>) -> Double {
    if domain.contains(0) { return 0 }
    return domain.lowerBound > 0 ? domain.lowerBound : domain.upperBound
}

private func hoverText(_ display: Double, unit: String) -> String {
    switch unit {
    case "%":
        percentText(display)
    case "bps":
        quantity(display) + " Mbps"
    default:
        quantity(display)
    }
}

private func statisticText(_ raw: Double, unit: String) -> String {
    switch unit {
    case "%":
        percentText(raw)
    case "bps":
        quantity(raw / 1_000_000) + " Mbps"
    case "":
        quantity(raw)
    default:
        quantity(raw) + " " + unit
    }
}

private func shownStatistic(_ raw: Double, unit: String) -> Double {
    unit == "bps" ? raw / 1_000_000 : raw
}

private func percentText(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(2))) + "%"
}

/// Values below one keep enough digits that a few milliseconds do not become zero.
private func quantity(_ value: Double) -> String {
    let magnitude = abs(value)
    if magnitude == 0 { return "0" }
    if magnitude >= 1 {
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
    if magnitude >= 0.001 {
        return value.formatted(.number.precision(.fractionLength(0...4)))
    }
    return value.formatted(.number.precision(.significantDigits(1...3)))
}
