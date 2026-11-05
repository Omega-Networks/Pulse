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

                if isLoading {
                    loadingView
                } else {
                    #if os(macOS)
                    SeriesChart(revision: plotted.revision, lit: hover.visible, plotted: plotted, hover: hover)
                        .equatable()
                    #else
                    SeriesChart(revision: plotted.revision, lit: false, plotted: plotted)
                        .equatable()
                    #endif

                    if let low = plotted.rawMin, let high = plotted.rawMax, let average = plotted.rawAverage {
                        statisticsView(min: low, max: high, average: average, unit: plotted.unit)
                    }
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
        .task(id: "\(itemId)|\(selectedPeriod)") {
            #if os(macOS)
            hover.end()
            #endif
            isLoading = true
            textValue = nil
            plotted = PlottedSeries.empty(revision: plotted.revision + 1)
            await loadItem()
        }
    }

    private var loadingView: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: 200)
    }

    private func periodPickerView(selectedPeriod: Binding<String>) -> some View {
        HStack(alignment: .center) {
            #if os(macOS)
            if hover.visible, let sampleDate = hover.sampleDate {
                Spacer()
                Text(sampleDate, format: .dateTime)
                    .fontWeight(.medium)
                Spacer()
            } else {
                periodPicker(selectedPeriod)
            }
            #else
            periodPicker(selectedPeriod)
            #endif
        }
        .frame(height: 32)
        .padding(.horizontal)
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

    private func statisticsView(min: Double, max: Double, average: Double, unit: String) -> some View {
        HStack {
            VStack {
                HStack {
                    Text("High")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(statisticText(max, unit: unit))
                        .fontWeight(.medium)
                }
                .frame(width: 200)

                HStack {
                    Text("Low")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(statisticText(min, unit: unit))
                        .fontWeight(.medium)
                }
                .frame(width: 200)

                HStack {
                    Text("Avg.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(statisticText(average, unit: unit))
                        .fontWeight(.medium)
                }
                .frame(width: 200)
            }
        }
    }

    private func loadItem() async {
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }

        guard let cachedItem = await ItemCache.shared.getItemById(itemId) else { return }
        guard !Task.isCancelled else { return }
        item = cachedItem

        let fetched = await HistoryFetcher().getHistories(
            itemId: cachedItem.itemId,
            selectedPeriod: canShowGraph ? selectedPeriod : "1H",
            valueType: cachedItem.valueType
        )
        guard !Task.isCancelled else { return }

        if canShowGraph {
            let series = PlottedSeries.adopt(
                fetched: fetched,
                unit: cachedItem.units,
                period: selectedPeriod,
                revision: plotted.revision + 1
            )
            plotted = series
            #if os(macOS)
            hover.adopt(series.samples, unit: series.unit)
            #endif
        } else if let mostRecent = fetched.max(by: { $0.key < $1.key }) {
            textValue = mostRecent.value
        }
    }
}

/// The fetched series. Equality is the revision and whether the line is lit, so the pointer does not rebuild the marks.
private struct SeriesChart: View, Equatable {
    let revision: Int
    let lit: Bool
    let plotted: PlottedSeries
    #if os(macOS)
    let hover: GraphHover
    #endif

    nonisolated static func == (lhs: SeriesChart, rhs: SeriesChart) -> Bool {
        lhs.revision == rhs.revision && lhs.lit == rhs.lit
    }

    var body: some View {
        let seriesColor: Color = lit ? .cyan : .green
        let gradient = LinearGradient(colors: [seriesColor, .clear], startPoint: .top, endPoint: .bottom)
        Chart {
            ForEach(plotted.samples) { sample in
                LineMark(
                    x: .value("Date", sample.date),
                    y: .value("Value", sample.display)
                )
                .foregroundStyle(seriesColor)

                AreaMark(
                    x: .value("Date", sample.date),
                    y: .value("Value", sample.display)
                )
                .foregroundStyle(gradient)
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
                .overlay {
                    Rectangle()
                        .foregroundStyle(.gray.opacity(0.5))
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
        .chartYScale(domain: .automatic(dataType: Double.self) { domain in
            if plotted.unit == "%" {
                domain = [0, 100]
                return
            }
            guard let upper = domain.max(), let lower = domain.min() else { return }
            let span = upper - lower
            let headroom = span > 0 ? span * 0.1 : max(abs(upper) * 0.1, 1)
            domain = [lower, upper + headroom]
        })
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
/// Rule, dot, and value. Reads the hover model, so the series marks stay as they were.
private struct HoverMarks: View {
    let proxy: ChartProxy
    var hover: GraphHover
    let frame: CGRect

    var body: some View {
        if hover.visible,
           let date = hover.sampleDate,
           let displayY = hover.displayY,
           let pointX = proxy.position(forX: date) {
            let ruleX = hover.pointerX
            let labelX = min(max(ruleX, frame.minX + 36), frame.maxX - 36)
            Rectangle()
                .fill(.cyan)
                .frame(width: 1, height: frame.height)
                .position(x: ruleX, y: frame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            if let pointY = proxy.position(forY: displayY) {
                Circle()
                    .fill(.cyan)
                    .frame(width: 10, height: 10)
                    .position(x: pointX, y: pointY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Text(hover.valueLabel)
                .fontWeight(.medium)
                .foregroundStyle(.cyan)
                .fixedSize()
                .allowsHitTesting(false)
                .position(x: labelX, y: frame.minY + 16)
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
            visible = false
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
        sampleDate = nil
        displayY = nil
        valueLabel = ""
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
    let revision: Int

    init(
        samples: [PlotSample],
        unit: String,
        rawMin: Double?,
        rawMax: Double?,
        rawAverage: Double?,
        window: ClosedRange<Date>?,
        emptyY: ClosedRange<Double>?,
        revision: Int
    ) {
        self.samples = samples
        self.unit = unit
        self.rawMin = rawMin
        self.rawMax = rawMax
        self.rawAverage = rawAverage
        self.window = window
        self.emptyY = emptyY
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
            revision: revision
        )
    }

    static func adopt(fetched: [Date: String], unit: String, period: String, revision: Int) -> PlottedSeries {
        var samples: [PlotSample] = []
        samples.reserveCapacity(fetched.count)
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        for (date, raw) in fetched {
            guard let value = Double(raw) else { continue }
            if value < low { low = value }
            if value > high { high = value }
            sum += value
            count += 1
            samples.append(PlotSample(date: date, display: displayed(value, unit: unit)))
        }
        samples.sort { $0.date < $1.date }

        let bounds = chartTimeWindow(for: period)
        let window: ClosedRange<Date>? = bounds.start < bounds.end ? bounds.start...bounds.end : nil
        let emptyY: ClosedRange<Double>? = samples.isEmpty && window != nil
            ? (unit == "%" ? 0...100 : 0...1)
            : nil
        return PlottedSeries(
            samples: samples,
            unit: unit,
            rawMin: count > 0 ? low : nil,
            rawMax: count > 0 ? high : nil,
            rawAverage: count > 0 ? sum / Double(count) : nil,
            window: window,
            emptyY: emptyY,
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

private func hoverText(_ display: Double, unit: String) -> String {
    switch unit {
    case "%":
        String(format: "%.2f%%", display)
    case "bps":
        String(format: "%.2f Mbps", display)
    default:
        String(format: "%.2f", display)
    }
}

private func statisticText(_ raw: Double, unit: String) -> String {
    switch unit {
    case "%":
        String(format: "%.2f%%", raw)
    case "bps":
        String(format: "%.2f Mbps", raw / 1_000_000)
    default:
        String(format: "%.2f \(unit)", raw)
    }
}
