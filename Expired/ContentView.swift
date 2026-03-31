import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var settingsNavID = UUID()

    var body: some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { newTab in
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
                TimelineView()
            }
            Tab("Insights", systemImage: "chart.bar", value: 2) {
                InsightsView()
            }
            Tab("Settings", systemImage: "gear", value: 3) {
                SettingsView()
                    .id(settingsNavID)
            }
        }
#if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
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
        case strip      = "Month Strip"

        var icon: String {
            switch self {
            case .timeline:   return "list.bullet.below.rectangle"
            case .calendar:   return "calendar"
            case .heatmap:    return "square.grid.3x3.fill"
            case .swimLane:   return "chart.bar.xaxis"
            case .spendSpike: return "chart.bar.fill"
            case .strip:      return "rectangle.split.3x1"
            }
        }
    }

    @AppStorage("timelineViewMode") private var viewModeRaw: String = ViewMode.timeline.rawValue
    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .timeline }

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
                    switch viewMode {
                    case .timeline:   classicTimelineView
                    case .calendar:   CalendarGridView(items: allItems, currency: preferredCurrency)
                    case .heatmap:    HeatmapView(items: allItems, currency: preferredCurrency)
                    case .swimLane:   SwimLaneView(items: upcoming)
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
                            Button {
                                withAnimation(.spring(duration: 0.3)) { viewModeRaw = mode.rawValue }
                            } label: {
                                if viewMode == mode {
                                    Label(mode.rawValue, systemImage: "checkmark")
                                } else {
                                    Label(mode.rawValue, systemImage: mode.icon)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: viewMode.icon)
                            .font(.system(size: 16, weight: .semibold))
                    }
#if os(macOS)
                    .menuIndicator(.hidden)
#endif
                }
            }
        }
    }

    // MARK: - Classic timeline (original spine list)

    private var classicTimelineView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, item in
                    TimelineRow(item: item, isLast: index == upcoming.count - 1)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

// MARK: - Classic Timeline Row

