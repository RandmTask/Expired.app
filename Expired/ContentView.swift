import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UserNotifications
import RevenueCat
import Charts
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private func calendarWeekStart(for date: Date, calendar: Calendar = .current) -> Date {
    calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
}

private func localizedWeekdayInitials(calendar: Calendar = .current) -> [String] {
    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let startIndex = max(0, calendar.firstWeekday - 1)
    return (0..<7).map { symbols[(startIndex + $0) % symbols.count] }
}

private func leadingWeekdaySlots(for date: Date, calendar: Calendar = .current) -> Int {
    let weekdayIndex = calendar.component(.weekday, from: date) - 1
    let firstWeekdayIndex = calendar.firstWeekday - 1
    return (weekdayIndex - firstWeekdayIndex + 7) % 7
}

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var settingsNavID = UUID()

    var body: some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { newTab in
                Haptics.fire(.selectionChanged)
                if selectedTab == 3 && newTab != 3 {
                    // Leaving Settings → reset nav so returning always shows root
                    settingsNavID = UUID()
                } else if newTab == 3 && selectedTab == 3 {
                    // Re-tapping Settings while already on it → also reset to root
                    settingsNavID = UUID()
                }
                selectedTab = newTab
            }
        )) {
            Tab("Subscriptions", systemImage: "creditcard", value: 0) {
                HomeView()
            }
            Tab("Timeline", systemImage: "calendar", value: 1) {
                TimelineView(isSelected: selectedTab == 1)
            }
            Tab("Insights", systemImage: "chart.bar", value: 2) {
                InsightsView()
            }
            Tab("Settings", systemImage: "gear", value: 3) {
                SettingsView()
                    .id(settingsNavID)
            }
        }
        .environmentObject(CloudKitDebugStore.shared)
        .onReceive(NotificationCenter.default.publisher(for: .expiredShowSettings)) { _ in
            Haptics.fire(.selectionChanged)
            selectedTab = 3
        }
#if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        .expiredOnboardingGate()
        .expiredSplash()
#endif
    }
}

// MARK: - Timeline View (container with view-mode switcher)

struct TimelineView: View {
    @Query(filter: #Predicate<SubscriptionItem> { !$0.isArchived },
           sort: \SubscriptionItem.nextRenewalDate)
    private var allItems: [SubscriptionItem]

    enum ViewMode: String, CaseIterable {
        case timeline   = "Timeline"
        case calendar   = "Calendar"
        case heatmap    = "Heatmap"
        case swimLane   = "Swim Lane"
        case spendSpike = "Spend Spike"
        case strip      = "Two Weeks"

        var icon: String {
            switch self {
            case .timeline:   return "list.bullet.below.rectangle"
            case .calendar:   return "calendar"
            case .heatmap:    return "square.grid.3x3.fill"
            case .swimLane:   return "chart.bar.xaxis"
            case .spendSpike: return "chart.bar.fill"
            case .strip:      return "rectangle.split.2x1"
            }
        }

        /// Timeline + Calendar are free; the richer visualisations are Pro.
        var isPro: Bool {
            switch self {
            case .timeline, .calendar: return false
            default: return true
            }
        }
    }

    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPaywall = false
    // Reuses `InsightsEntrance` as-is (it isn't Insights-specific) so the classic timeline
    // gets the same staggered fade-in + "don't replay if you just glanced away" gating.
    @State private var entrance = InsightsEntrance()
    /// Whether the Timeline tab is the one currently selected in `ContentView`'s `TabView`.
    /// The entrance MUST be driven off this, not `.onAppear`/`.onDisappear` on this view's
    /// content — iOS 26's `Tab` API eagerly creates every tab's content at launch (all of
    /// them, regardless of which is selected), so `.onAppear` fires the moment the app
    /// launches, and the entrance plays out fully off-screen before the user ever taps this
    /// tab. `isSelected` flipping true is the real "user is now looking at this" signal.
    let isSelected: Bool

    @AppStorage("timelineViewMode") private var viewModeRaw: String = ViewMode.timeline.rawValue
    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .timeline }

    /// Falls back to the free Timeline when a Pro mode is selected but the user isn't
    /// premium (e.g. after a lapse) — without discarding their saved preference.
    private var effectiveViewMode: ViewMode {
        (viewMode.isPro && !purchaseManager.isPremium) ? .timeline : viewMode
    }

    @AppStorage("preferredCurrency") private var preferredCurrency = SettingsView.localeCurrencyCode

    private var upcoming: [SubscriptionItem] {
        allItems.filter { $0.daysUntilRenewal >= 0 }
            .sorted { $0.nextRelevantDate < $1.nextRelevantDate }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allItems.isEmpty {
                    ContentUnavailableView(
                        "No Upcoming Events",
                        systemImage: "calendar.badge.clock",
                        description: Text("Add subscriptions to see your timeline.")
                    )
                } else {
                    switch effectiveViewMode {
                    case .timeline:   classicTimelineView
                    case .calendar:   CalendarGridView(items: allItems, currency: preferredCurrency)
                    case .heatmap:    HeatmapView(items: allItems, currency: preferredCurrency)
                    case .swimLane:   SwimLaneView(items: allItems)
                    case .spendSpike: SpendSpikeView(items: allItems, currency: preferredCurrency)
                    case .strip:      MonthStripView(items: allItems, currency: preferredCurrency)
                    }
                }
            }
            .navigationTitle("Timeline")
            .largeNavigationTitle()
            .background(groupedBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            let locked = mode.isPro && !purchaseManager.isPremium
                            Button {
                                if locked {
                                    Haptics.fire(.warning)
                                    showPaywall = true
                                } else {
                                    Haptics.fire(.selectionChanged)
                                    withAnimation(.spring(duration: 0.3)) { viewModeRaw = mode.rawValue }
                                }
                            } label: {
                                viewModeMenuRow(mode: mode, isSelected: viewMode == mode, isLocked: locked)
                            }
                        }
                    } label: {
                        Image(systemName: effectiveViewMode.icon)
                            .font(.system(size: 16, weight: .semibold))
                    }
#if os(macOS)
                    .menuIndicator(.hidden)
#endif
                }
            }
            .expiredPaywallSheet(isPresented: $showPaywall)
        }
    }

    private func viewModeMenuRow(mode: ViewMode, isSelected: Bool, isLocked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .opacity(isSelected ? 1 : 0)
                .frame(width: 16, alignment: .center)
            Image(systemName: isLocked ? "lock.fill" : mode.icon)
                .frame(width: 22, alignment: .center)
            Text(mode.rawValue)
        }
    }

    // MARK: - Classic timeline (original spine list)

    /// Non-overlapping row slots (stride == window) so rows reveal strictly one at a time —
    /// row `i+1` only starts once row `i`'s own window finishes — instead of the cascading
    /// overlap `InsightsEntrance`'s default stride/window ratio produces.
    private static let rowStride = 0.1
    /// Longer than Insights' default 0.85s: at 10 non-overlapping slots, 0.85s would give each
    /// row ~85ms, too fast to read as "one at a time." ~1.4s gives each row ~140ms.
    private static let timelineEntranceDuration: TimeInterval = 1.4

    private var classicTimelineView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, item in
                    // Clamp the index so long lists still finish inside the driver's 0→1 run.
                    TimelineRow(item: item, isFirst: index == 0,
                                progress: entrance.staggered(index: min(index, 9),
                                                              stride: Self.rowStride,
                                                              window: Self.rowStride))
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // No `initial: true` — Timeline isn't the default tab, so `isSelected` always starts
        // `false`; firing on the initial evaluation would call `leave()` before the entrance
        // ever ran, stamping `leftAt` as "just now" and wrongly skipping the real first entrance
        // if the user taps over within the 2s replay-threshold window.
        .onChange(of: isSelected) { _, nowSelected in
            if nowSelected {
                entrance.enter(reduceMotion: reduceMotion, duration: Self.timelineEntranceDuration)
            } else {
                entrance.leave()
            }
        }
    }
}

// MARK: - Classic Timeline Row

struct TimelineRow: View {
    let item: SubscriptionItem
    /// The dot now sits at the *bottom* of each row (see below), so the leading connector
    /// line is only omitted for the first row — there's nothing above it to connect to.
    let isFirst: Bool
    /// 0→1 local entrance progress for this row alone (see `TimelineView.entrance`); rows
    /// reveal sequentially, not overlapping. Defaults to 1 (fully settled) for any caller
    /// that doesn't drive an entrance.
    var progress: Double = 1

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 0) {
                if !isFirst {
                    Rectangle()
                        .fill(dotColor.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        // Grows down from the top, so it visibly draws toward the dot rather
                        // than just fading in at full length.
                        .scaleEffect(x: 1, y: lineProgress, anchor: .top)
                }
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .padding(.bottom, 4)
                    .scaleEffect(dotScale)
            }
            .frame(width: 10)
            SubscriptionRowView(item: item)
        }
        .frame(minHeight: 60)
        .insightsEntrance(progress)
    }

    /// Line draws in over the first 60% of this row's local window...
    private var lineProgress: Double { min(1, progress / 0.6) }
    /// ...and the dot's pop-in bounce takes the remainder, landing once the line reaches it —
    /// slight overlap (starts at 45%) so the handoff doesn't read as two disjoint steps.
    private var dotAppearProgress: Double { max(0, min(1, (progress - 0.45) / 0.55)) }

    /// Dot pops in with a small overshoot past 1.0 rather than the row's plain ease-out,
    /// so the spine reads as being "drawn" rather than just fading up with everything else.
    private var dotScale: Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        let x = dotAppearProgress - 1
        return 1 + c3 * x * x * x + c1 * x * x
    }

    private var dotColor: Color {
        switch item.status {
        case .trial:             return .purple
        case .autoRenew:         return .green
        case .manualRenew:       return .blue
        case .cancelledButActive: return .orange
        case .expired:           return .gray
        }
    }
}

// MARK: - Option 2: Monthly Calendar Grid

struct CalendarGridView: View {
    let items: [SubscriptionItem]
    let currency: String

    @State private var displayedMonth: Date = {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    }()

    private var cal: Calendar { Calendar.current }

    private var monthTotal: Double {
        let comps = cal.dateComponents([.year, .month], from: displayedMonth)
        return items.compactMap { item -> Double? in
            let itemComps = cal.dateComponents([.year, .month], from: item.nextRelevantDate)
            guard itemComps.year == comps.year, itemComps.month == comps.month else { return nil }
            return item.cost.map { CurrencyInfo.convert($0, from: item.currency, to: currency) }
        }.reduce(0, +)
    }

    private var monthLabel: String {
        displayedMonth.formatted(.dateTime.month(.wide).year())
    }

