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

    /// Shared x-axis for both forecast charts, keyed by the same `granularity` that already
    /// drives their bucketing — previously each chart picked its own stride *and* format, so
    /// they visibly disagreed. At month granularity (90d/365d) ticks land on the 1st of each
    /// month; at day/week granularity (30d) they stay daily so the default free view keeps a
    /// readable axis instead of collapsing to a single tick.
    @AxisContentBuilder
    static func forecastAxis(granularity: ForecastEngine.Granularity) -> some AxisContent {
        switch granularity {
        case .day:
            AxisMarks(values: .stride(by: .day, count: 7)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel(date.formatted(.dateTime.day().month(.abbreviated)))
                }
            }
        case .week:
            AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel(date.formatted(.dateTime.day().month(.abbreviated)))
                }
            }
        case .month:
            AxisMarks(values: .stride(by: .month, count: 1)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel(date.formatted(.dateTime.month(.abbreviated)))
                }
            }
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
    /// Drives the shared x-axis so this chart's ticks always match `ForecastBucketChart`'s.
    let granularity: ForecastEngine.Granularity
    /// 0→1 entrance driver; scales the curve up from the baseline.
    let progress: Double

    @State private var scrubDate: Date?

    /// Last point at or before the scrub position — the running total "so far" at that date.
    private var scrubbed: ForecastEngine.CumulativePoint? {
        guard let scrubDate else { return nil }
        return points.last { $0.date <= scrubDate } ?? points.first
    }

    var body: some View {
        GeometryReader { geo in
            Chart {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Spend", point.runningTotal)
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
                        y: .value("Spend", point.runningTotal)
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
                        y: .value("Spend", scrubbed.runningTotal)
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
            .chartXAxis { InsightsChartFormat.forecastAxis(granularity: granularity) }
            // "Draws" the line left-to-right on entrance instead of inflating it vertically
            // from zero — a wipe reveal reads as the line being traced, matching the growing
            // bar chart beneath it instead of looking like an unrelated scale-up.
            .mask(alignment: .leading) {
                Rectangle().frame(width: max(0, geo.size.width * progress))
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

/// Direction of a horizontal swipe across the donut, used to cycle the cost-period picker
/// without requiring the user to reach up to the segmented control.
enum DonutSwipeDirection {
    case forward, backward
}

/// Category spend ring. Sweeps in from zero on the shared `InsightsEntrance` driver; tapping
/// a segment (or its legend swatch) selects it and dims the rest — and tapping the same one
/// again clears the selection.
///
/// Tap resolution is done manually (angle math against the tap location) rather than via
/// `chartAngleSelection`: the framework's built-in selection repeatedly failed to register
/// taps on some segments (had to be tapped several times, and a few never registered at
/// all) — resolving the angle ourselves from the raw tap point is simpler and reliable.
struct CategoryDonutChart: View {
    let slices: [CategorySpendSlice]
    let currencyCode: String
    /// 0→1 entrance driver; scales the sweep up from empty.
    let progress: Double
    @Binding var selectedCategory: SubscriptionCategory?
    /// Called on a horizontal swipe across the ring so the caller can cycle the cost period.
    var onSwipe: ((DonutSwipeDirection) -> Void)?

    private var total: Double { slices.reduce(0) { $0 + $1.amount } }

    private var centerAmount: Double {
        guard let selectedCategory else { return total }
        return slices.first { $0.category == selectedCategory }?.amount ?? 0
    }

    private var centerTitle: String {
        selectedCategory?.displayName ?? "Total"
    }

    /// Angle (degrees, 0 = 12 o'clock, clockwise) of a point relative to `rect`'s center —
    /// `nil` if the point falls outside the ring's radial band (with a little tap slop).
    private func angleDegrees(at point: CGPoint, in rect: CGRect) -> Double? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = (dx * dx + dy * dy).squareRoot()
        let outer = min(rect.width, rect.height) / 2
        // Matches the mark's actual innerRadius(.ratio(0.62))/outerRadius(.ratio(0.92)) band,
        // with a little slop either side for a finger's imprecision — but not so much that a
        // tap near the center label (which sits inside the hole) misfires onto a slice.
        guard radius >= outer * 0.56, radius <= outer * 1.0 else { return nil }
        var degrees = atan2(dy, dx) * 180 / .pi + 90
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// Maps an angle (0–360, 0 = 12 o'clock, clockwise — matching `SectorMark`'s default
    /// start point and direction) to whichever slice's cumulative share contains it.
    private func category(atDegrees degrees: Double) -> SubscriptionCategory? {
        guard total > 0 else { return nil }
        var running = 0.0
        for slice in slices {
            running += slice.amount
            if degrees <= running / total * 360 { return slice.category }
        }
        return slices.last?.category
    }

    private func toggleSelection(for category: SubscriptionCategory) {
        withAnimation(.smooth(duration: 0.25)) {
            selectedCategory = selectedCategory == category ? nil : category
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Keep the plot separate from the legend. Swift Charts otherwise gives the
            // legend part of this frame, so both the ring and its background label move
            // and shrink as the number of categories changes.
            ZStack {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Spend", slice.amount * progress),
                        innerRadius: .ratio(0.62),
                        outerRadius: .ratio(0.92),
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
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            // Plain tap gesture, not a zero-distance DragGesture — this is the
                            // form that composes cleanly with the enclosing ScrollView's own
                            // pan recognizer instead of fighting it for every touch.
                            .onTapGesture { location in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let rect = geo[plotFrame]
                                guard let degrees = angleDegrees(at: location, in: rect),
                                      let tapped = category(atDegrees: degrees) else { return }
                                toggleSelection(for: tapped)
                            }
                            // Separate, higher-threshold drag purely for the swipe-to-cycle
                            // gesture, so a vertical scroll started on the ring isn't
                            // intercepted before the ScrollView's own recognizer claims it.
                            .gesture(
                                DragGesture(minimumDistance: 24)
                                    .onEnded { value in
                                        let dx = value.translation.width
                                        let dy = value.translation.height
                                        guard abs(dx) > 32, abs(dx) > abs(dy) * 1.5 else { return }
                                        onSwipe?(dx < 0 ? .forward : .backward)
                                    }
                            )
                    }
                }

                VStack(spacing: 2) {
                    Text(centerTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.75)
                    AnimatedCurrencyText(value: centerAmount, currencyCode: currencyCode)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: 104, height: 62)
                .allowsHitTesting(false)
            }
            .frame(height: 220)

            categoryLegend
        }
    }

    private var categoryLegend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 126), spacing: 10, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(slices) { slice in
                Button {
                    toggleSelection(for: slice.category)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(slice.category.chartColor)
                            .frame(width: 9, height: 9)
                        Text(slice.category.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(selectedCategory == nil || selectedCategory == slice.category ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter by \(slice.category.displayName)")
                .accessibilityAddTraits(selectedCategory == slice.category ? .isSelected : [])
            }
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

    var body: some View {
        GeometryReader { geo in
            Chart {
                ForEach(buckets) { bucket in
                    BarMark(
                        x: .value("Date", bucket.start, unit: granularity.component),
                        y: .value("Cost", bucket.total)
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
            .chartXAxis { InsightsChartFormat.forecastAxis(granularity: granularity) }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    if let amount = value.as(Double.self) {
                        AxisValueLabel(InsightsChartFormat.axisAmount(amount, code: currencyCode))
                    }
                }
            }
            // Same left-to-right wipe reveal as the cumulative chart above it, so both
            // charts animate in together instead of the bars looking static beneath a
            // moving line.
            .mask(alignment: .leading) {
                Rectangle().frame(width: max(0, geo.size.width * progress))
            }
        }
        .frame(height: 120)
    }
}