struct TimelineRow: View {
    let item: SubscriptionItem
    let isLast: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, 4)
                if !isLast {
                    Rectangle()
                        .fill(dotColor.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)
            SubscriptionRowView(item: item, showsDaysUntilBadge: true)
        }
        .frame(minHeight: 60)
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
            return item.cost
        }.reduce(0, +)
    }

    private var monthLabel: String {
        displayedMonth.formatted(.dateTime.month(.wide).year())
    }

    // Days in the displayed month padded to start on Sunday
    private var gridDays: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: displayedMonth)) else { return [] }
        let weekday = cal.component(.weekday, from: firstDay) - 1  // 0=Sun
        var days: [Date?] = Array(repeating: nil, count: weekday)
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
            let cellSize = floor(min(
                availableWidth / 7,
                (availableHeight - gridSpacing * CGFloat(rows - 1)) / CGFloat(rows)
            ))
            let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: gridSpacing), count: 7)

            VStack(spacing: 8) {
                // Month header
                HStack {
                    Button {
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
                    ForEach(["S","M","T","W","T","F","S"], id: \.self) { d in
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
        let today = cal.startOfDay(for: Date())
        return (0..<days).map { offset in
            let date = cal.date(byAdding: .day, value: offset, to: today) ?? today
            let dayItems = items.filter { cal.startOfDay(for: $0.nextRelevantDate) == date }
            let spend = dayItems.compactMap(\.cost).reduce(0, +)
            return DayData(id: offset, date: date, spend: spend, items: dayItems)
        }
    }

    private var maxSpend: Double { dayData.map(\.spend).max() ?? 1 }

    @State private var selectedDay: DayData? = nil

    var body: some View {
        GeometryReader { geo in
            let horizontalPadding: CGFloat = 16
            let gridSpacing: CGFloat = 4
            let rows = 13
            let headerHeight: CGFloat = 96
            let labelsHeight: CGFloat = 16
            let availableWidth = geo.size.width - horizontalPadding * 2 - gridSpacing * 6
            let availableHeight = geo.size.height - headerHeight - labelsHeight - 60
            let cellSize = floor(min(
                availableWidth / 7,
                (availableHeight - gridSpacing * CGFloat(rows - 1)) / CGFloat(rows)
            ))
            let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: gridSpacing), count: 7)
            let startWeekday = cal.component(.weekday, from: Date()) - 1 // 0=Sun

            VStack(alignment: .leading, spacing: 10) {
                // Header
                VStack(spacing: 4) {
                    Text("Next 13 Weeks")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    let total = dayData.map(\.spend).reduce(0, +)
                    Text(CurrencyInfo.format(total, code: currency))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("total spend in next 90 days")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

                // Day-of-week labels
                HStack(spacing: 0) {
                    ForEach(["S","M","T","W","T","F","S"], id: \.self) { d in
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
                    ForEach(0..<startWeekday, id: \.self) { _ in
                        Color.clear.frame(width: cellSize, height: cellSize)
                    }
                    ForEach(dayData) { day in
                        HeatmapCell(
                            day: day.date,
                            spend: day.spend,
                            items: day.items,
                            maxSpend: maxSpend,
                            currency: currency,
                            isSelected: selectedDay?.id == day.id
                        )
                        .frame(width: cellSize, height: cellSize)
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.2)) {
                                selectedDay = selectedDay?.id == day.id ? nil : day
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
                if let day = selectedDay, !day.items.isEmpty {
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

    private var maxDays: Int {
        items.map(\.daysUntilRenewal).max().map { max($0, 1) } ?? 1
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header row
                HStack {
                    Text("Subscription")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 120, alignment: .leading)
                    Text("Days until renewal →")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, horizPadding)
                .padding(.vertical, 8)

                ForEach(items) { item in
                    SwimLaneRow(item: item, maxDays: maxDays, laneHeight: laneHeight)
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

    private var days: Int { max(item.daysUntilRenewal, 0) }
    private var fraction: Double { maxDays > 0 ? Double(days) / Double(maxDays) : 0 }

    private var barColor: Color {
        switch item.urgency {
        case .critical: return .red
        case .warning:  return .orange
        case .expired:  return .secondary
        case .normal:   return .blue
        }
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
            .frame(width: 120, alignment: .leading)

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
                    Capsule()
                        .fill(LinearGradient(
                            colors: [barColor.opacity(0.7), barColor],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(8, geo.size.width * fraction), height: 8)
                        .frame(maxHeight: .infinity, alignment: .center)

                    // Days label at end of bar
                    Text(days == 0 ? "Today" : "\(days)d")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(barColor)
                        .offset(x: max(8, geo.size.width * fraction) + 4)
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
        var total: Double { items.compactMap(\.cost).reduce(0, +) }

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
            return WeekBucket(id: w, startDate: start, endDate: end, items: bucket)
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

// MARK: - Option 5: Rolling Month Strip

struct MonthStripView: View {
    let items: [SubscriptionItem]
    let currency: String

    private var cal: Calendar { Calendar.current }

    private struct DayCard: Identifiable {
        let id: Int
        let date: Date
        let items: [SubscriptionItem]
        var total: Double { items.compactMap(\.cost).reduce(0, +) }
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
            let horizontalPadding: CGFloat = 14
            let cardWidth = floor((geo.size.width - horizontalPadding * 2 - spacing * CGFloat(periodLength - 1)) / CGFloat(periodLength))
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
                                    withAnimation(.spring(duration: 0.2)) {
                                        selectedDay = selectedDay?.id == day.id ? nil : day
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 10)
                        .tag(period.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .frame(height: 130)
                .onChange(of: currentPeriodID) { _, _ in
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
        let today = cal.startOfDay(for: Date())
        return (0..<count).map { index in
            let start = cal.date(byAdding: .day, value: index * length, to: today) ?? today
            let days: [DayCard] = (0..<length).map { offset in
                let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
                let dayItems = items.filter { cal.startOfDay(for: $0.nextRelevantDate) == date }
                return DayCard(id: index * length + offset, date: date, items: dayItems)
            }
            return Period(id: index, startDate: start, days: days)
        }
    }

    private func periodLabel(start: Date, length: Int) -> String {
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
        .scaleEffect(isSelected ? 1.02 : 1.0)
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
    }
    @State private var costPeriod: CostPeriod = .monthly

    private var activeItems: [SubscriptionItem] {
        allItems.filter { if case .expired = $0.status { return false }; return true }
    }
    private var displayCurrency: String { preferredCurrency }

    private var monthlyTotal: Double {
        activeItems.compactMap { $0.monthlyCostConverted(to: preferredCurrency) }.reduce(0, +)
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

    private var costPeriodIcon: String {
        switch costPeriod {
        case .monthly:  return "calendar"
        case .annual:   return "chart.line.uptrend.xyaxis"
        case .ytd:      return "calendar.badge.checkmark"
        case .lifetime: return "infinity"
        }
    }

    private var autoRenewCount: Int { activeItems.filter(\.isAutoRenew).count }
    private var trialCount: Int { activeItems.filter(\.isTrial).count }
    private var cancelledCount: Int {
        allItems.filter { if case .cancelledButActive = $0.status { return true }; return false }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Period picker
                    Picker("", selection: $costPeriod) {
                        ForEach(CostPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    costCard
                    countsRow
                    if !activeItems.isEmpty { costBreakdown }
                    Spacer(minLength: 40)
                }
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(groupedBackground.ignoresSafeArea())
            .navigationTitle("Insights")
            .largeNavigationTitle()
        }
    }

    private var costCard: some View {
        GlassInsightCard(
            title: costPeriod.rawValue + " Cost",
            value: CurrencyInfo.format(displayTotal, code: displayCurrency),
            icon: costPeriodIcon,
            color: .blue
        )
        .padding(.horizontal)
    }

    private var countsRow: some View {
        HStack(spacing: 12) {
            GlassInsightCard(title: "Auto-Renewing", value: "\(autoRenewCount)", icon: "arrow.clockwise", color: .green)
            GlassInsightCard(title: "Free Trials", value: "\(trialCount)", icon: "gift.fill", color: .purple)
            GlassInsightCard(title: "Cancelled", value: "\(cancelledCount)", icon: "xmark.circle", color: .red)
        }
        .padding(.horizontal)
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
            guard billingFrom < billingTo else { return monthly }
            let days = cal.dateComponents([.day], from: billingFrom, to: billingTo).day ?? 0
            return monthly * max(1, Double(days) / 30.4375)
        }
    }

    private var costBreakdown: some View {
        let itemsWithCost = activeItems
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
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(itemsWithCost) { item in
                    CostBarRow(
                        item: item,
                        displayCost: periodCost(for: item),
                        displayCurrency: preferredCurrency,
                        maxCost: maxCost
                    )
                }
            }
        }
        .padding(.horizontal)
    }
}

struct GlassInsightCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(height: 22, alignment: .center)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 20))
    }
}

struct CostBarRow: View {
    let item: SubscriptionItem
    let displayCost: Double
    let displayCurrency: String
    let maxCost: Double

    var body: some View {
        HStack(spacing: 12) {
            ItemIconView(item: item, size: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(CurrencyInfo.format(displayCost, code: displayCurrency))
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
                        .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(in: .rect(cornerRadius: 16))
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
                                modelContext.delete(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                withAnimation {
                                    item.isArchived = false
                                    item.updatedAt = Date()
                                }
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
#if os(iOS)
        iOSBody
#else
        macOSBody
#endif
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
                    unifiedCategories.remove(atOffsets: IndexSet(toRemove))
                    saveUnified()
                }
            }

            Section {
                Button {
                    newCategoryName = ""
                    newCategoryIcon = UserCategory.defaultIcon
                    newCategoryDescription = ""
                    editingCategory = nil
                    showingAdd = true
                } label: {
                    Label("Add Category", systemImage: "plus.circle.fill")
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
                    unifiedCategories[idx] = .custom(updated)
                } else {
                    unifiedCategories.append(.custom(UserCategory(
                        name: newCategoryName,
                        icon: newCategoryIcon,
                        description: newCategoryDescription.isEmpty ? nil : newCategoryDescription
                    )))
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
                    unifiedCategories[idx] = .custom(updated)
                } else {
                    unifiedCategories.append(.custom(UserCategory(
                        name: newCategoryName,
                        icon: newCategoryIcon,
                        description: newCategoryDescription.isEmpty ? nil : newCategoryDescription
                    )))
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
                newCategoryName = ""
                newCategoryIcon = UserCategory.defaultIcon
                newCategoryDescription = ""
                editingCategory = nil
                showingAdd = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
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
                withAnimation {
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true
    @AppStorage("preferredCurrency") private var preferredCurrency = SettingsView.localeCurrencyCode
    @AppStorage("appearanceMode") private var appearanceMode = 0
    @AppStorage("notificationHour")   private var notificationHour: Int = 9
    @AppStorage("notificationMinute") private var notificationMinute: Int = 0
    @State private var showRestartAlert = false
    @State private var showCurrencyPicker = false
    @State private var isSyncing = false
    @State private var isRefreshingFavicons = false
    @State private var faviconRefreshProgress: (done: Int, total: Int) = (0, 0)
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

    /// Writes notification time to both @AppStorage (local) and iCloud KV store (cross-device).
    /// Minutes are snapped to the nearest 15-minute interval (0, 15, 30, 45).
    private func saveNotificationTime(_ date: Date) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour   = comps.hour   ?? 9
        let rawMin = comps.minute ?? 0
        let minute = (rawMin / 15) * 15   // snap down to nearest quarter-hour
        notificationHour   = hour
        notificationMinute = minute
        let kv = NSUbiquitousKeyValueStore.default
        kv.set(Int64(hour),   forKey: Self.kvHourKey)
        kv.set(Int64(minute), forKey: Self.kvMinuteKey)
        kv.synchronize()
    }

    /// Pulls the notification time from iCloud KV store into @AppStorage.
    private func pullNotificationTimeFromKVStore() {
        let kv = NSUbiquitousKeyValueStore.default
        guard kv.object(forKey: Self.kvHourKey) != nil else { return }
        notificationHour   = Int(kv.longLong(forKey: Self.kvHourKey))
        notificationMinute = Int(kv.longLong(forKey: Self.kvMinuteKey))
    }

    /// Best-guess currency from the device locale, falling back to USD.
    static var localeCurrencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
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
        }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { note in
            guard let keys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) else { return }
            if keys.contains(Self.kvHourKey) || keys.contains(Self.kvMinuteKey) {
                pullNotificationTimeFromKVStore()
            }
        }
    }

    // MARK: - macOS Settings (card layout matching iOS form style)

#if os(macOS)
    private var macSettingsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // DISPLAY
                settingsSection(title: "Display", icon: "paintbrush") {
                    Button { showCurrencyPicker = true } label: {
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
                        macSettingsLabel("Appearance", icon: "paintbrush")
                        Spacer()
                        Menu {
                            Button { appearanceMode = 0 } label: {
                                if appearanceMode == 0 { Label("System", systemImage: "checkmark") }
                                else { Text("System") }
                            }
                            Button { appearanceMode = 1 } label: {
                                if appearanceMode == 1 { Label("Light", systemImage: "checkmark") }
                                else { Text("Light") }
                            }
                            Button { appearanceMode = 2 } label: {
                                if appearanceMode == 2 { Label("Dark", systemImage: "checkmark") }
                                else { Text("Dark") }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(appearanceMode == 0 ? "System" : appearanceMode == 1 ? "Light" : "Dark")
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .animation(nil, value: appearanceMode)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }

                // NOTIFICATIONS
                settingsSection(title: "Notifications", icon: "bell") {
                    settingsRow {
                        macSettingsLabel("Reminder", icon: "clock")
                        Spacer()
                        DatePicker(
                            "",
                            selection: Binding(get: { notificationTime }, set: { saveNotificationTime($0) }),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .datePickerStyle(.field)
                    }
                }

                // SYNC
                settingsSection(title: "Sync", icon: "icloud") {
                    settingsRow {
                        macSettingsLabel("iCloud Sync", icon: "icloud")
                        Spacer()
                        Toggle("", isOn: $iCloudSyncEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.green)
                            .onChange(of: iCloudSyncEnabled) { _, _ in showRestartAlert = true }
                    }

                    FormDivider()

                    Button {
                        guard !isSyncing else { return }
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

                    Button { refreshAllFavicons() } label: {
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

    // MARK: - iOS Settings (List-based)

    private var iosSettingsBody: some View {
        List {
            Section {
                Button {
                    showCurrencyPicker = true
                } label: {
                    HStack {
                        Label("Currency", systemImage: "dollarsign.circle")
                            .foregroundStyle(.primary, .secondary)
                        Spacer()
                        Text("\(CurrencyInfo.symbol(for: preferredCurrency)) \(preferredCurrency)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                Button {
                    appearanceMode = (appearanceMode + 1) % 3
                } label: {
                    HStack {
                        Label("Appearance", systemImage: "paintbrush")
                            .foregroundStyle(.primary, .secondary)
                        Spacer()
                        Menu {
                            Button { appearanceMode = 0 } label: {
                                if appearanceMode == 0 { Label("System", systemImage: "checkmark") }
                                else { Text("System") }
                            }
                            Button { appearanceMode = 1 } label: {
                                if appearanceMode == 1 { Label("Light", systemImage: "checkmark") }
                                else { Text("Light") }
                            }
                            Button { appearanceMode = 2 } label: {
                                if appearanceMode == 2 { Label("Dark", systemImage: "checkmark") }
                                else { Text("Dark") }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(appearanceMode == 0 ? "System" : appearanceMode == 1 ? "Light" : "Dark")
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .animation(nil, value: appearanceMode)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Display")
            } footer: {
                Text("All subscription costs are converted to this currency when calculating totals. Exchange rates are approximate and updated periodically.")
            }

            Section {
                HStack {
                    Label("Reminder", systemImage: "clock")
                        .foregroundStyle(.primary, .secondary)
                    Spacer()
                    DatePicker(
                        "",
                        selection: Binding(get: { notificationTime }, set: { saveNotificationTime($0) }),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize()
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Reminders will be delivered at this time on the scheduled day.")
            }

            Section {
                Toggle(isOn: $iCloudSyncEnabled) {
                    Label("iCloud Sync", systemImage: "icloud")
                        .foregroundStyle(.primary, .secondary)
                }
                .onChange(of: iCloudSyncEnabled) { _, _ in
                    showRestartAlert = true
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("When enabled, your data syncs across all devices signed into the same iCloud account. Requires an iCloud account and internet connection. Restart the app after changing this setting.")
            }

            Section("Data") {
                NavigationLink {
                    ArchiveView()
                } label: {
                    HStack {
                        Label("Archive", systemImage: "archivebox")
                            .foregroundStyle(.primary, .secondary)
                        Spacer()
                        if !archivedItems.isEmpty {
                            Text("\(archivedItems.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink {
                    CategoriesView()
                } label: {
                    Label("Categories", systemImage: "square.grid.2x2")
                        .foregroundStyle(.primary, .secondary)
                }
                Button {
                    refreshAllFavicons()
                } label: {
                    HStack {
                        Label("Refresh Icons", systemImage: "arrow.clockwise.circle")
                            .foregroundStyle(.blue)
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
                        item.iconData = data
                        item.iconSource = .favicon
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