    // Days in the displayed month padded to the user's calendar week start.
    private var gridDays: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: displayedMonth)) else { return [] }
        var days: [Date?] = Array(repeating: nil, count: leadingWeekdaySlots(for: firstDay, calendar: cal))
        for d in range {
            days.append(cal.date(byAdding: .day, value: d - 1, to: firstDay))
        }
        // Pad to complete the last row
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    // Items keyed by their calendar day start
    private func items(on date: Date) -> [SubscriptionItem] {
        let target = cal.startOfDay(for: date)
        return items.filter { cal.startOfDay(for: $0.nextRelevantDate) == target }
    }

    var body: some View {
        GeometryReader { geo in
            let horizontalPadding: CGFloat = 12
            let gridSpacing: CGFloat = 4
            let rows = max(gridDays.count / 7, 5)
            let headerHeight: CGFloat = 88
            let labelsHeight: CGFloat = 18
            let availableWidth = geo.size.width - horizontalPadding * 2 - gridSpacing * 6
            let availableHeight = geo.size.height - headerHeight - labelsHeight - 20
            let cellSize = max(1, floor(min(
                availableWidth / 7,
                (availableHeight - gridSpacing * CGFloat(rows - 1)) / CGFloat(rows)
            )))
            let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: gridSpacing), count: 7)

            VStack(spacing: 8) {
                // Month header
                HStack {
                    Button {
                        Haptics.fire(.light)
                        withAnimation(.spring(duration: 0.3)) {
                            displayedMonth = cal.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(8)
                            .background(Color.secondary.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    VStack(spacing: 4) {
                        Text(monthLabel)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(CurrencyInfo.format(monthTotal, code: currency))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        if monthTotal > 0 {
                            let avg = monthTotal / Double(cal.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30)
                            Text(CurrencyInfo.format(avg, code: currency) + " / day avg")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }

                    Spacer()

                    Button {
                        Haptics.fire(.light)
                        withAnimation(.spring(duration: 0.3)) {
                            displayedMonth = cal.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(8)
                            .background(Color.secondary.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 4)
                .frame(height: headerHeight, alignment: .top)

                // Day-of-week headers
                HStack(spacing: 0) {
                    ForEach(Array(localizedWeekdayInitials(calendar: cal).enumerated()), id: \.offset) { _, d in
                        Text(d)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: cellSize)
                    }
                }
                .frame(height: labelsHeight)
                .padding(.horizontal, horizontalPadding)

                // Calendar grid
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                        if let day {
                            CalendarDayCell(date: day, items: items(on: day))
                                .frame(width: cellSize, height: cellSize)
                        } else {
                            Color.clear.frame(width: cellSize, height: cellSize)
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
                .padding(.horizontal, horizontalPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct CalendarDayCell: View {
    let date: Date
    let items: [SubscriptionItem]

    private var isToday: Bool { Calendar.current.isDateInToday(date) }
    private var dayNumber: Int { Calendar.current.component(.day, from: date) }
    private var isPast: Bool { date < Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(isPast ? 0.05 : 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isToday ? Color.white.opacity(0.5) : Color.white.opacity(0.04), lineWidth: 1)
                )

            VStack(spacing: 6) {
                HStack {
                    Text("\(dayNumber)")
                        .font(.system(size: 11, weight: isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? .primary : Color.secondary.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)

                Spacer()

                if items.isEmpty {
                    Spacer()
                } else if items.count == 1 {
                    TimelineMiniIconView(item: items[0], size: 20)
                        .padding(.bottom, 6)
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(items.prefix(3))) { item in
                            TimelineMiniIconView(item: item, size: 16)
                        }
                        if items.count > 3 {
                            Text("+\(items.count - 3)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }
}

struct TimelineMiniIconView: View {
    let item: SubscriptionItem
    let size: CGFloat

    var body: some View {
        Group {
            if (item.iconSource == .customImage || item.iconSource == .favicon),
               let data = item.iconData,
               let img = platformImage(from: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28)
                        .fill(Color.secondary.opacity(0.18))
                    Image(systemName: item.systemIconName)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                }
                .frame(width: size, height: size)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Option 1: 90-Day Heatmap Grid

struct HeatmapView: View {
    let items: [SubscriptionItem]
    let currency: String

    private var cal: Calendar { Calendar.current }
    private let days = 91  // 13 weeks

    private struct DayData: Identifiable {
        let id: Int  // offset from today
        let date: Date
        let spend: Double
        let items: [SubscriptionItem]
    }

    private var dayData: [DayData] {
        let start = calendarWeekStart(for: Date(), calendar: cal)
        let itemsByDay = Dictionary(grouping: items) { item in
            cal.startOfDay(for: item.nextRelevantDate)
        }
        return (0..<days).map { offset in
            let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
            let dayItems = itemsByDay[date] ?? []
            let spend = dayItems.compactMap { item in
                item.cost.map { CurrencyInfo.convert($0, from: item.currency, to: currency) }
            }.reduce(0, +)
            return DayData(id: offset, date: date, spend: spend, items: dayItems)
        }
    }

    @State private var selectedDayID: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let data = dayData
            let maxSpend = data.map(\.spend).max() ?? 1
            let horizontalPadding: CGFloat = 16
            let gridSpacing: CGFloat = 4
            let rows = 13
            let headerHeight: CGFloat = 96
            let labelsHeight: CGFloat = 16
            let availableWidth = geo.size.width - horizontalPadding * 2 - gridSpacing * 6
            let availableHeight = geo.size.height - headerHeight - labelsHeight - 60
            let cellSize = max(1, floor(min(
                availableWidth / 7,
                (availableHeight - gridSpacing * CGFloat(rows - 1)) / CGFloat(rows)
            )))
            let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: gridSpacing), count: 7)

            VStack(alignment: .leading, spacing: 10) {
                // Header
                VStack(spacing: 4) {
                    Text("Next 13 Weeks")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    let total = data.map(\.spend).reduce(0, +)
                    Text(CurrencyInfo.format(total, code: currency))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("total spend across 13 calendar weeks")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

                // Day-of-week labels
                HStack(spacing: 0) {
                    ForEach(Array(localizedWeekdayInitials(calendar: cal).enumerated()), id: \.offset) { _, d in
                        Text(d)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: cellSize)
                    }
                }
                .frame(height: labelsHeight)
                .padding(.horizontal, horizontalPadding)

                // Grid
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(data) { day in
                        HeatmapCell(
                            day: day.date,
                            spend: day.spend,
                            items: day.items,
                            maxSpend: maxSpend,
                            currency: currency,
                            isSelected: selectedDayID == day.id
                        )
                        .frame(width: cellSize, height: cellSize)
                        .onTapGesture {
                            Haptics.fire(.selectionChanged)
                            withAnimation(.spring(duration: 0.2)) {
                                selectedDayID = selectedDayID == day.id ? nil : day.id
                            }
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
                .padding(.horizontal, horizontalPadding)

                // Detail card for selected day
                if let selectedDayID,
                   let day = data.first(where: { $0.id == selectedDayID }),
                   !day.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.date.formatted(date: .complete, time: .omitted))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(day.items) { item in
                            HStack(spacing: 10) {
                                TimelineMiniIconView(item: item, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 14, weight: .medium))
                                    if let c = item.cost {
                                        Text(CurrencyInfo.format(c, code: item.currency))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                StatusBadge(status: item.status, itemType: item.itemType)
                            }
                        }
                    }
                    .padding(12)
                    .glassEffect(in: .rect(cornerRadius: 16))
                    .padding(.horizontal, horizontalPadding)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Intensity legend
                HStack(spacing: 6) {
                    Text("Less")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(heatColor(fraction: f))
                            .frame(width: 14, height: 14)
                    }
                    Text("More")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, horizontalPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    func heatColor(fraction: Double) -> Color {
        if fraction <= 0 { return Color.secondary.opacity(0.08) }
        return Color.teal.opacity(0.15 + 0.7 * fraction)
    }
}

struct HeatmapCell: View {
    let day: Date
    let spend: Double
    let items: [SubscriptionItem]
    let maxSpend: Double
    let currency: String
    let isSelected: Bool

    private var fraction: Double { maxSpend > 0 ? min(spend / maxSpend, 1.0) : 0 }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var dayNum: Int { Calendar.current.component(.day, from: day) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(cellColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.white.opacity(0.6) : Color.white.opacity(0.08),
                                      lineWidth: isSelected ? 1.5 : 1)
                )

            if items.count == 1 {
                TimelineMiniIconView(item: items[0], size: 18)
            } else if items.count > 1 {
                HStack(spacing: 3) {
                    ForEach(Array(items.prefix(3))) { item in
                        TimelineMiniIconView(item: item, size: 14)
                    }
                    if items.count > 3 {
                        Text("+\(items.count - 3)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
        }
    }

    private var cellColor: Color {
        if spend <= 0 { return Color.secondary.opacity(0.08) }
        return Color.teal.opacity(0.15 + 0.7 * fraction)
    }
}

// MARK: - Option 3: Swim Lane (Gantt-style)

struct SwimLaneView: View {
    let items: [SubscriptionItem]
    private let laneHeight: CGFloat = 52
    private let horizPadding: CGFloat = 16
    private let nameColumnWidth: CGFloat = 168

    private var activeItems: [SubscriptionItem] {
        items.filter { if case .expired = $0.status { return false }; return true }
            .sorted { $0.nextRelevantDate < $1.nextRelevantDate }
    }

    private var expiredItems: [SubscriptionItem] {
        items.filter { if case .expired = $0.status { return true }; return false }
            .sorted { $0.nextRelevantDate < $1.nextRelevantDate }
    }

    private var maxDays: Int {
        activeItems.map(\.daysUntilRenewal).max().map { max($0, 1) } ?? 1
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header row
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11, weight: .bold))
                        Text("RENEWAL DATE")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.6)
                    }
                    .foregroundStyle(Color.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.12), in: Capsule())
                    .frame(width: nameColumnWidth, alignment: .leading)
                    Spacer()
                }
                .padding(.horizontal, horizPadding)
                .padding(.vertical, 8)

                ForEach(activeItems) { item in
                    SwimLaneRow(item: item, maxDays: maxDays, laneHeight: laneHeight, nameColumnWidth: nameColumnWidth)
                }

                if !expiredItems.isEmpty {
                    HStack {
                        Text("EXPIRED")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, horizPadding)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                    ForEach(expiredItems) { item in
                        SwimLaneRow(item: item, maxDays: maxDays, laneHeight: laneHeight, nameColumnWidth: nameColumnWidth)
                    }
                }

                Spacer(minLength: 100)
            }
            .padding(.top, 8)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

struct SwimLaneRow: View {
    let item: SubscriptionItem
    let maxDays: Int
    let laneHeight: CGFloat
    let nameColumnWidth: CGFloat

    private var days: Int { max(item.daysUntilRenewal, 0) }
    private var fraction: Double {
        if case .expired = item.status { return 0 }
        return maxDays > 0 ? Double(days) / Double(maxDays) : 0
    }

    private var barColor: Color {
        switch item.urgency {
        case .critical: return .red
        case .warning:  return .orange
        case .expired:  return .secondary
        case .normal:   return .blue
        }
    }

    private var labelText: String {
        if case .expired = item.status { return "Expired" }
        return days == 0 ? "Today" : "\(days)d"
    }

    var body: some View {
        HStack(spacing: 10) {
            // Icon + name
            HStack(spacing: 8) {
                ItemIconView(item: item, size: 32)
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: nameColumnWidth, alignment: .leading)

            // Bar track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: .infinity, alignment: .center)

                    // Fill
                    if fraction > 0 {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [barColor.opacity(0.7), barColor],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: max(8, geo.size.width * fraction), height: 8)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }

                    // Days label at end of bar
                    Text(labelText)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(barColor)
                        .offset(x: fraction > 0 ? max(8, geo.size.width * fraction) + 4 : 0)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(height: laneHeight)
        }
        .padding(.horizontal, 16)
        .frame(height: laneHeight)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.04))
                .padding(.horizontal, 8)
        )
    }
}

// MARK: - Option 4: Spend Spike Bar Chart (12-week forward)

struct SpendSpikeView: View {
    let items: [SubscriptionItem]
    let currency: String

    private var cal: Calendar { Calendar.current }

    private struct WeekBucket: Identifiable {
        let id: Int  // week offset from today
        let startDate: Date
        let endDate: Date
        let items: [SubscriptionItem]
        let currency: String
        var total: Double {
            items.compactMap { item in
                item.cost.map { CurrencyInfo.convert($0, from: item.currency, to: currency) }
            }.reduce(0, +)
        }

        var label: String {
            let df = DateFormatter()
            df.dateFormat = "MMM d"
            return df.string(from: startDate)
        }
    }

    private var weeks: [WeekBucket] {
        let today = cal.startOfDay(for: Date())
        return (0..<12).map { w in
            let start = cal.date(byAdding: .day, value: w * 7, to: today) ?? today
            let end   = cal.date(byAdding: .day, value: w * 7 + 6, to: today) ?? today
            let bucket = items.filter {
                let d = cal.startOfDay(for: $0.nextRelevantDate)
                return d >= start && d <= end
            }
            return WeekBucket(id: w, startDate: start, endDate: end, items: bucket, currency: currency)
        }
    }

    private var maxTotal: Double { weeks.map(\.total).max() ?? 1 }

    @State private var selectedWeek: WeekBucket? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Summary header
                let grandTotal = weeks.map(\.total).reduce(0, +)
                VStack(spacing: 4) {
                    Text("Next 12 Weeks")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(CurrencyInfo.format(grandTotal, code: currency))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    if let peak = weeks.max(by: { $0.total < $1.total }), peak.total > 0 {
                        Text("Biggest spike: \(peak.label) — \(CurrencyInfo.format(peak.total, code: currency))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                // Bar chart
                GeometryReader { geo in
                    let barW = (geo.size.width - 32) / CGFloat(weeks.count) - 4
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(weeks) { week in
                            let h = maxTotal > 0 ? CGFloat(week.total / maxTotal) * 180 : 0
                            VStack(spacing: 4) {
                                // Icons floating above bar
                                if !week.items.isEmpty {
                                    ZStack {
                                        ForEach(Array(week.items.prefix(3).enumerated()), id: \.offset) { idx, item in
                                            ItemIconView(item: item, size: 20)
                                                .offset(x: CGFloat(idx) * 6 - CGFloat(min(week.items.count, 3) - 1) * 3)
                                        }
                                    }
                                    .frame(height: 22)
                                } else {
                                    Color.clear.frame(height: 22)
                                }

                                // Bar
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedWeek?.id == week.id ?
                                          LinearGradient(colors: [.orange, .red], startPoint: .bottom, endPoint: .top) :
                                          LinearGradient(colors: [.blue.opacity(0.6), .blue], startPoint: .bottom, endPoint: .top))
                                    .frame(width: barW, height: max(h, week.total > 0 ? 4 : 0))
                                    .animation(.spring(duration: 0.3), value: selectedWeek?.id)

                                // Week label
                                Text(week.label)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .frame(width: barW)
                            }
                            .onTapGesture {
                                Haptics.fire(.selectionChanged)
                                withAnimation(.spring(duration: 0.2)) {
                                    selectedWeek = selectedWeek?.id == week.id ? nil : week
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .padding(.horizontal, 16)
                }
                .frame(height: 230)

                // Selected week detail
                if let week = selectedWeek, !week.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Week of \(week.label)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(CurrencyInfo.format(week.total, code: currency))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.primary)
                        }
                        ForEach(week.items) { item in
                            HStack(spacing: 10) {
                                ItemIconView(item: item, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 14, weight: .medium))
                                    Text(item.nextRelevantDate.formatted(date: .abbreviated, time: .omitted))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let c = item.cost {
                                    Text(CurrencyInfo.format(c, code: item.currency))
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                        }
                    }
                    .padding(14)
                    .glassEffect(in: .rect(cornerRadius: 16))
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer(minLength: 100)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

// MARK: - Option 5: Two-Week Strip

struct MonthStripView: View {
    let items: [SubscriptionItem]
    let currency: String

    private var cal: Calendar { Calendar.current }

    private struct DayCard: Identifiable {
        let id: Int
        let date: Date
        let items: [SubscriptionItem]
        let currency: String
        var total: Double {
            items.compactMap { item in
                item.cost.map { CurrencyInfo.convert($0, from: item.currency, to: currency) }
            }.reduce(0, +)
        }
    }

    private struct Period: Identifiable {
        let id: Int
        let startDate: Date
        let days: [DayCard]
        var items: [SubscriptionItem] { days.flatMap(\.items) }
        var total: Double { days.reduce(0) { $0 + $1.total } }
    }

    @State private var selectedDay: DayCard? = nil
    @State private var currentPeriodID: Int = 0

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let periodLength = resolvedPeriodLength(isLandscape: isLandscape)
            let periods = buildPeriods(length: periodLength, count: 12)
            let spacing: CGFloat = 6
            let horizontalPadding: CGFloat = 8
            let availableWidth = max(1, geo.size.width - horizontalPadding * 2 - spacing * CGFloat(periodLength - 1))
            let cardWidth = max(1, floor(availableWidth / CGFloat(periodLength)))
            let currentPeriod = periods.first(where: { $0.id == currentPeriodID }) ?? periods.first

            VStack(spacing: 0) {
                TabView(selection: $currentPeriodID) {
                    ForEach(periods) { period in
                        HStack(spacing: spacing) {
                            ForEach(period.days) { day in
                                MonthStripCard(
                                    day: day.date,
                                    items: day.items,
                                    total: day.total,
                                    currency: currency,
                                    isSelected: selectedDay?.id == day.id,
                                    width: cardWidth
                                )
                                .onTapGesture {
                                    Haptics.fire(.selectionChanged)
                                    withAnimation(.spring(duration: 0.2)) {
                                        selectedDay = selectedDay?.id == day.id ? nil : day
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 10)
                        .frame(width: geo.size.width, alignment: .center)
                        .tag(period.id)
                    }
                }
#if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
#endif
                .frame(width: geo.size.width, height: 130)
                .clipped()
                .onChange(of: currentPeriodID) { _, _ in
                    Haptics.fire(.selectionChanged)
                    selectedDay = nil
                }

                Divider().opacity(0.3)

                ScrollView {
                    if let day = selectedDay {
                        if day.items.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.secondary)
                                Text("Nothing due on \(day.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                        } else {
                            VStack(spacing: 10) {
                                HStack {
                                    Text(day.date.formatted(date: .complete, time: .omitted))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(CurrencyInfo.format(day.total, code: currency))
                                        .font(.system(size: 15, weight: .bold))
                                }
                                .padding(.horizontal)
                                .padding(.top, 12)
                                ForEach(day.items) { item in
                                    SubscriptionRowView(item: item)
                                        .padding(.horizontal)
                                }
                            }
                        }
                    } else if let period = currentPeriod {
                        let periodItems = period.items.sorted { $0.nextRelevantDate < $1.nextRelevantDate }
                        VStack(spacing: 10) {
                            HStack {
                                Text(periodLabel(start: period.startDate, length: periodLength))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(CurrencyInfo.format(period.total, code: currency))
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .padding(.horizontal)
                            .padding(.top, 12)
                            if periodItems.isEmpty {
                                Text("No renewals in this period")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 24)
                            } else {
                                ForEach(periodItems) { item in
                                    SubscriptionRowView(item: item)
                                        .padding(.horizontal)
                                }
                            }
                        }
                    } else {
                        Text("Tap a day to see details")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    Spacer(minLength: 80)
                }
            }
        }
    }

    private func buildPeriods(length: Int, count: Int) -> [Period] {
        let firstStart = calendarWeekStart(for: Date(), calendar: cal)
        let itemsByDay = Dictionary(grouping: items) { item in
            cal.startOfDay(for: item.nextRelevantDate)
        }
        return (0..<count).map { index in
            let start = cal.date(byAdding: .day, value: index * length, to: firstStart) ?? firstStart
            let days: [DayCard] = (0..<length).map { offset in
                let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
                let dayItems = itemsByDay[date] ?? []
                return DayCard(id: index * length + offset, date: date, items: dayItems, currency: currency)
            }
            return Period(id: index, startDate: start, days: days)
        }
    }

    private func periodLabel(start: Date, length: Int) -> String {
        let currentWeekStart = calendarWeekStart(for: Date(), calendar: cal)
        let weekOffset = cal.dateComponents([.weekOfYear], from: currentWeekStart, to: start).weekOfYear ?? 0
        if length == 7 {
            if weekOffset == 0 { return "This Week" }
            if weekOffset == 1 { return "Next Week" }
        } else if length == 14 {
            if weekOffset == 0 { return "This Week + Next Week" }
            if weekOffset == 2 { return "In 2 Weeks" }
        }

        let end = cal.date(byAdding: .day, value: length - 1, to: start) ?? start
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return "\(df.string(from: start)) – \(df.string(from: end))"
    }

    private func resolvedPeriodLength(isLandscape: Bool) -> Int {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad && isLandscape { return 14 }
        return 7
#else
        return 14
#endif
    }
}

struct MonthStripCard: View {
    let day: Date
    let items: [SubscriptionItem]
    let total: Double
    let currency: String
    let isSelected: Bool
    let width: CGFloat

    private var cal: Calendar { Calendar.current }
    private var isToday: Bool { cal.isDateInToday(day) }
    private var isPast: Bool { day < cal.startOfDay(for: Date()) }
    private var dayNum: String { "\(cal.component(.day, from: day))" }
    private var weekday: String {
        let df = DateFormatter()
        df.dateFormat = "EEE"
        return df.string(from: day)
    }

    private var weekdayColor: Color { isToday ? .blue : Color.secondary.opacity(0.4) }
    private var dayNumColor: Color { isToday ? .blue : (isPast ? Color.secondary.opacity(0.35) : .primary) }
    private var bgColor: Color { isSelected ? Color.blue.opacity(0.18) : (isToday ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.07)) }
    private var borderColor: Color { isSelected ? Color.blue.opacity(0.6) : (isToday ? Color.blue.opacity(0.3) : Color.clear) }

    var body: some View {
        VStack(spacing: 4) {
            Text(weekday.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(weekdayColor)

            Text(dayNum)
                .font(.system(size: 15, weight: isToday ? .bold : .medium))
                .foregroundStyle(dayNumColor)

            if total > 0 {
                Text(CurrencyInfo.format(total, code: currency))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Color.clear.frame(height: 10)
            }

            HStack(spacing: 2) {
                ForEach(Array(items.prefix(2))) { item in
                    TimelineMiniIconView(item: item, size: 14)
                }
                if items.count > 2 {
                    Text("+\(items.count - 2)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 16)
        }
        .frame(width: width)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 12).fill(bgColor))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor, lineWidth: 1))
        .opacity(isPast && !isSelected ? 0.55 : 1.0)
        .animation(.spring(duration: 0.2), value: isSelected)
    }
}

// MARK: - Insights View

struct InsightsView: View {
    @Query(filter: #Predicate<SubscriptionItem> { !$0.isArchived }) private var allItems: [SubscriptionItem]
    @AppStorage("preferredCurrency") private var preferredCurrency = SettingsView.localeCurrencyCode

    enum CostPeriod: String, CaseIterable {
        case monthly  = "Monthly"
        case annual   = "Annual"
        case ytd      = "YTD"
        case lifetime = "Lifetime"

        /// Monthly total is free; longer-horizon analysis is Pro.
        var isPro: Bool { self != .monthly }
    }
    @State private var costPeriod: CostPeriod = .monthly
    @Environment(PurchaseManager.self) private var purchaseManager
    @State private var showPaywall = false

    enum ForecastHorizon: Int, CaseIterable {
        case thirtyDays = 30
        case ninetyDays = 90
        case yearDays = 365

        var label: String {
            switch self {
            case .thirtyDays: return "30d"
            case .ninetyDays: return "90d"
            case .yearDays: return "365d"
            }
        }

        /// 30-day forecast is free; longer horizons (and the monthly chart) are Pro.
        var isPro: Bool { self != .thirtyDays }
    }
    @State private var forecastHorizon: ForecastHorizon = .thirtyDays

    /// Tapped donut segment; filters `costBreakdown` below it. Tapping the same segment
    /// again clears it (toggled inside `CategoryDonutChart`).
    @State private var selectedCategory: SubscriptionCategory?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entrance = InsightsEntrance()

    private var activeItems: [SubscriptionItem] {
        allItems.filter(\.isActiveSubscription)
    }
    private var displayCurrency: String { preferredCurrency }

    private var monthlyTotal: Double {
        activeItems
            .filter(\.contributesToCurrentRecurringSpend)
            .compactMap { $0.monthlyCostConverted(to: preferredCurrency) }
            .reduce(0, +)
    }
    private var yearlyTotal: Double { monthlyTotal * 12 }

    /// Year-to-date: per-item cost from the later of (Jan 1 or effectiveStartDate) to today.
    /// Accurately reflects when each subscription actually started within this year.
    private var ytdTotal: Double {
        let now = Date()
        let cal = Calendar.current
        guard let jan1 = cal.date(from: cal.dateComponents([.year], from: now)) else { return 0 }
        return allItems.reduce(0) { sum, item in
            guard let monthly = item.monthlyCostConverted(to: preferredCurrency) else { return sum }
            // Start of billing this year: later of Jan 1 and effectiveStartDate
            let billingFrom = max(jan1, item.effectiveStartDate)
            // End of billing: today (or the date it stopped, for cancelled/expired items)
            let billingTo = billingEndDate(for: item, cap: now)
            guard billingFrom < billingTo else { return sum }
            let days = cal.dateComponents([.day], from: billingFrom, to: billingTo).day ?? 0
            // Convert day fraction to months (average 30.44 days/month)
            let months = Double(days) / 30.4375
            return sum + monthly * months
        }
    }

    /// Lifetime: per-item cost from effectiveStartDate to today (or until it stopped).
    private var lifetimeTotal: Double {
        let now = Date()
        return allItems.reduce(0) { sum, item in
            guard let monthly = item.monthlyCostConverted(to: preferredCurrency) else { return sum }
            let billingFrom = item.effectiveStartDate
            let billingTo = billingEndDate(for: item, cap: now)
            guard billingFrom < billingTo else { return sum }
            let days = Calendar.current.dateComponents([.day], from: billingFrom, to: billingTo).day ?? 0
            let months = Double(days) / 30.4375
            return sum + monthly * months
        }
    }

    /// Returns the effective billing end date for cost calculation purposes.
    /// For expired/cancelled items, uses the date they stopped; otherwise uses `cap` (today).
    private func billingEndDate(for item: SubscriptionItem, cap: Date) -> Date {
        switch item.status {
        case .expired:
            // Use nextRelevantDate (when it expired) if it's in the past, otherwise cap
            return min(item.nextRelevantDate, cap)
        case .cancelledButActive(let until):
            return min(until, cap)
        default:
            return cap
        }
    }

    private var displayTotal: Double {
        switch costPeriod {
        case .monthly:  return monthlyTotal
        case .annual:   return yearlyTotal
        case .ytd:      return ytdTotal
        case .lifetime: return lifetimeTotal
        }
    }

    /// Swiping the donut cycles the same `costPeriod` state the segmented picker drives, so
    /// the existing `.onChange(of: costPeriod)` (Pro-gate revert + haptic) applies unchanged
    /// regardless of which control made the change.
    private func cyclePeriod(forward: Bool) {
        let cases = CostPeriod.allCases
        guard let index = cases.firstIndex(of: costPeriod) else { return }
        let count = cases.count
        let newIndex = forward ? (index + 1) % count : (index - 1 + count) % count
        withAnimation(.smooth(duration: 0.3)) { costPeriod = cases[newIndex] }
    }

    private var costPeriodIcon: String {
        switch costPeriod {
        case .monthly:  return "calendar"
        case .annual:   return "chart.line.uptrend.xyaxis"
        case .ytd:      return "calendar.badge.checkmark"
        case .lifetime: return "infinity"
        }
    }

    private var activeCount: Int { activeItems.count }
    private var autoRenewCount: Int { activeItems.filter(\.isAutoRenewingActiveSubscription).count }
    private var trialCount: Int { activeItems.filter(\.isTrial).count }
    private var manualCount: Int { activeItems.filter(\.isManualActiveSubscription).count }
    private var cancelledCount: Int {
        activeItems.filter(\.isCancelledButActiveSubscription).count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Period picker
                    Picker("", selection: $costPeriod) {
                        ForEach(CostPeriod.allCases, id: \.self) { period in
                            if period.isPro && !purchaseManager.isPremium {
                                Text("\(Image(systemName: "lock.fill")) \(period.rawValue)").tag(period)
                            } else {
                                Text(period.rawValue).tag(period)
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .onChange(of: costPeriod) { _, newValue in
                        // Pro periods are selectable in the segmented control but revert
                        // immediately and surface the paywall for a free user.
                        if newValue.isPro && !purchaseManager.isPremium {
                            Haptics.fire(.warning)
                            costPeriod = .monthly
                            showPaywall = true
                        } else {
                            Haptics.fire(.selectionChanged)
                        }
                    }

                    // Stat tiles sit directly under the period picker so the control that
                    // drives them is next to what it changes — with the forecast card on
                    // top (its previous position), switching Monthly→Annual left the whole
                    // visible top of the screen unchanged and read as "nothing happened".
                    compactStatsGrid
                    categoryDonutSection
                    forecastSection
                    if !costBreakdownItems.isEmpty { costBreakdown }
                    Spacer(minLength: 40)
                }
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(groupedBackground.ignoresSafeArea())
            .navigationTitle("Insights")
            .largeNavigationTitle()
            .expiredPaywallSheet(isPresented: $showPaywall)
            .onAppear { entrance.enter(reduceMotion: reduceMotion) }
            .onDisappear { entrance.leave() }
        }
    }

    // MARK: - Forecast (R3)

    private var forecastTotal: Double {
        ForecastEngine.total(
            for: allItems, horizonDays: forecastHorizon.rawValue,
            targetCurrency: preferredCurrency, convert: CurrencyInfo.convert
        )
    }

    private var forecastBiggestHits: [ForecastEngine.Contribution] {
        ForecastEngine.biggestUpcoming(
            for: allItems, horizonDays: forecastHorizon.rawValue,
            targetCurrency: preferredCurrency, convert: CurrencyInfo.convert, limit: 5
        )
    }

    /// Granularity + buckets are both derived from the selected horizon. Before 2026-07-28
    /// this was `monthlyBuckets(monthsAhead: 12)` — hardcoded, so 30/90/365 moved the
    /// headline total and the hits list but redrew an identical chart every time.
    private var forecastGranularity: ForecastEngine.Granularity {
        .forHorizon(days: forecastHorizon.rawValue)
    }

    private var forecastBuckets: [ForecastEngine.Bucket] {
        ForecastEngine.buckets(
            for: allItems, horizonDays: forecastHorizon.rawValue,
            granularity: forecastGranularity,
            targetCurrency: preferredCurrency, convert: CurrencyInfo.convert
        )
    }

    private var forecastCumulative: [ForecastEngine.CumulativePoint] {
        ForecastEngine.cumulative(
            for: allItems, horizonDays: forecastHorizon.rawValue,
            targetCurrency: preferredCurrency, convert: CurrencyInfo.convert
        )
    }

    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11, weight: .bold))
                Text("FORECAST")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            VStack(spacing: 14) {
                Picker("", selection: $forecastHorizon) {
                    ForEach(ForecastHorizon.allCases, id: \.self) { horizon in
                        if horizon.isPro && !purchaseManager.isPremium {
                            Text("\(Image(systemName: "lock.fill")) \(horizon.label)").tag(horizon)
                        } else {
                            Text(horizon.label).tag(horizon)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: forecastHorizon) { _, newValue in
                    if newValue.isPro && !purchaseManager.isPremium {
                        Haptics.fire(.warning)
                        forecastHorizon = .thirtyDays
                        showPaywall = true
                    } else {
                        Haptics.fire(.selectionChanged)
                    }
                }

                VStack(spacing: 2) {
                    // Counts up from 0 on entrance and tweens between totals when the
                    // horizon changes — the cumulative curve below lands on this figure.
                    AnimatedCurrencyText(
                        value: forecastTotal * entrance.progress,
                        currencyCode: preferredCurrency
                    )
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .animation(.smooth(duration: 0.45), value: forecastTotal)
                    Text("projected over next \(forecastHorizon.rawValue) days")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.3), value: forecastHorizon)
                }
                .frame(maxWidth: .infinity)

                // Cumulative curve is free (it's the 30-day horizon that's already free);
                // the granular bucket breakdown is Pro.
                ForecastCumulativeChart(
                    points: forecastCumulative,
                    currencyCode: preferredCurrency,
                    granularity: forecastGranularity,
                    progress: entrance.progress
                )
                .animation(.smooth(duration: 0.45), value: forecastHorizon)

                if purchaseManager.isPremium {
                    ForecastBucketChart(
                        buckets: forecastBuckets,
                        granularity: forecastGranularity,
                        currencyCode: preferredCurrency,
                        progress: entrance.progress
                    )
                    .animation(.smooth(duration: 0.45), value: forecastHorizon)
                } else {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Image(systemName: "lock.fill")
                            Text("Unlock the renewal breakdown chart")
                            Spacer()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                if !forecastBiggestHits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Biggest upcoming hits")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(forecastBiggestHits) { hit in
                            HStack {
                                Text(hit.itemName)
                                    .font(.system(size: 14))
                                    .lineLimit(1)
                                Spacer()
                                Text(hit.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text(CurrencyInfo.format(hit.amount, code: preferredCurrency))
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                    }
                }
            }
            .padding(16)
            .glassEffect(in: .rect(cornerRadius: 20))
        }
        .padding(.horizontal)
        .insightsEntrance(entrance.staggered(index: 7))
    }

    // MARK: - Category donut (R3b)

    /// Grouped from the same period-based base list `costBreakdown` uses, so the donut and
    /// the "By Cost" list underneath always agree — before any tap-to-filter is applied.
    /// Items with no custom user category (or a category name that isn't a built-in enum
    /// case) collapse into `.other`, matching `item.category`'s existing nil-fallback
    /// behaviour elsewhere in the app.
    /// Every category is always represented (zero-amount ones included), in the fixed
    /// `SubscriptionCategory.allCases` declaration order — **never** re-sorted by amount.
    /// `CategoryDonutChart`'s `Chart(slices)` feeds this array directly into `SectorMark`s,
    /// and Swift Charts' pie/donut geometry interpolation ties each mark's continuous
    /// animation (angle *and* color) to its position in that array, not to `slice.id`.
    /// Sorting by amount used to put the biggest category at index 0 every time — so when
    /// the *rank order* changed between periods (e.g. Streaming overtakes Professional &
    /// Business going from YTD to Lifetime), the mark at index 0 would smoothly morph from
    /// the old top category's geometry+color into the new one's, instead of each category
    /// staying anchored to its own slice. That's what read as "the brown wedge grows huge
    /// and turns into Streaming" — the wedge didn't grow, it inherited a different
    /// category's identity mid-animation. Keeping this array's order fixed regardless of
    /// amount means every category always owns the same index, so only its own angle
    /// interpolates — no more cross-category color/identity swaps. (Amount-sorted display
    /// order for the legend is a separate, display-only sort — see `nonZeroSlices` in
    /// `CategoryDonutChart`.)
    private var categorySpend: [CategorySpendSlice] {
        var totals: [SubscriptionCategory: Double] = [:]
        for item in costBreakdownBaseItems {
            guard item.monthlyCostConverted(to: preferredCurrency) != nil else { continue }
            totals[item.category ?? .other, default: 0] += periodCost(for: item)
        }
        return SubscriptionCategory.allCases
            .map { CategorySpendSlice(category: $0, amount: totals[$0, default: 0]) }
    }

    private var categoryDonutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("BY CATEGORY")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            if purchaseManager.isPremium {
                Group {
                    if !categorySpend.contains(where: { $0.amount > 0 }) {
                        Text("No spend to break down yet")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        CategoryDonutChart(
                            slices: categorySpend,
                            currencyCode: preferredCurrency,
                            progress: entrance.progress,
                            selectedCategory: $selectedCategory,
                            onSwipe: { direction in cyclePeriod(forward: direction == .forward) }
                        )
                    }
                }
                .padding(16)
                .glassEffect(in: .rect(cornerRadius: 20))
                .animation(.smooth(duration: 0.45), value: costPeriod)
            } else {
                Button {
                    showPaywall = true
                } label: {
                    HStack {
                        Image(systemName: "lock.fill")
                        Text("Unlock the category spend breakdown")
                        Spacer()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .insightsEntrance(entrance.staggered(index: 6))
    }

    private var statTiles: [(title: String, value: CompactInsightTile.Value, icon: String, color: Color)] {
        [
            (costPeriod.rawValue + " Cost", .currency(displayTotal, code: displayCurrency), costPeriodIcon, .blue),
            ("Active",        .count(activeCount),    "checkmark.seal.fill", .blue),
            ("Auto-Renewing", .count(autoRenewCount), "arrow.clockwise",     .green),
            ("Free Trials",   .count(trialCount),     "gift.fill",           .purple),
            ("Manual",        .count(manualCount),    "hand.tap.fill",       .indigo),
            ("Cancelled",     .count(cancelledCount), "xmark.circle",        .red),
        ]
    }

    private var compactStatsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Array(statTiles.enumerated()), id: \.offset) { index, tile in
                CompactInsightTile(
                    title: tile.title, value: tile.value, icon: tile.icon, color: tile.color,
                    progress: entrance.staggered(index: index)
                )
            }
        }
        .padding(.horizontal)
        .animation(.smooth(duration: 0.4), value: costPeriod)
    }

    /// Multiplier to convert monthly cost to the selected period's cost
    private var periodMultiplier: Double {
        switch costPeriod {
        case .monthly:  return 1.0
        case .annual:   return 12.0
        case .ytd:
            let cal = Calendar.current
            let now = Date()
            let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1
            let daysInYear = cal.range(of: .day, in: .year, for: now)?.count ?? 365
            return 12.0 * Double(dayOfYear) / Double(daysInYear)
        case .lifetime:
            return 1.0  // handled per-item in periodCost(for:)
        }
    }

    private func periodCost(for item: SubscriptionItem) -> Double {
        guard let monthly = item.monthlyCostConverted(to: preferredCurrency) else { return 0 }
        let now = Date()
        let cal = Calendar.current
        switch costPeriod {
        case .monthly:
            return monthly
        case .annual:
            return monthly * 12.0
        case .ytd:
            guard let jan1 = cal.date(from: cal.dateComponents([.year], from: now)) else { return 0 }
            let billingFrom = max(jan1, item.effectiveStartDate)
            let billingTo = billingEndDate(for: item, cap: now)
            guard billingFrom < billingTo else { return 0 }
            let days = cal.dateComponents([.day], from: billingFrom, to: billingTo).day ?? 0
            return monthly * (Double(days) / 30.4375)
        case .lifetime:
            let billingFrom = item.effectiveStartDate
            let billingTo = billingEndDate(for: item, cap: now)
            guard billingFrom < billingTo else { return 0 }
            let days = cal.dateComponents([.day], from: billingFrom, to: billingTo).day ?? 0
            return monthly * (Double(days) / 30.4375)
        }
    }

    /// Period-based list, before any donut-segment filter — this is what the donut itself
    /// sums, so a tapped segment's amount always matches what filtering reveals below it.
    private var costBreakdownBaseItems: [SubscriptionItem] {
        switch costPeriod {
        case .monthly, .annual:
            return activeItems.filter(\.contributesToCurrentRecurringSpend)
        case .ytd, .lifetime:
            return allItems.filter { $0.itemType == .subscription }
        }
    }

    private var costBreakdownItems: [SubscriptionItem] {
        guard let selectedCategory else { return costBreakdownBaseItems }
        return costBreakdownBaseItems.filter { ($0.category ?? .other) == selectedCategory }
    }

    private var costBreakdown: some View {
        let itemsWithCost = costBreakdownItems
            .filter { $0.monthlyCostConverted(to: preferredCurrency) != nil }
            .sorted { periodCost(for: $0) > periodCost(for: $1) }
        let maxCost = itemsWithCost.map { periodCost(for: $0) }.first ?? 1

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "list.number")
                    .font(.system(size: 11, weight: .bold))
                Text("BY COST")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                if let selectedCategory {
                    Spacer()
                    Button {
                        self.selectedCategory = nil
                    } label: {
                        HStack(spacing: 3) {
                            Text(selectedCategory.displayName)
                            Image(systemName: "xmark.circle.fill")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selectedCategory.chartColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(Array(itemsWithCost.enumerated()), id: \.element.id) { index, item in
                    CostBarRow(
                        item: item,
                        displayCost: periodCost(for: item),
                        displayCurrency: preferredCurrency,
                        maxCost: maxCost,
                        // Clamped: an unbounded index would push later rows past the end
                        // of the entrance driver and leave them permanently invisible.
                        progress: entrance.staggered(index: 8 + min(index, 2))
                    )
                }
            }
            .animation(.smooth(duration: 0.45), value: costPeriod)
        }
        .padding(.horizontal)
    }
}

/// Compact AutoSleep-style stat tile: tinted icon chip, big value, small label,
/// subtle color-tinted background. Sized for a dense 3-column grid.
struct CompactInsightTile: View {
    /// Numeric rather than pre-formatted, so the tile can tween between two values when
    /// the period changes instead of swapping one static string for another.
    enum Value {
        case currency(Double, code: String)
        case count(Int)
    }

    let title: String
    let value: Value
    let icon: String
    let color: Color
    /// 0→1 staggered entrance progress. Also scales the value up from zero.
    var progress: Double = 1

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            Group {
                switch value {
                case .currency(let amount, let code):
                    AnimatedCurrencyText(value: amount * progress, currencyCode: code)
                case .count(let count):
                    AnimatedCountText(value: Double(count) * progress)
                }
            }
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(color.opacity(0.10), lineWidth: 1)
        )
        .insightsEntrance(progress)
    }
}

struct CostBarRow: View {
    let item: SubscriptionItem
    let displayCost: Double
    let displayCurrency: String
    let maxCost: Double
    /// 0→1 staggered entrance progress; also grows the bar out from the left.
    var progress: Double = 1

    var body: some View {
        HStack(spacing: 12) {
            ItemIconView(item: item, size: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    AnimatedCurrencyText(value: displayCost * progress, currencyCode: displayCurrency)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    let fraction = maxCost > 0 ? max(0, min(1, displayCost / maxCost)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.blue.opacity(0.12)).frame(width: geo.size.width)
                        Capsule().fill(
                            LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width * fraction * progress)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(in: .rect(cornerRadius: 16))
        .opacity(progress)
        .offset(y: (1 - progress) * 10)
    }
}

// MARK: - Archive View

struct ArchiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<SubscriptionItem> { $0.isArchived },
           sort: \SubscriptionItem.updatedAt, order: .reverse)
    private var archivedItems: [SubscriptionItem]

    @State private var editingItem: SubscriptionItem?
    @State private var searchText = ""

    private var visibleItems: [SubscriptionItem] {
        guard !searchText.isEmpty else { return archivedItems }
        return archivedItems.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.provider.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if archivedItems.isEmpty {
                    ContentUnavailableView(
                        "No Archived Items",
                        systemImage: "archivebox",
                        description: Text("Swipe left on any subscription to archive it.")
                    )
                } else if visibleItems.isEmpty {
                    ContentUnavailableView.search
                } else {
                    archiveList
                }
            }
            .navigationTitle("Archive")
            .largeNavigationTitle()
#if os(iOS)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search archive")
#endif
            .sheet(item: $editingItem) { AddEditSubscriptionView(item: $0) }
        }
    }

    private var archiveList: some View {
        List {
            Section {
                ForEach(visibleItems) { item in
                    SubscriptionRowView(item: item)
                        .onTapGesture { editingItem = item }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Haptics.fire(.error)
                                modelContext.delete(item)
                                try? modelContext.save()
                                let ctx = modelContext
                                Task { await NotificationManager.shared.refreshAll(context: ctx) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Haptics.fire(.success)
                                withAnimation {
                                    item.isArchived = false
                                    item.updatedAt = Date()
                                    try? modelContext.save()
                                }
                                let ctx = modelContext
                                Task { await NotificationManager.shared.refreshAll(context: ctx) }
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.left")
                            }
                            .tint(.green)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            } header: {
                Text("\(visibleItems.count) item\(visibleItems.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                    .textCase(nil)
                    .padding(.top, 4)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(groupedBackground.ignoresSafeArea())
    }
}

// MARK: - Scheduled Notifications View

/// Reliability preview + debugger: shows the computed upcoming notifications grouped by day,
/// and a validation row comparing the computed count against what iOS actually has pending.
struct ScheduledNotificationsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [SubscriptionItem]

    @State private var moments: [FireMoment] = []
    @State private var pendingCount: Int = 0

    private var capped: [FireMoment] {
        Array(moments.sorted { $0.fireDate < $1.fireDate }.prefix(NotificationManager.scheduleCap))
    }

    private var grouped: [(day: Date, moments: [FireMoment])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: capped) { cal.startOfDay(for: $0.fireDate) }
        return byDay.keys.sorted().map { ($0, byDay[$0]!.sorted { $0.fireDate < $1.fireDate }) }
    }

    var body: some View {
        List {
            Section {
                validationRow
            }

            ForEach(grouped, id: \.day) { group in
                Section {
                    ForEach(group.moments) { moment in
                        HStack(spacing: 10) {
                            Image(systemName: moment.itemType.icon)
                                .font(.system(size: 15))
                                .frame(width: 22, alignment: .center)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(moment.itemName)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.primary)
                                Text(moment.fireDate.formatted(.dateTime.hour().minute()))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if moment.isCritical {
                                Image(systemName: "bell.badge.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } header: {
                    Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)
                        .textCase(nil)
                }
            }

            if capped.isEmpty {
                Section {
                    Text("No upcoming reminders scheduled.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
        .scrollContentBackground(.hidden)
        .background(groupedBackground.ignoresSafeArea())
        .navigationTitle("Scheduled")
        .largeNavigationTitle()
        .task { await reload() }
    }

    @ViewBuilder
    private var validationRow: some View {
        let computed = capped.count
        let matches = computed == pendingCount
        HStack(spacing: 10) {
            Image(systemName: matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(matches ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(matches ? "Schedule in sync" : "Schedule mismatch")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(computed) computed · \(pendingCount) pending with iOS")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Haptics.fire(.light)
                Task {
                    await NotificationManager.shared.refreshAll(context: modelContext)
                    await reload()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private func reload() async {
        moments = NotificationManager.shared.computeAllFireMoments(items: allItems)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        pendingCount = pending.filter { $0.identifier.hasPrefix(NotificationManager.identifierPrefix) }.count
    }
}

// MARK: - Categories View

/// Unified item type for the merged built-in + custom categories list.
private enum CategoryListItem: Identifiable {
    case builtIn(SubscriptionCategory)
    case custom(UserCategory)

    var id: String {
        switch self {
        case .builtIn(let c): return "builtin-\(c.rawValue)"
        case .custom(let c):  return "custom-\(c.id.uuidString)"
        }
    }
}

struct CategoriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PurchaseManager.self) private var purchaseManager
    @State private var showPaywall = false
    @Query(filter: #Predicate<SubscriptionItem> { !$0.isArchived && $0.itemTypeRaw == "subscription" })
    private var allSubscriptions: [SubscriptionItem]

    // Built-in visibility
    @State private var hiddenBuiltIn: Set<String> = BuiltInCategoryStore.hiddenRawValues()

    // Unified ordered list (built-in + custom interleaved) — populated in onAppear
    @State private var unifiedCategories: [CategoryListItem] = []

    // Custom categories sheet state
    @State private var showingAdd = false
    @State private var editingCategory: UserCategory? = nil
    @State private var newCategoryName = ""
    @State private var newCategoryIcon = UserCategory.defaultIcon
    @State private var newCategoryDescription = ""

    // Edit mode for reordering (iOS)
    @State private var isEditing = false

    private func count(rawName: String) -> Int {
        allSubscriptions.filter { $0.categoryRaw == rawName }.count
    }

    /// Reassigns every item pointing at a custom category to `newName` (or clears it when nil).
    /// Fetches directly from the context — `allSubscriptions` excludes archived/document items,
    /// which must also be reassigned so a deleted/renamed category can't strand them.
    private func reassignItems(named oldName: String, to newName: String?) {
        let target: String? = oldName
        let descriptor = FetchDescriptor<SubscriptionItem>(
            predicate: #Predicate { $0.categoryRaw == target }
        )
        guard let matches = try? modelContext.fetch(descriptor), !matches.isEmpty else { return }
        for item in matches {
            item.categoryRaw = newName
            item.updatedAt = Date()
        }
        try? modelContext.save()
    }

    /// Build the unified list, respecting the saved interleaved order when available.
    private func buildUnified() -> [CategoryListItem] {
        let builtInMap: [String: SubscriptionCategory] = Dictionary(
            uniqueKeysWithValues: SubscriptionCategory.allCases.map { ($0.rawValue, $0) }
        )
        let customMap: [String: UserCategory] = Dictionary(
            uniqueKeysWithValues: UserCategoryStore.load().map { ($0.id.uuidString, $0) }
        )

        // If a unified order was saved, reconstruct from it
        if let tags = BuiltInCategoryStore.loadUnifiedOrder(), !tags.isEmpty {
            var result: [CategoryListItem] = []
            for tag in tags {
                if tag.hasPrefix("builtin:") {
                    let raw = String(tag.dropFirst(8))
                    if let cat = builtInMap[raw] { result.append(.builtIn(cat)) }
                } else if tag.hasPrefix("custom:") {
                    let uuid = String(tag.dropFirst(7))
                    if let cat = customMap[uuid] { result.append(.custom(cat)) }
                }
            }
            // Append any new built-ins not yet in the saved list
            let seenBuiltIns = Set(result.compactMap { if case .builtIn(let c) = $0 { return c.rawValue } else { return nil } })
            for cat in BuiltInCategoryStore.allOrdered() where !seenBuiltIns.contains(cat.rawValue) {
                result.append(.builtIn(cat))
            }
            // Append any new custom categories not yet in the saved list
            let seenCustoms = Set(result.compactMap { if case .custom(let c) = $0 { return c.id.uuidString } else { return nil } })
            for cat in UserCategoryStore.load() where !seenCustoms.contains(cat.id.uuidString) {
                result.append(.custom(cat))
            }
            return result
        }

        // First-launch fallback: built-ins first, then customs
        let builtIns = BuiltInCategoryStore.allOrdered().map { CategoryListItem.builtIn($0) }
        let customs  = UserCategoryStore.load().map { CategoryListItem.custom($0) }
        return builtIns + customs
    }

    /// Persist the current unified order (interleaved tags + separate stores).
    private func saveUnified() {
        // Save the interleaved tag sequence so the exact position survives navigation
        let tags: [String] = unifiedCategories.map { item in
            switch item {
            case .builtIn(let c): return "builtin:\(c.rawValue)"
            case .custom(let c):  return "custom:\(c.id.uuidString)"
            }
        }
        BuiltInCategoryStore.saveUnifiedOrder(tags)

        // Also keep the separate stores up to date (used elsewhere in the app)
        let builtInOrder = unifiedCategories.compactMap { if case .builtIn(let c) = $0 { return c.rawValue } else { return nil } }
        let customItems  = unifiedCategories.compactMap { if case .custom(let c) = $0 { return c } else { return nil } }
        BuiltInCategoryStore.saveOrder(builtInOrder)
        UserCategoryStore.save(customItems)
    }

    var body: some View {
        platformBody
            .expiredPaywallSheet(isPresented: $showPaywall)
    }

    @ViewBuilder
    private var platformBody: some View {
#if os(iOS)
        iOSBody
#else
        macOSBody
#endif
    }

    /// Custom categories are a Pro feature; a free user gets the paywall instead of the editor.
    private func beginAddCategory() {
        guard purchaseManager.isPremium else {
            Haptics.fire(.warning)
            showPaywall = true
            return
        }
        Haptics.fire(.light)
        newCategoryName = ""
        newCategoryIcon = UserCategory.defaultIcon
        newCategoryDescription = ""
        editingCategory = nil
        showingAdd = true
    }

#if os(iOS)
    // MARK: iOS body — List is the root scroll container

    private var iOSBody: some View {
        List {
            Section {
                ForEach(unifiedCategories) { item in
                    Group {
                        switch item {
                        case .builtIn(let cat):
                            builtInRow(cat)
                        case .custom(let cat):
                            customCategoryRow(cat)
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                .onMove { from, to in
                    Haptics.fire(.light)
                    unifiedCategories.move(fromOffsets: from, toOffset: to)
                    saveUnified()
                }
                .onDelete { offsets in
                    // Only delete custom rows; ignore built-in deletions
                    let toRemove = offsets.filter {
                        if case .custom = unifiedCategories[$0] { return true }
                        return false
                    }
                    guard !toRemove.isEmpty else { return }
                    // Clear the category off any items that referenced it before removing.
                    for i in toRemove {
                        if case .custom(let c) = unifiedCategories[i] {
                            reassignItems(named: c.name, to: nil)
                        }
                    }
                    Haptics.fire(.error)
                    unifiedCategories.remove(atOffsets: IndexSet(toRemove))
                    saveUnified()
                }
            }

            Section {
                Button {
                    beginAddCategory()
                } label: {
                    Label("Add Category", systemImage: purchaseManager.isPremium ? "plus.circle.fill" : "lock.fill")
                        .foregroundStyle(.blue)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(groupedBackground.ignoresSafeArea())
        .navigationTitle("Categories")
        .largeNavigationTitle()
        .environment(\.editMode, isEditing ? .constant(.active) : .constant(.inactive))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Done" : "Edit") {
                    Haptics.fire(.selectionChanged)
                    withAnimation { isEditing.toggle() }
                }
                .fontWeight(isEditing ? .semibold : .regular)
            }
        }
        .onAppear {
            hiddenBuiltIn = BuiltInCategoryStore.hiddenRawValues()
            // Only rebuild from disk on first load; preserve in-memory ordering after that
            // so user drag positions aren't lost when navigating away and back
            if unifiedCategories.isEmpty {
                unifiedCategories = buildUnified()
            }
        }
        .sheet(isPresented: $showingAdd, onDismiss: { editingCategory = nil }) {
            CategoryEditSheet(
                name: $newCategoryName,
                icon: $newCategoryIcon,
                description: $newCategoryDescription,
                title: editingCategory == nil ? "Add Category" : "Edit Category"
            ) {
                withTransaction(Transaction(animation: nil)) {
                    if let editing = editingCategory,
                       let idx = unifiedCategories.firstIndex(where: {
                           if case .custom(let c) = $0 { return c.id == editing.id }
                           return false
                       }) {
                        let updated = UserCategory(
                            id: editing.id,
                            name: newCategoryName,
                            icon: newCategoryIcon,
                            description: newCategoryDescription.isEmpty ? nil : newCategoryDescription
                        )
                        // A rename must follow through to items that reference the old name.
                        if editing.name != newCategoryName {
                            reassignItems(named: editing.name, to: newCategoryName)
                        }
                        unifiedCategories[idx] = .custom(updated)
                    } else {
                        unifiedCategories.append(.custom(UserCategory(
                            name: newCategoryName,
                            icon: newCategoryIcon,
                            description: newCategoryDescription.isEmpty ? nil : newCategoryDescription
                        )))
                    }
                }
                saveUnified()
            }
        }
        .onChange(of: editingCategory) { _, cat in
            if cat != nil { showingAdd = true }
        }
    }
#else
    // MARK: macOS body

    private var macOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                builtInSection
                customSection
            }
            .padding(16)
        }
        .background(groupedBackground.ignoresSafeArea())
        .navigationTitle("Categories")
        .largeNavigationTitle()
        .onAppear {
            hiddenBuiltIn = BuiltInCategoryStore.hiddenRawValues()
            unifiedCategories = buildUnified()
        }
        .sheet(isPresented: $showingAdd, onDismiss: { editingCategory = nil }) {
            CategoryEditSheet(
                name: $newCategoryName,
                icon: $newCategoryIcon,
                description: $newCategoryDescription,
                title: editingCategory == nil ? "Add Category" : "Edit Category"
            ) {
                withTransaction(Transaction(animation: nil)) {
                    if let editing = editingCategory,
                       let idx = unifiedCategories.firstIndex(where: {
                           if case .custom(let c) = $0 { return c.id == editing.id }
                           return false
                       }) {
                        let updated = UserCategory(
                            id: editing.id,
                            name: newCategoryName,
                            icon: newCategoryIcon,
                            description: newCategoryDescription.isEmpty ? nil : newCategoryDescription
                        )
                        // A rename must follow through to items that reference the old name.
                        if editing.name != newCategoryName {
                            reassignItems(named: editing.name, to: newCategoryName)
                        }
                        unifiedCategories[idx] = .custom(updated)
                    } else {
                        unifiedCategories.append(.custom(UserCategory(
                            name: newCategoryName,
                            icon: newCategoryIcon,
                            description: newCategoryDescription.isEmpty ? nil : newCategoryDescription
                        )))
                    }
                }
                saveUnified()
            }
        }
        .onChange(of: editingCategory) { _, cat in
            if cat != nil { showingAdd = true }
        }
    }
#endif

    // MARK: Built-in Section (macOS + helper for iOS row)

    @ViewBuilder
    private func builtInRow(_ cat: SubscriptionCategory) -> some View {
        let isHidden = hiddenBuiltIn.contains(cat.rawValue)
        HStack(spacing: 12) {
            Image(systemName: cat.icon)
                .font(.system(size: 16))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(isHidden ? .tertiary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.displayName)
                    .font(.system(size: 16))
                    .foregroundStyle(isHidden ? .secondary : .primary)
                Text(cat.examples)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            let n = count(rawName: cat.rawValue)
            if n > 0 {
                Text("\(n)")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            // Visibility toggle
            Button {
                Haptics.fire(.light)
                withAnimation {
                    if isHidden {
                        hiddenBuiltIn.remove(cat.rawValue)
                    } else {
                        hiddenBuiltIn.insert(cat.rawValue)
                    }
                    BuiltInCategoryStore.setHidden(cat.rawValue, hidden: !isHidden)
                }
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 16))
                    .foregroundStyle(isHidden ? Color.secondary.opacity(0.4) : Color.blue)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
    }

#if os(macOS)
    @ViewBuilder
    private func builtInRow(_ cat: SubscriptionCategory, index: Int, total: Int) -> some View {
        let isHidden = hiddenBuiltIn.contains(cat.rawValue)
        HStack(spacing: 12) {
            Image(systemName: cat.icon)
                .font(.system(size: 16))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(isHidden ? .tertiary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.displayName)
                    .font(.system(size: 16))
                    .foregroundStyle(isHidden ? .secondary : .primary)
                Text(cat.examples)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            let n = count(rawName: cat.rawValue)
            if n > 0 {
                Text("\(n)")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            // Up/down reorder buttons (moves within the unified list)
            VStack(spacing: 2) {
                Button {
                    guard index > 0 else { return }
                    Haptics.fire(.light)
                    // Find this item's index in the unified list and move up
                    if let uIdx = unifiedCategories.firstIndex(where: {
                        if case .builtIn(let c) = $0 { return c.rawValue == cat.rawValue }
                        return false
                    }), uIdx > 0 {
                        unifiedCategories.move(fromOffsets: IndexSet(integer: uIdx), toOffset: uIdx - 1)
                        saveUnified()
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == 0 ? Color.secondary.opacity(0.3) : Color.secondary)
                .disabled(index == 0)

                Button {
                    guard index < total - 1 else { return }
                    Haptics.fire(.light)
                    if let uIdx = unifiedCategories.firstIndex(where: {
                        if case .builtIn(let c) = $0 { return c.rawValue == cat.rawValue }
                        return false
                    }), uIdx < unifiedCategories.count - 1 {
                        unifiedCategories.move(fromOffsets: IndexSet(integer: uIdx), toOffset: uIdx + 2)
                        saveUnified()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == total - 1 ? Color.secondary.opacity(0.3) : Color.secondary)
                .disabled(index == total - 1)
            }
            .padding(.leading, 4)

            // Visibility toggle
            Button {
                Haptics.fire(.light)
                withAnimation {
                    let isHidden = hiddenBuiltIn.contains(cat.rawValue)
                    if isHidden {
                        hiddenBuiltIn.remove(cat.rawValue)
                    } else {
                        hiddenBuiltIn.insert(cat.rawValue)
                    }
                    BuiltInCategoryStore.setHidden(cat.rawValue, hidden: !isHidden)
                }
            } label: {
                Image(systemName: hiddenBuiltIn.contains(cat.rawValue) ? "eye.slash" : "eye")
                    .font(.system(size: 16))
                    .foregroundStyle(hiddenBuiltIn.contains(cat.rawValue) ? Color.secondary.opacity(0.4) : Color.blue)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
#endif

#if os(macOS)
    // MARK: macOS Sections

    @ViewBuilder
    private var builtInSection: some View {
        let orderedBuiltIn = unifiedCategories.compactMap { if case .builtIn(let c) = $0 { return c } else { return nil } }
        categoriesSection(title: "Built-in", icon: "square.grid.2x2") {
            ForEach(Array(orderedBuiltIn.enumerated()), id: \.element.rawValue) { idx, cat in
                builtInRow(cat, index: idx, total: orderedBuiltIn.count)
                if idx < orderedBuiltIn.count - 1 {
                    FormDivider()
                }
            }
        }
    }

    @ViewBuilder
    private var customSection: some View {
        let customItems = unifiedCategories.compactMap { if case .custom(let c) = $0 { return c } else { return nil } }
        categoriesSection(title: "Custom", icon: "tag") {
            if customItems.isEmpty {
                Text("No custom categories yet")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                ForEach(customItems) { cat in
                    customCategoryRow(cat)
                    if cat.id != customItems.last?.id {
                        FormDivider()
                    }
                }
            }
            FormDivider()
            Button {
                beginAddCategory()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: purchaseManager.isPremium ? "plus.circle.fill" : "lock.fill")
                        .font(.system(size: 16))
                        .frame(width: 22, alignment: .center)
                    Text("Add Category")
                        .font(.system(size: 16))
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
#endif

    @ViewBuilder
    private func customCategoryRow(_ cat: UserCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: cat.icon)
                .font(.system(size: 16))
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.name)
                    .font(.system(size: 16))
                if let desc = cat.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            let n = count(rawName: cat.name)
            if n > 0 {
                Text("\(n)")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            Button {
                Haptics.fire(.light)
                newCategoryName = cat.name
                newCategoryIcon = cat.icon
                newCategoryDescription = cat.description ?? ""
                editingCategory = cat
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.blue.opacity(0.8))
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            Button {
                Haptics.fire(.light)
                withAnimation {
                    reassignItems(named: cat.name, to: nil)
                    unifiedCategories.removeAll {
                        if case .custom(let c) = $0 { return c.id == cat.id }
                        return false
                    }
                    saveUnified()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
    }

    @ViewBuilder
    private func categoriesSectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func categoriesSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            categoriesSectionHeader(title: title, icon: icon)
            VStack(spacing: 0) {
                content()
            }
            .glassEffect(in: .rect(cornerRadius: 20))
        }
    }
}

struct CategoryEditSheet: View {
    @Binding var name: String
    @Binding var icon: String
    @Binding var description: String
    let title: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    // A curated set of icons the user can pick for a custom category
    private let iconOptions: [(String, String)] = [
        ("tag", "Tag"),
        ("star.fill", "Star"),
        ("heart.fill", "Health"),
        ("bolt.fill", "Power"),
        ("house.fill", "Home"),
        ("car.fill", "Transport"),
        ("airplane", "Travel"),
        ("fork.knife", "Food"),
        ("book.fill", "Education"),
        ("dumbbell.fill", "Sport"),
        ("pawprint.fill", "Pets"),
        ("leaf.fill", "Nature"),
        ("person.fill", "Personal"),
        ("briefcase.fill", "Work"),
        ("camera.fill", "Photo"),
        ("gamecontroller.fill", "Gaming"),
        ("music.note", "Music"),
        ("tv.fill", "TV"),
        ("cloud.fill", "Cloud"),
        ("lock.fill", "Security"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Category name", text: $name)
                        .autocorrectionDisabled()
                }
                Section("Description") {
                    TextField("Optional — e.g. Work tools, Side projects…", text: $description)
                        .autocorrectionDisabled()
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
                        ForEach(iconOptions, id: \.0) { iconName, _ in
                            Button {
                                Haptics.fire(.selectionChanged)
                                icon = iconName
                            } label: {
                                Image(systemName: iconName)
                                    .font(.system(size: 22))
                                    .frame(width: 48, height: 48)
                                    .foregroundStyle(icon == iconName ? .white : .primary)
                                    .background(
                                        icon == iconName ? Color.blue : Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.fire(.light)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.fire(.success)
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Cross-platform helpers (shared across files)

var groupedBackground: Color {
#if os(iOS)
    Color(uiColor: .systemGroupedBackground)
#else
    Color(nsColor: .windowBackgroundColor)
#endif
}

extension View {
    func largeNavigationTitle() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.large)
#else
        self
#endif
    }

    func inlineNavigationTitle() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    func trailingTextAlignment() -> some View {
#if os(iOS)
        self.multilineTextAlignment(.trailing)
#else
        self
#endif
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PurchaseManager.self) private var purchaseManager
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true
    @AppStorage(ServicePopularityReporter.sharingEnabledKey) private var shareServicePopularity = true
    @AppStorage("preferredCurrency") private var preferredCurrency = SettingsView.localeCurrencyCode
    @AppStorage("appStoreRegion") private var appStoreRegion = "auto"
    @AppStorage(ScreenshotAISettings.providerKey) private var screenshotAIProviderRaw = ScreenshotAIProvider.automatic.rawValue
    /// Live model picker state. `selectedModels` mirrors the chosen model per
    /// provider; `availableModels` is the last fetched list for the current provider.
    @State private var selectedModels: [String: String] = [:]
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    /// Device-local only (never synced) — persists the revealed state across
    /// navigation per `_shared/settings-conventions.md`'s "Hidden debug section".
    @AppStorage("debugSectionRevealed") private var debugSectionRevealed = false
    @State private var showVersionCopiedToast = false
    @AppStorage("appearanceMode") private var appearanceMode = 0
    @AppStorage("notificationHour")   private var notificationHour: Int = 9
    @AppStorage("notificationMinute") private var notificationMinute: Int = 0
    @AppStorage("quietHoursEnabled") private var quietHoursEnabled = false
    @AppStorage("quietHoursStartMinutes") private var quietStartMinutes: Int = 22 * 60
    @AppStorage("quietHoursEndMinutes")   private var quietEndMinutes: Int = 8 * 60
    @State private var showRestartAlert = false
    @State private var showCurrencyPicker = false
    @State private var isSyncing = false
    @State private var isRefreshingFavicons = false
    @State private var faviconRefreshProgress: (done: Int, total: Int) = (0, 0)
    @State private var showExportWarning = false
    @State private var showPaywall = false
    @State private var showCustomerCenter = false
    @State private var showingExporter = false
    @State private var exportDocument: BackupDocument?
    @State private var showingImporter = false
    @State private var importResultMessage: String?
    @State private var backupErrorMessage: String?
    @AppStorage(BackupService.autoBackupEnabledKey) private var autoBackupEnabled = true
    @AppStorage(BackupService.lastAutoBackupKey) private var lastAutoBackupAt: Double = 0
    @Query(filter: #Predicate<SubscriptionItem> { $0.isArchived }) private var archivedItems: [SubscriptionItem]
    @Query private var allItems: [SubscriptionItem]

    private static let kvHourKey   = "notificationHour"
    private static let kvMinuteKey = "notificationMinute"

    /// A Date representing the stored notification hour/minute (today's date at that time).
    private var notificationTime: Date {
        Calendar.current.date(
            bySettingHour: notificationHour, minute: notificationMinute, second: 0,
            of: Date()
        ) ?? Date()
    }

    private func date(fromMinutes minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    private func minutes(from date: Date) -> Int {
        let snapped = QuarterHourTimePicker.snap(date)
        let c = Calendar.current.dateComponents([.hour, .minute], from: snapped)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Binding for the quiet-hours start time. Writes through both stores + refreshes.
    private var quietStartBinding: Binding<Date> {
        Binding(
            get: { date(fromMinutes: quietStartMinutes) },
            set: { newDate in
                quietStartMinutes = minutes(from: newDate)
                NotificationTimeSettings.writeInt(quietStartMinutes, forKey: NotificationTimeSettings.quietStartKey)
                Task { await NotificationManager.shared.refreshAll(context: modelContext) }
            }
        )
    }

    private var quietEndBinding: Binding<Date> {
        Binding(
            get: { date(fromMinutes: quietEndMinutes) },
            set: { newDate in
                quietEndMinutes = minutes(from: newDate)
                NotificationTimeSettings.writeInt(quietEndMinutes, forKey: NotificationTimeSettings.quietEndKey)
                Task { await NotificationManager.shared.refreshAll(context: modelContext) }
            }
        )
    }

    private func setQuietHoursEnabled(_ on: Bool) {
        Haptics.fire(.selectionChanged)
        quietHoursEnabled = on
        NotificationTimeSettings.writeBool(on, forKey: NotificationTimeSettings.quietEnabledKey)
        Task { await NotificationManager.shared.refreshAll(context: modelContext) }
    }

    /// Writes notification time to both @AppStorage (local) and iCloud KV store (cross-device),
    /// via the shared settings accessor so every read path (including background refreshes) agrees.
    private func saveNotificationTime(_ date: Date) {
        // Snap to 15-minute intervals for parity with the per-rule/per-item pickers.
        let snapped = QuarterHourTimePicker.snap(date)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: snapped)
        let hour   = comps.hour   ?? 9
        let minute = comps.minute ?? 0
        let changed = notificationHour != hour || notificationMinute != minute
        notificationHour   = hour
        notificationMinute = minute
        NotificationTimeSettings.writeInt(hour, forKey: NotificationTimeSettings.hourKey)
        NotificationTimeSettings.writeInt(minute, forKey: NotificationTimeSettings.minuteKey)
        if changed {
            Task { await NotificationManager.shared.refreshAll(context: modelContext) }
        }
    }

    /// Pulls the notification time from iCloud KV store into @AppStorage.
    private func pullNotificationTimeFromKVStore() {
        let kv = NSUbiquitousKeyValueStore.default
        guard kv.object(forKey: Self.kvHourKey) != nil else { return }
        let hour = Int(kv.longLong(forKey: Self.kvHourKey))
        let minute = Int(kv.longLong(forKey: Self.kvMinuteKey))
        let changed = notificationHour != hour || notificationMinute != minute
        notificationHour = hour
        notificationMinute = minute
        if changed {
            Task { await NotificationManager.shared.refreshAll(context: modelContext) }
        }
    }

    /// Best-guess currency from the device locale, falling back to USD.
    static var localeCurrencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    private static let appStoreRegions: [(code: String, name: String)] = [
        ("auto", "Automatic"),
        ("us", "United States"),
        ("gb", "United Kingdom"),
        ("au", "Australia"),
        ("ca", "Canada"),
        ("nz", "New Zealand"),
        ("ie", "Ireland"),
        ("de", "Germany"),
        ("fr", "France"),
        ("es", "Spain"),
        ("it", "Italy"),
        ("nl", "Netherlands"),
        ("se", "Sweden"),
        ("no", "Norway"),
        ("dk", "Denmark"),
        ("fi", "Finland"),
        ("jp", "Japan"),
        ("kr", "South Korea"),
        ("cn", "China"),
        ("hk", "Hong Kong"),
        ("sg", "Singapore"),
        ("in", "India"),
        ("br", "Brazil"),
        ("mx", "Mexico"),
        ("za", "South Africa")
    ]

    private var appStoreRegionLabel: String {
        if appStoreRegion == "auto" {
            let deviceRegion = Locale.current.region?.identifier.uppercased() ?? "US"
            return "Automatic (\(deviceRegion))"
        }
        let code = appStoreRegion.lowercased()
        let name = Self.appStoreRegions.first(where: { $0.code == code })?.name ?? code.uppercased()
        return "\(name) (\(code.uppercased()))"
    }

    private var screenshotAIProvider: ScreenshotAIProvider {
        get { ScreenshotAIProvider(rawValue: screenshotAIProviderRaw) ?? .automatic }
        nonmutating set { screenshotAIProviderRaw = newValue.rawValue }
    }

    private var displayedScreenshotAIProviderName: String {
        purchaseManager.isPremium ? screenshotAIProvider.displayName : ScreenshotAIProvider.automatic.displayName
    }

    // MARK: - Live model picker

    private var currentSelectedModel: String {
        selectedModels[screenshotAIProvider.rawValue] ?? screenshotAIProvider.selectedModelID
    }

    /// Picker options: live-fetched ∪ current selection ∪ hardcoded default, so a
    /// tag always exists for the current value even before a successful fetch.
    private var modelPickerOptions: [String] {
        var set = Set(availableModels)
        set.insert(currentSelectedModel)
        set.insert(screenshotAIProvider.defaultModelID)
        return set.filter { !$0.isEmpty }.sorted()
    }

    private func modelLabel(_ model: String) -> String {
        model == screenshotAIProvider.defaultModelID ? "\(model) (default)" : model
    }

    private func setSelectedModel(_ model: String) {
        screenshotAIProvider.setSelectedModelID(model)
        withTransaction(Transaction(animation: nil)) {
            selectedModels[screenshotAIProvider.rawValue] = screenshotAIProvider.selectedModelID
        }
    }

    private func loadSelectedModels() {
        var dict: [String: String] = [:]
        for provider in ScreenshotAIProvider.allCases where provider.requiresAPIKey {
            dict[provider.rawValue] = provider.selectedModelID
        }
        selectedModels = dict
    }

    /// Fetches the live model list for the current provider via the Supabase `models`
    /// function (server holds the key). Guards against a stale response landing after
    /// the user has switched provider.
    private func loadModels() {
        availableModels = []
        modelLoadError = nil
        let provider = screenshotAIProvider
        guard provider.requiresAPIKey else { return }
        isLoadingModels = true
        Task {
            do {
                let models = try await ScreenshotAIModelService.listModels(provider: provider)
                await MainActor.run {
                    guard screenshotAIProvider == provider else { return }
                    availableModels = models
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    guard screenshotAIProvider == provider else { return }
                    modelLoadError = error.localizedDescription
                    isLoadingModels = false
                }
            }
        }
    }

    /// Shared note + error shown under the model picker on both platforms.
    @ViewBuilder
    private var modelPickerNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let modelLoadError {
                Text(modelLoadError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Models load live from the server. A server-side default is planned — this picker is a stopgap.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        NavigationStack {
#if os(macOS)
            macSettingsBody
#else
            iosSettingsBody
#endif
        }
        .onAppear {
            NSUbiquitousKeyValueStore.default.synchronize()
            pullNotificationTimeFromKVStore()
            loadSelectedModels()
            loadModels()
        }
        .onChange(of: screenshotAIProviderRaw) { _, _ in
            loadModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { note in
            guard let keys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) else { return }
            if keys.contains(Self.kvHourKey) || keys.contains(Self.kvMinuteKey) {
                pullNotificationTimeFromKVStore()
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Expired Backup"
        ) { _ in
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { handleImport($0) }
        .alert("Export Backup", isPresented: $showExportWarning) {
            Button("Continue") { prepareExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This backup is not encrypted and includes account emails, usernames, and passwords. Only save it somewhere private.")
        }
        .alert("Import Complete", isPresented: Binding(
            get: { importResultMessage != nil },
            set: { if !$0 { importResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importResultMessage ?? "")
        }
        .alert("Backup Error", isPresented: Binding(
            get: { backupErrorMessage != nil },
            set: { if !$0 { backupErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupErrorMessage ?? "")
        }
        .expiredPaywallSheet(isPresented: $showPaywall)
        .expiredCustomerCenterSheet(isPresented: $showCustomerCenter)
    }

    /// Pro export is gated: a free user gets the paywall instead of the export warning.
    private func beginExport() {
        guard purchaseManager.isPremium else {
            Haptics.fire(.warning)
            showPaywall = true
            return
        }
        Haptics.fire(.light)
        showExportWarning = true
    }

    private func beginImportBackup() {
        guard purchaseManager.isPremium else {
            Haptics.fire(.warning)
            showPaywall = true
            return
        }
        Haptics.fire(.light)
        showingImporter = true
    }

    private func setScreenshotAIProvider(_ provider: ScreenshotAIProvider) {
        guard purchaseManager.isPremium else {
            Haptics.fire(.warning)
            showPaywall = true
            return
        }
        Haptics.fire(.selectionChanged)
        withTransaction(Transaction(animation: nil)) {
            screenshotAIProviderRaw = provider.rawValue
        }
    }

    // MARK: - Backup (export / import)

    private var lastAutoBackupText: String {
        guard lastAutoBackupAt > 0 else { return "No automatic backup yet" }
        let date = Date(timeIntervalSince1970: lastAutoBackupAt)
        return "Last backup \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func prepareExport() {
        do {
            let data = try BackupService.export(allItems)
            exportDocument = BackupDocument(data: data)
            Haptics.fire(.success)
            showingExporter = true
        } catch {
            Haptics.fire(.error)
            backupErrorMessage = "Could not create backup: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let url = try? result.get().first else { return }
        guard url.startAccessingSecurityScopedResource() else {
            Haptics.fire(.warning)
            backupErrorMessage = "Could not access the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let file = try BackupService.decode(data)
            let counts = BackupService.merge(file, into: modelContext, existing: allItems)
            importResultMessage = "Imported \(counts.added) new, updated \(counts.updated)."
            Haptics.fire(.success)
            Task { await NotificationManager.shared.refreshAll(context: modelContext) }
        } catch {
            Haptics.fire(.error)
            backupErrorMessage = "Could not read backup: \(error.localizedDescription)"
        }
    }

    // MARK: - macOS Settings (card layout matching iOS form style)

#if os(macOS)
    private var macSettingsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // DISPLAY
                settingsSection(title: "Display", icon: "paintbrush") {
                    Button {
                        Haptics.fire(.light)
                        showCurrencyPicker = true
                    } label: {
                        settingsRow {
                            macSettingsLabel("Currency", icon: "dollarsign.circle")
                            Spacer()
                            Text("\(CurrencyInfo.symbol(for: preferredCurrency)) \(preferredCurrency)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    FormDivider()

                    settingsRow {
                        macSettingsLabel("App Store", icon: "bag")
                        Spacer()
                        Menu {
                            ForEach(Self.appStoreRegions, id: \.code) { region in
                                Button {
                                    Haptics.fire(.selectionChanged)
                                    withTransaction(Transaction(animation: nil)) {
                                        appStoreRegion = region.code
                                    }
                                } label: {
                                    macMenuOptionTitle(region.name, isSelected: appStoreRegion == region.code)
                                }
                            }
                        } label: {
                            macMenuValueLabel(appStoreRegionLabel)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }

                    FormDivider()

                    settingsRow {
                        macSettingsLabel("Appearance", icon: "paintbrush")
                        Spacer()
                        Menu {
                            Button {
                                Haptics.fire(.selectionChanged)
                                withTransaction(Transaction(animation: nil)) {
                                    appearanceMode = 0
                                }
                            } label: {
                                macMenuOptionTitle("System", isSelected: appearanceMode == 0)
                            }
                            Button {
                                Haptics.fire(.selectionChanged)
                                withTransaction(Transaction(animation: nil)) {
                                    appearanceMode = 1
                                }
                            } label: {
                                macMenuOptionTitle("Light", isSelected: appearanceMode == 1)
                            }
                            Button {
                                Haptics.fire(.selectionChanged)
                                withTransaction(Transaction(animation: nil)) {
                                    appearanceMode = 2
                                }
                            } label: {
                                macMenuOptionTitle("Dark", isSelected: appearanceMode == 2)
                            }
                        } label: {
                            macMenuValueLabel(appearanceMode == 0 ? "System" : appearanceMode == 1 ? "Light" : "Dark")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }

                // EXPIRED PRO
                settingsSection(title: "Expired Pro", icon: "crown") {
                    if purchaseManager.isPremium {
                        settingsRow {
                            macSettingsLabel("Subscription", icon: "crown.fill")
                            Spacer()
                            Text("Active").foregroundStyle(.green)
                        }
                        FormDivider()
                        Button {
                            Haptics.fire(.light)
                            showCustomerCenter = true
                        } label: {
                            settingsRow {
                                macSettingsLabel("Manage Subscription", icon: "person.crop.circle")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            Haptics.fire(.light)
                            showPaywall = true
                        } label: {
                            settingsRow {
                                macSettingsLabel("Upgrade to Pro", icon: "crown.fill")
                                    .foregroundStyle(.blue)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        FormDivider()
                        Button {
                            Haptics.fire(.light)
                            showCustomerCenter = true
                        } label: {
                            settingsRow {
                                macSettingsLabel("Restore Purchases", icon: "arrow.clockwise")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // SCREENSHOT IMPORT
                settingsSection(title: "Screenshot Import", icon: "doc.viewfinder") {
                    settingsRow {
                        macSettingsLabel("Analyzer", icon: "sparkles")
                        if !purchaseManager.isPremium { ProChip() }
                        Spacer()
                        Menu {
                            ForEach(ScreenshotAIProvider.allCases) { provider in
                                Button {
                                    setScreenshotAIProvider(provider)
                                } label: {
                                    macMenuOptionTitle(provider.displayName, isSelected: screenshotAIProvider == provider)
                                }
                            }
                        } label: {
                            macMenuValueLabel(displayedScreenshotAIProviderName)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(!purchaseManager.isPremium)
                    }

                    if purchaseManager.isPremium && screenshotAIProvider.requiresAPIKey {
                        FormDivider()

                        settingsRow {
                            macSettingsLabel("Model", icon: "cpu")
                            Spacer()
                            if isLoadingModels {
                                ProgressView().controlSize(.small)
                            }
                            Menu {
                                ForEach(modelPickerOptions, id: \.self) { model in
                                    Button {
                                        Haptics.fire(.selectionChanged)
                                        setSelectedModel(model)
                                    } label: {
                                        macMenuOptionTitle(modelLabel(model), isSelected: currentSelectedModel == model)
                                    }
                                }
                            } label: {
                                macMenuValueLabel(modelLabel(currentSelectedModel))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            Button {
                                Haptics.fire(.light)
                                loadModels()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Refresh model list")
                        }

                        settingsRow {
                            modelPickerNote
                        }
                    }
                }

                // NOTIFICATIONS
                settingsSection(title: "Notifications", icon: "bell") {
                    settingsRow {
                        macSettingsLabel("Reminder", icon: "clock")
                        Spacer()
                        QuarterHourTimePicker(date: Binding(get: { notificationTime }, set: { saveNotificationTime($0) }))
                    }

                    FormDivider()

                    settingsRow {
                        macSettingsLabel("Quiet Hours", icon: "moon.fill")
                        Spacer()
                        Toggle("", isOn: Binding(get: { quietHoursEnabled }, set: { setQuietHoursEnabled($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(.blue)
                    }

                    if quietHoursEnabled {
                        FormDivider()
                        settingsRow {
                            macSettingsLabel("From", icon: "bed.double.fill")
                            Spacer()
                            QuarterHourTimePicker(date: quietStartBinding)
                        }
                        FormDivider()
                        settingsRow {
                            macSettingsLabel("To", icon: "sun.max.fill")
                            Spacer()
                            QuarterHourTimePicker(date: quietEndBinding)
                        }
                    }

                    FormDivider()

                    NavigationLink {
                        ScheduledNotificationsView()
                    } label: {
                        settingsRow {
                            macSettingsLabel("Scheduled Notifications", icon: "list.bullet.rectangle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // DATA
                settingsSection(title: "Data", icon: "folder") {
                    NavigationLink { ArchiveView() } label: {
                        settingsRow {
                            macSettingsLabel("Archive", icon: "archivebox")
                            Spacer()
                            if !archivedItems.isEmpty {
                                Text("\(archivedItems.count)")
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    FormDivider()

                    NavigationLink { CategoriesView() } label: {
                        settingsRow {
                            macSettingsLabel("Categories", icon: "square.grid.2x2")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    FormDivider()

                    Button {
                        Haptics.fire(.light)
                        refreshAllFavicons()
                    } label: {
                        settingsRow {
                            macSettingsLabel("Refresh Icons", icon: "arrow.clockwise.circle")
                                .foregroundStyle(isRefreshingFavicons ? Color.secondary : Color.blue)
                            Spacer()
                            if isRefreshingFavicons {
                                if faviconRefreshProgress.total > 0 {
                                    Text("\(faviconRefreshProgress.done)/\(faviconRefreshProgress.total)")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 13))
                                }
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshingFavicons)
                }

                // PRIVACY
                settingsSection(title: "Privacy", icon: "hand.raised") {
                    settingsRow {
                        macSettingsLabel("Share Subscription Usage", icon: "chart.bar")
                        Spacer()
                        Toggle("", isOn: $shareServicePopularity)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                            .onChange(of: shareServicePopularity) { _, _ in
                                Haptics.fire(.selectionChanged)
                            }
                    }
                }

                // BACKUP & SYNC
                settingsSection(title: "Backup & Sync", icon: "icloud") {
                    settingsRow {
                        macSettingsLabel("iCloud Sync", icon: "icloud")
                        Spacer()
                        Toggle("", isOn: $iCloudSyncEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                            .onChange(of: iCloudSyncEnabled) { _, _ in
                                Haptics.fire(.selectionChanged)
                                showRestartAlert = true
                            }
                    }

                    FormDivider()

                    Button {
                        guard !isSyncing else { return }
                        Haptics.fire(.light)
                        isSyncing = true
                        NotificationCenter.default.post(name: .expiredManualSync, object: nil)
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            isSyncing = false
                        }
                    } label: {
                        settingsRow {
                            macSettingsLabel("Sync Now", icon: isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise.icloud")
                            Spacer()
                            if isSyncing { ProgressView().controlSize(.small) }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!iCloudSyncEnabled || isSyncing)

                    FormDivider()

                    settingsRow {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.system(size: 15))
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud Backup")
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                            Text(lastAutoBackupText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $autoBackupEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                            .onChange(of: autoBackupEnabled) { _, _ in
                                Haptics.fire(.selectionChanged)
                            }
                    }

                    FormDivider()

                    Button { beginExport() } label: {
                        settingsRow {
                            macSettingsLabel("Export Backup", icon: "square.and.arrow.up")
                                .foregroundStyle(.blue)
                            ProChip()
                        }
                    }
                    .buttonStyle(.plain)

                    FormDivider()

                    Button { beginImportBackup() } label: {
                        settingsRow {
                            macSettingsLabel("Import Backup", icon: "square.and.arrow.down")
                                .foregroundStyle(.blue)
                            ProChip()
                        }
                    }
                    .buttonStyle(.plain)
                }

                versionFooterRow
                    .padding(.top, 4)

                if debugSectionRevealed {
                    DebugAIFailureSimulatorView(onHide: { debugSectionRevealed = false })
                }

                Spacer(minLength: 40)
            }
            .padding(24)
        }
        .background(groupedBackground.ignoresSafeArea())
        .navigationTitle("Settings")
        .currencyPickerPresentation(isPresented: $showCurrencyPicker, selectedCode: $preferredCurrency)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please restart the app for the iCloud sync change to take effect.")
        }
    }

    /// Consistent icon + label row element with fixed icon width for alignment.
    @ViewBuilder
    private func macSettingsLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 20, alignment: .center)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
        }
    }

    /// A card-style section with a small header pill and a `FormCard`-style glass container.
    private func settingsSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .glassEffect(in: .rect(cornerRadius: 20))
        }
    }

    /// A standard settings row with consistent padding.
    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
#endif

    /// Stable menu label used for settings pickers so the row width does not jitter while scrolling.
    @ViewBuilder
    private func macMenuValueLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .animation(nil, value: title)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Stable menu row content. macOS uses a fixed-width checkmark slot for alignment;
    /// iOS uses the standard Label/Text pattern so only the selected item shows a checkmark.
    @ViewBuilder
    private func macMenuOptionTitle(_ title: String, isSelected: Bool) -> some View {
#if os(macOS)
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14, alignment: .center)
                .foregroundStyle(isSelected ? Color.primary : Color.clear)
            Text(title)
        }
#else
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
#endif
    }

    // MARK: - iOS Settings (List-based)

    /// Fixed-width icon slot for iOS list rows — ensures all text starts at the same x position.
    @ViewBuilder
    private func rowIcon(_ name: String, color: Color = .secondary) -> some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .frame(width: 22, alignment: .center)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .textCase(nil)
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }

    // MARK: - Version footer / hidden debug entry

    private var versionBuildString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Expired \(version) (\(build))"
    }

    private func copyVersionString() {
        #if os(iOS)
        UIPasteboard.general.string = versionBuildString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(versionBuildString, forType: .string)
        #endif
        Haptics.fire(.light)
    }

    /// Tap copies the version string (for bug reports); a 4-second long-press (iOS)
    /// reveals the hidden Debug section. Never a visible affordance — see
    /// `_shared/settings-conventions.md` "Hidden debug section".
    private var versionFooterRow: some View {
        Text(versionBuildString)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            #if os(iOS)
            .onTapGesture { copyVersionString() }
            .onLongPressGesture(minimumDuration: 4.0) {
                Haptics.fire(.success)
                debugSectionRevealed = true
            }
            #elseif os(macOS)
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.option) {
                    Haptics.fire(.success)
                    debugSectionRevealed = true
                } else {
                    copyVersionString()
                }
            }
            #endif
    }

    private var iosSettingsBody: some View {
        List {

            // MARK: Display
            Section {
                Button {
                    Haptics.fire(.light)
                    showCurrencyPicker = true
                } label: {
                    HStack {
                        rowIcon("dollarsign.circle")
                        Text("Currency").foregroundStyle(.primary)
                        Spacer()
                        Text("\(CurrencyInfo.symbol(for: preferredCurrency)) \(preferredCurrency)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)

                HStack {
                    rowIcon("bag")
                    Text("App Store").foregroundStyle(.primary)
                    Spacer()
                    Menu {
                        ForEach(Self.appStoreRegions, id: \.code) { region in
                            Button {
                                Haptics.fire(.selectionChanged)
                                withTransaction(Transaction(animation: nil)) {
                                    appStoreRegion = region.code
                                }
                            } label: {
                                macMenuOptionTitle(region.name, isSelected: appStoreRegion == region.code)
                            }
                        }
                    } label: {
                        macMenuValueLabel(appStoreRegionLabel)
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    rowIcon("paintbrush")
                    Text("Appearance").foregroundStyle(.primary)
                    Spacer()
                    Menu {
                        Button {
                            Haptics.fire(.selectionChanged)
                            withTransaction(Transaction(animation: nil)) {
                                appearanceMode = 0
                            }
                        } label: { macMenuOptionTitle("System", isSelected: appearanceMode == 0) }
                        Button {
                            Haptics.fire(.selectionChanged)
                            withTransaction(Transaction(animation: nil)) {
                                appearanceMode = 1
                            }
                        } label: { macMenuOptionTitle("Light", isSelected: appearanceMode == 1) }
                        Button {
                            Haptics.fire(.selectionChanged)
                            withTransaction(Transaction(animation: nil)) {
                                appearanceMode = 2
                            }
                        } label: { macMenuOptionTitle("Dark", isSelected: appearanceMode == 2) }
                    } label: {
                        macMenuValueLabel(appearanceMode == 0 ? "System" : appearanceMode == 1 ? "Light" : "Dark")
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                sectionHeader("DISPLAY")
            } footer: {
                Text("All subscription costs are converted to this currency when calculating totals. Exchange rates are approximate and updated periodically.")
            }

            // MARK: Expired Pro
            Section {
                if purchaseManager.isPremium {
                    HStack {
                        rowIcon("crown.fill", color: .green)
                        Text("Expired Pro").foregroundStyle(.primary)
                        Spacer()
                        Text("Active").foregroundStyle(.green)
                    }
                    Button {
                        Haptics.fire(.light)
                        showCustomerCenter = true
                    } label: {
                        HStack {
                            rowIcon("person.crop.circle")
                            Text("Manage Subscription").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Haptics.fire(.light)
                        showPaywall = true
                    } label: {
                        HStack {
                            rowIcon("crown.fill", color: .blue)
                            Text("Upgrade to Pro").foregroundStyle(.blue)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        Haptics.fire(.light)
                        showCustomerCenter = true
                    } label: {
                        HStack {
                            rowIcon("arrow.clockwise", color: .blue)
                            Text("Restore Purchases").foregroundStyle(.blue)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                sectionHeader("EXPIRED PRO")
            }

            // MARK: Screenshot Import
            Section {
                HStack {
                    rowIcon("sparkles")
                    Text("Analyzer").foregroundStyle(.primary)
                    if !purchaseManager.isPremium { ProChip() }
                    Spacer()
                    Menu {
                        ForEach(ScreenshotAIProvider.allCases) { provider in
                            Button {
                                setScreenshotAIProvider(provider)
                            } label: {
                                macMenuOptionTitle(provider.displayName, isSelected: screenshotAIProvider == provider)
                            }
                        }
                    } label: {
                        macMenuValueLabel(displayedScreenshotAIProviderName)
                    }
                    .buttonStyle(.plain)
                    .disabled(!purchaseManager.isPremium)
                }

                if purchaseManager.isPremium && screenshotAIProvider.requiresAPIKey {
                    HStack {
                        rowIcon("cpu")
                        Text("Model").foregroundStyle(.primary)
                        Spacer()
                        if isLoadingModels { ProgressView().controlSize(.small) }
                        Menu {
                            ForEach(modelPickerOptions, id: \.self) { model in
                                Button {
                                    Haptics.fire(.selectionChanged)
                                    setSelectedModel(model)
                                } label: {
                                    macMenuOptionTitle(modelLabel(model), isSelected: currentSelectedModel == model)
                                }
                            }
                        } label: {
                            macMenuValueLabel(modelLabel(currentSelectedModel))
                        }
                        .buttonStyle(.plain)
                        Button {
                            Haptics.fire(.light)
                            loadModels()
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }

                    modelPickerNote
                }
            } header: {
                sectionHeader("SCREENSHOT IMPORT")
            } footer: {
                Text("Automatic tries On-Device first, then falls back to Expired's secure proxy if needed. Other providers send the screenshot through the proxy directly — no key needed on your device.")
            }

            // MARK: Notifications
            Section {
                HStack {
                    rowIcon("clock")
                    Text("Reminder").foregroundStyle(.primary)
                    Spacer()
                    QuarterHourTimePicker(date: Binding(get: { notificationTime }, set: { saveNotificationTime($0) }))
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                HStack {
                    rowIcon("moon.fill")
                    Text("Quiet Hours").foregroundStyle(.primary)
                    Spacer()
                    Toggle("", isOn: Binding(get: { quietHoursEnabled }, set: { setQuietHoursEnabled($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(.blue)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                if quietHoursEnabled {
                    HStack {
                        rowIcon("bed.double.fill")
                        Text("From").foregroundStyle(.primary)
                        Spacer()
                        QuarterHourTimePicker(date: quietStartBinding)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    HStack {
                        rowIcon("sun.max.fill")
                        Text("To").foregroundStyle(.primary)
                        Spacer()
                        QuarterHourTimePicker(date: quietEndBinding)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }

                NavigationLink {
                    ScheduledNotificationsView()
                } label: {
                    HStack {
                        rowIcon("list.bullet.rectangle")
                        Text("Scheduled Notifications").foregroundStyle(.primary)
                    }
                }
            } header: {
                sectionHeader("NOTIFICATIONS")
            } footer: {
                Text(quietHoursEnabled
                     ? "Non-critical reminders inside quiet hours are delivered at the window's end. Critical reminders always fire on time."
                     : "Reminders will be delivered at this time on the scheduled day.")
            }

            // MARK: Data
            Section {
                NavigationLink { ArchiveView() } label: {
                    HStack {
                        rowIcon("archivebox")
                        Text("Archive").foregroundStyle(.primary)
                        Spacer()
                        if !archivedItems.isEmpty {
                            Text("\(archivedItems.count)").foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink { CategoriesView() } label: {
                    HStack {
                        rowIcon("square.grid.2x2")
                        Text("Categories").foregroundStyle(.primary)
                    }
                }
                Button {
                    Haptics.fire(.light)
                    refreshAllFavicons()
                } label: {
                    HStack {
                        rowIcon("arrow.clockwise.circle", color: isRefreshingFavicons ? Color.secondary : Color.blue)
                        Text("Refresh Icons")
                            .foregroundStyle(isRefreshingFavicons ? Color.secondary : Color.blue)
                        if isRefreshingFavicons {
                            Spacer()
                            if faviconRefreshProgress.total > 0 {
                                Text("\(faviconRefreshProgress.done)/\(faviconRefreshProgress.total)")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 13))
                            }
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshingFavicons)
            } header: {
                sectionHeader("DATA")
            }

            // MARK: Privacy
            Section {
                HStack {
                    rowIcon("chart.bar")
                    Text("Share Subscription Usage").foregroundStyle(.primary)
                    Spacer()
                    Toggle("", isOn: $shareServicePopularity)
                        .labelsHidden()
                        .tint(.green)
                        .onChange(of: shareServicePopularity) { _, _ in
                            Haptics.fire(.selectionChanged)
                        }
                }
            } header: {
                sectionHeader("PRIVACY")
            } footer: {
                Text("When a subscription you add matches a known service (e.g. Netflix), the service name alone is sent anonymously — never your cost, dates, notes, or any identifier — to help prioritize which services Expired recognizes automatically. Off means nothing is ever sent.")
            }

            // MARK: Backup & Sync
            Section {
                HStack {
                    rowIcon("icloud")
                    Text("iCloud Sync").foregroundStyle(.primary)
                    Spacer()
                    Toggle("", isOn: $iCloudSyncEnabled)
                        .labelsHidden()
                        .tint(.green)
                        .onChange(of: iCloudSyncEnabled) { _, _ in
                            Haptics.fire(.selectionChanged)
                            showRestartAlert = true
                        }
                }

                HStack {
                    rowIcon("icloud.and.arrow.up")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iCloud Backup").foregroundStyle(.primary)
                        Text(lastAutoBackupText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $autoBackupEnabled)
                        .labelsHidden()
                        .tint(.green)
                        .onChange(of: autoBackupEnabled) { _, _ in
                            Haptics.fire(.selectionChanged)
                        }
                }

                Button { beginExport() } label: {
                    HStack {
                        rowIcon("square.and.arrow.up", color: .blue)
                        Text("Export Backup").foregroundStyle(.blue)
                        ProChip()
                    }
                }
                .buttonStyle(.plain)

                Button { beginImportBackup() } label: {
                    HStack {
                        rowIcon("square.and.arrow.down", color: .blue)
                        Text("Import Backup").foregroundStyle(.blue)
                        ProChip()
                    }
                }
                .buttonStyle(.plain)
            } header: {
                sectionHeader("BACKUP & SYNC")
            } footer: {
                Text("iCloud Sync keeps data across all your devices — restart the app after changing. Daily snapshots save automatically to iCloud Drive (skipped if nothing changed). Export writes an unencrypted JSON file (icons excluded); import merges by item, never deleting. Keep the file private.")
            }

            Section {
                versionFooterRow
                    .listRowBackground(Color.clear)
            }

            if debugSectionRevealed {
                DebugAIFailureSimulatorView(onHide: { debugSectionRevealed = false })
            }
        }
        .navigationTitle("Settings")
        .largeNavigationTitle()
        .currencyPickerPresentation(isPresented: $showCurrencyPicker, selectedCode: $preferredCurrency)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please restart the app for the iCloud sync change to take effect.")
        }
    }

    private func refreshAllFavicons() {
        let itemsWithURL = allItems.filter {
            !$0.url.isEmpty &&
            $0.iconSource != .customImage &&
            $0.iconSource != .appBundle
        }
        guard !itemsWithURL.isEmpty else { return }
        isRefreshingFavicons = true
        faviconRefreshProgress = (0, itemsWithURL.count)
        Task {
            for item in itemsWithURL {
                guard !Task.isCancelled else { break }
                if let data = await FaviconFetcher.fetch(from: item.url) {
                    await MainActor.run {
                        // The row may have been deleted while the fetch was in flight.
                        guard item.modelContext != nil else {
                            faviconRefreshProgress.done += 1
                            return
                        }
                        item.iconData = data
                        item.iconSource = .favicon
                        try? item.modelContext?.save()
                        faviconRefreshProgress.done += 1
                    }
                } else {
                    await MainActor.run { faviconRefreshProgress.done += 1 }
                }
            }
            await MainActor.run { isRefreshingFavicons = false }
        }
    }

}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(CloudKitDebugStore.shared)
        .environment(PurchaseManager.shared)
        .modelContainer(PreviewData.container)
}
// MARK: - Platform-adaptive currency picker presentation

extension View {
    /// Presents `CurrencyPickerSheet` as a sheet on iOS and a popover on macOS.
    func currencyPickerPresentation(isPresented: Binding<Bool>, selectedCode: Binding<String>) -> some View {
#if os(iOS)
        self.sheet(isPresented: isPresented) {
            CurrencyPickerSheet(selectedCode: selectedCode)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
#else
        self.popover(isPresented: isPresented, arrowEdge: .bottom) {
            CurrencyPickerSheet(selectedCode: selectedCode)
                .frame(minWidth: 320, minHeight: 400)
        }
#endif
    }
}
