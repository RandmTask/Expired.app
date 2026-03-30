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

// MARK: - Timeline View

struct TimelineView: View {
    @Query(filter: #Predicate<SubscriptionItem> { !$0.isArchived },
           sort: \SubscriptionItem.nextRenewalDate)
    private var allItems: [SubscriptionItem]

    private var upcoming: [SubscriptionItem] {
        allItems.filter { $0.daysUntilRenewal >= 0 }
            .sorted { $0.nextRelevantDate < $1.nextRelevantDate }
    }

    var body: some View {
        NavigationStack {
            timelineContent
                .navigationTitle("Timeline")
                .largeNavigationTitle()
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if upcoming.isEmpty {
            ContentUnavailableView(
                "No Upcoming Events",
                systemImage: "calendar.badge.clock",
                description: Text("Add subscriptions to see your timeline.")
            )
        } else {
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
            .background(groupedBackground.ignoresSafeArea())
        }
    }
}

struct TimelineRow: View {
    let item: SubscriptionItem
    let isLast: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Timeline spine
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

            SubscriptionRowView(item: item)
        }
        .frame(minHeight: 60)
    }

    private var dotColor: Color {
        switch item.status {
        case .trial: return .purple
        case .autoRenew: return .green
        case .manualRenew: return .blue
        case .cancelledButActive: return .orange
        case .expired: return .gray
        }
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

