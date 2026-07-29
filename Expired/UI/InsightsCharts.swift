import SwiftUI
import Charts

// MARK: - Entrance animation

/// Staggered-entrance driver for the Insights tab.
///
/// Swift Charts has no built-in entrance animation, so the standard technique is a single
/// 0→1 progress value multiplied into every mark's `y` value and into each element's
/// opacity/offset. Two things this has to get right that a naive `.onAppear` does not:
///
/// 1. **Replay on every visit.** Inside a `TabView` the Insights view stays alive after its
///    first appearance, so a `@State` progress set once in `.onAppear` animates exactly one
///    time and every later tab switch shows the charts already at rest.
/// 2. **Don't stutter on a tab bounce.** Re-running the whole entrance because the user
///    tapped away and straight back looks broken, so a replay only happens after
///    `replayThreshold` seconds away.
@MainActor
@Observable
final class InsightsEntrance {
    /// 0 = nothing drawn yet, 1 = fully settled. Read by every animated element.
    private(set) var progress: Double = 0

    private var leftAt: Date?
    private let replayThreshold: TimeInterval = 2

    /// Call from `.onAppear`. `reduceMotion` snaps straight to the settled state.
    func enter(reduceMotion: Bool) {
        guard !reduceMotion else { progress = 1; return }
        let awayLongEnough = leftAt.map { Date().timeIntervalSince($0) > replayThreshold } ?? true
        guard awayLongEnough else { progress = 1; return }
        progress = 0
        // Linear driver: the per-element easing lives in `staggered(_:index:)`, so a
        // curved driver here would squash the later elements' stagger together.
        withAnimation(.linear(duration: 0.85)) { progress = 1 }
    }

    /// Call from `.onDisappear`.
    func leave() { leftAt = Date() }

    /// Per-element progress for a staggered sequence: element `index` starts at
    /// `index * stride` through the driver and eases over `window`.
    /// `index * stride` must stay ≤ 0.5 so the last element still finishes inside the
    /// driver's 0→1 run — callers with unbounded lists clamp their index.
    func staggered(index: Int, stride: Double = 0.05, window: Double = 0.5) -> Double {
        let start = Double(index) * stride
        guard progress > start else { return 0 }
        let linear = min(1, (progress - start) / window)
        return 1 - pow(1 - linear, 3)   // easeOutCubic
    }
}

/// Standard fade + rise + settle used by every staggered element on the Insights tab.
extension View {
    func insightsEntrance(_ progress: Double, rise: CGFloat = 14) -> some View {
        self
            .opacity(progress)
            .offset(y: (1 - progress) * rise)
            .scaleEffect(0.95 + 0.05 * progress, anchor: .center)
    }
}

// MARK: - Animated numbers

/// `Text` is not animatable, so a currency figure that should count up (or tween between
/// two totals when the horizon/period changes) needs a `View` that conforms to `Animatable`
/// — SwiftUI then re-invokes `body` once per frame with an interpolated `value`.
struct AnimatedCurrencyText: View, Animatable {
    var value: Double
    var currencyCode: String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(CurrencyInfo.format(value, code: currencyCode))
    }
}

/// Whole-number counterpart of `AnimatedCurrencyText`, for the stat tiles' counts.
struct AnimatedCountText: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
    }
}

// MARK: - Shared chart helpers

enum InsightsChartFormat {
    /// Compact axis label — no decimals, `k` above 1000. Keeps a leading axis readable
    /// at the 120–170pt chart heights used here.
    static func axisAmount(_ value: Double, code: String) -> String {
        let symbol = CurrencyInfo.symbol(for: code)
        if value >= 1000 {
            return "\(symbol)\(String(format: "%.0f", value / 1000))k"
        }
        return "\(symbol)\(String(format: "%.0f", value))"
    }

    static func scrubLabel(_ date: Date, granularity: ForecastEngine.Granularity) -> String {
        switch granularity {
        case .day:   return date.formatted(.dateTime.day().month(.abbreviated))
        case .week:  return "Week of " + date.formatted(.dateTime.day().month(.abbreviated))
        case .month: return date.formatted(.dateTime.month(.wide).year())
        }
    }
}

/// Lollipop callout shown above a scrubbed mark.
private struct ScrubCallout: View {
    let title: String
    let amount: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(amount)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .fixedSize()
    }
}

// MARK: - Cumulative spend curve

/// Running projected spend across the selected horizon. Its right-hand endpoint is exactly
/// the headline forecast figure, which is the point: changing 30/90/365 visibly redraws the
/// curve to land on the new number instead of leaving a static chart next to a changed total.
struct ForecastCumulativeChart: View {
    let points: [ForecastEngine.CumulativePoint]
    let currencyCode: String
    /// 0→1 entrance driver; scales the curve up from the baseline.
    let progress: Double

    @State private var scrubDate: Date?

    /// Last point at or before the scrub position — the running total "so far" at that date.
    private var scrubbed: ForecastEngine.CumulativePoint? {
        guard let scrubDate else { return nil }
        return points.last { $0.date <= scrubDate } ?? points.first
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("Spend", point.runningTotal * progress)
                )
                .interpolationMethod(.stepEnd)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue.opacity(0.35), .blue.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Spend", point.runningTotal * progress)
                )
                .interpolationMethod(.stepEnd)
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            }

            if let scrubbed {
                RuleMark(x: .value("Date", scrubbed.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ScrubCallout(
                            title: scrubbed.date.formatted(.dateTime.day().month(.abbreviated)),
                            amount: CurrencyInfo.format(scrubbed.runningTotal, code: currencyCode)
                        )
                    }

                PointMark(
                    x: .value("Date", scrubbed.date),
                    y: .value("Spend", scrubbed.runningTotal * progress)
                )
                .foregroundStyle(.blue)
                .symbolSize(60)
            }
        }
        .chartXSelection(value: $scrubDate)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                if let amount = value.as(Double.self) {
                    AxisValueLabel(InsightsChartFormat.axisAmount(amount, code: currencyCode))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(date.formatted(.dateTime.day().month(.abbreviated)))
                }
            }
        }
        .frame(height: 150)
    }
}

