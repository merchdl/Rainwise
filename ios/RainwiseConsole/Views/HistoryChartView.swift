import Charts
import SwiftUI

private struct ChartPoint: Identifiable {
    var date: Date
    var value: Double
    var id: Date { date }
}

/// Area graph with dashed max/min lines and labels, like the original app.
/// Drag across the graph to read exact values.
struct HistoryChartView: View {
    @Environment(StationStore.self) private var store
    @State private var selectedDate: Date?

    var body: some View {
        let u = store.units
        let metric = store.chartMetric
        let q = metric.quantity
        let series = store.history?.metric == metric.rawValue && store.history?.range == store.chartRange.rawValue
            ? store.history : nil
        let points = (series?.points ?? []).map { ChartPoint(date: $0.date, value: q.convert($0.v, u)) }
        let maxPoint = series?.max.map { ChartPoint(date: $0.date, value: q.convert($0.v, u)) }
        let minPoint = series?.min.map { ChartPoint(date: $0.date, value: q.convert($0.v, u)) }
        let yDomain = Self.yDomain(points: points, extra: [maxPoint, minPoint].compactMap { $0?.value }, q: q, u: u)
        let xDomain = Self.xDomain(series, store.chartRange)
        let selected = selectedDate.flatMap { d in points.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) }

        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date),
                         yStart: .value("Base", yDomain.lowerBound),
                         yEnd: .value(metric.title, p.value))
                    .foregroundStyle(LinearGradient(colors: [ConsoleTheme.led.opacity(0.7), ConsoleTheme.led.opacity(0.12)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.date), y: .value(metric.title, p.value))
                    .foregroundStyle(ConsoleTheme.led)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }

            if let first = points.first, let last = points.last {
                if let mx = maxPoint {
                    RuleMark(xStart: .value("Start", first.date), xEnd: .value("End", last.date), y: .value("Max", mx.value))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text(label(mx, q: q, u: u)).font(.caption).foregroundStyle(.orange)
                        }
                }
                if let mn = minPoint {
                    RuleMark(xStart: .value("Start", first.date), xEnd: .value("End", last.date), y: .value("Min", mn.value))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .bottom, alignment: .center, spacing: 2) {
                            Text(label(mn, q: q, u: u)).font(.caption).foregroundStyle(.green)
                        }
                }
            }

            if let s = selected {
                RuleMark(x: .value("Selected", s.date))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(label(s, q: q, u: u))
                            .font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.8)))
                            .foregroundStyle(.white)
                    }
                PointMark(x: .value("Time", s.date), y: .value(metric.title, s.value))
                    .foregroundStyle(.white)
                    .symbolSize(30)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: xStride.component, count: xStride.count)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6)).foregroundStyle(Color.white.opacity(0.22))
                AxisTick().foregroundStyle(Color.white.opacity(0.5))
                AxisValueLabel(format: xLabelFormat)
                    .foregroundStyle(.white)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.12))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(v.formatted(decimals: max(q.decimals(u) - 1, 0)))\(q == .temperature ? "°" : "")")
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color(white: 0.13))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.1)))
        .overlay {
            if points.isEmpty {
                Text(store.historyError ?? "No history yet — the collector records one point a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private var xStride: (component: Calendar.Component, count: Int) {
        switch store.chartRange {
        case .today: return (.hour, 3)
        case .hours48: return (.hour, 6)
        case .week: return (.day, 1)
        }
    }

    private var xLabelFormat: Date.FormatStyle {
        store.chartRange == .week ? .dateTime.weekday(.abbreviated) : .dateTime.hour()
    }

    private func label(_ p: ChartPoint, q: Quantity, u: UnitSystem) -> String {
        let f = DateFormatter()
        f.dateFormat = store.chartRange == .today ? "h:mma" : "EEE h:mma"
        return "\(p.value.formatted(decimals: q.decimals(u))) \(q.symbol(u)) @ \(f.string(from: p.date))"
    }

    private static func xDomain(_ s: HistorySeries?, _ range: ChartRange) -> ClosedRange<Date> {
        if let s { return s.startDate...s.endDate }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let start = cal.date(byAdding: .day, value: -range.daysBack, to: today)!
        return start...cal.date(byAdding: .day, value: 1, to: today)!
    }

    private static func yDomain(points: [ChartPoint], extra: [Double], q: Quantity, u: UnitSystem) -> ClosedRange<Double> {
        let values = points.map(\.value) + extra
        guard var lo = values.min(), var hi = values.max() else { return 0...1 }
        let span = max(hi - lo, q.minimumSpan(u))
        let mid = (lo + hi) / 2
        lo = min(lo, mid - span / 2)
        hi = max(hi, mid + span / 2)
        let pad = span * 0.15  // room for the max/min labels
        lo -= pad
        hi += pad
        if q.floorsAtZero { lo = max(lo, 0) }
        if q == .humidity { hi = min(hi, 100) }
        return lo...hi
    }
}

/// A row of buttons where one is selected, styled like the original app.
struct SegmentBar<Item: Hashable>: View {
    var items: [Item]
    @Binding var selection: Item
    var itemWidth: CGFloat? = nil
    var title: (Item) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Button { selection = item } label: {
                    Text(title(item))
                        .font(.system(size: 16))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: itemWidth == nil ? .infinity : nil)
                        .frame(width: itemWidth)
                        .foregroundStyle(selection == item ? Color.black : Color.white)
                        .background(selection == item ? Color.white : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.8)).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: itemWidth != nil, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.8), lineWidth: 1))
    }
}

/// Graph plus its range / metric buttons.
struct HistorySection: View {
    @Environment(StationStore.self) private var store
    var compact: Bool

    var body: some View {
        let range = Binding(get: { store.chartRange }, set: { store.chartRange = $0 })
        let metric = Binding(get: { store.chartMetric }, set: { store.chartMetric = $0 })
        VStack(spacing: 10) {
            HistoryChartView()
                .frame(minHeight: 150)
            if compact {
                SegmentBar(items: ChartRange.allCases, selection: range) { $0.title }
                ScrollView(.horizontal, showsIndicators: false) {
                    SegmentBar(items: ChartMetric.allCases, selection: metric, itemWidth: 100) { $0.title }
                        .padding(1)
                }
            } else {
                HStack(spacing: 24) {
                    SegmentBar(items: ChartRange.allCases, selection: range) { $0.title }
                        .frame(width: 330)
                    Spacer(minLength: 0)
                    SegmentBar(items: ChartMetric.allCases, selection: metric) { $0.title }
                        .frame(maxWidth: 820)
                }
            }
        }
    }
}