// MARK: - Category spend donut

/// One category's total spend for the currently selected cost period. Built by the caller
/// from `periodCost(for:)` grouped by `item.category ?? .other`.
struct CategorySpendSlice: Identifiable {
    var id: String { category.rawValue }
    let category: SubscriptionCategory
    let amount: Double
}

/// Category spend ring. Sweeps in from zero on the shared `InsightsEntrance` driver; tapping
/// a segment (or its legend swatch) selects it — pops out slightly and dims the rest — and
/// tapping the same one again clears the selection. `chartAngleSelection` is the standard
/// Swift Charts technique for pie/donut tap targets, so selection is angle-based: a tap
/// resolves to whichever slice's cumulative amount range contains the tapped angle value.
struct CategoryDonutChart: View {
    let slices: [CategorySpendSlice]
    let currencyCode: String
    /// 0→1 entrance driver; scales the sweep up from empty.
    let progress: Double
    @Binding var selectedCategory: SubscriptionCategory?

    @State private var angleSelection: Double?

    private var total: Double { slices.reduce(0) { $0 + $1.amount } }

    private var centerAmount: Double {
        guard let selectedCategory else { return total }
        return slices.first { $0.category == selectedCategory }?.amount ?? 0
    }

    private var centerTitle: String {
        selectedCategory?.displayName ?? "Total"
    }

    /// Maps a tapped angle (in the same value domain as the mark's `angle`, i.e. cumulative
    /// spend) to the slice whose cumulative range contains it.
    private func category(atCumulative value: Double) -> SubscriptionCategory? {
        var running = 0.0
        for slice in slices {
            running += slice.amount * progress
            if value <= running { return slice.category }
        }
        return slices.last?.category
    }

    var body: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Spend", slice.amount * progress),
                innerRadius: .ratio(0.62),
                outerRadius: .ratio(selectedCategory == nil || selectedCategory == slice.category ? 0.98 : 0.88),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Category", slice.category.displayName))
            .opacity(selectedCategory == nil || selectedCategory == slice.category ? 1 : 0.35)
            .cornerRadius(4)
        }
        .chartForegroundStyleScale(
            domain: slices.map(\.category.displayName),
            range: slices.map(\.category.chartColor)
        )
        .chartLegend(position: .bottom, spacing: 8)
        .chartAngleSelection(value: $angleSelection)
        .chartBackground { _ in
            VStack(spacing: 2) {
                Text(centerTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                AnimatedCurrencyText(value: centerAmount, currencyCode: currencyCode)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 220)
        .onChange(of: angleSelection) { _, newValue in
            guard let newValue, let tapped = category(atCumulative: newValue) else { return }
            selectedCategory = (selectedCategory == tapped) ? nil : tapped
            angleSelection = nil
        }
    }
}

// MARK: - Horizon bucket bar chart

/// "When do the hits land" companion to the cumulative curve. Granularity is derived from
/// the horizon (daily / weekly / monthly), so this redraws whenever 30/90/365 changes.
struct ForecastBucketChart: View {
    let buckets: [ForecastEngine.Bucket]
    let granularity: ForecastEngine.Granularity
    let currencyCode: String
    let progress: Double

    @State private var scrubDate: Date?

    private var scrubbed: ForecastEngine.Bucket? {
        guard let scrubDate else { return nil }
        return buckets.last { $0.start <= scrubDate } ?? buckets.first
    }

    private var axisStride: (component: Calendar.Component, count: Int) {
        switch granularity {
        case .day:   return (.day, 7)
        case .week:  return (.weekOfYear, 2)
        case .month: return (.month, 2)
        }
    }

    var body: some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(
                    x: .value("Date", bucket.start, unit: granularity.component),
                    y: .value("Cost", bucket.total * progress)
                )
                .foregroundStyle(
                    scrubbed?.id == bucket.id
                        ? AnyShapeStyle(Color.cyan.gradient)
                        : AnyShapeStyle(Color.blue.gradient)
                )
                .cornerRadius(3)
            }

            if let scrubbed, scrubbed.total > 0 {
                RuleMark(x: .value("Date", scrubbed.start, unit: granularity.component))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ScrubCallout(
                            title: InsightsChartFormat.scrubLabel(scrubbed.start, granularity: granularity),
                            amount: CurrencyInfo.format(scrubbed.total, code: currencyCode)
                        )
                    }
            }
        }
        .chartXSelection(value: $scrubDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: axisStride.component, count: axisStride.count)) { value in
                if let date = value.as(Date.self) {
                    switch granularity {
                    case .day, .week:
                        AxisValueLabel(date.formatted(.dateTime.day().month(.abbreviated)))
                    case .month:
                        AxisValueLabel(date.formatted(.dateTime.month(.abbreviated)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                if let amount = value.as(Double.self) {
                    AxisValueLabel(InsightsChartFormat.axisAmount(amount, code: currencyCode))
                }
            }
        }
        .frame(height: 120)
    }
}
