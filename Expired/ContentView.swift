import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Subscriptions", systemImage: "creditcard") {
                HomeView()
            }
            Tab("Timeline", systemImage: "calendar") {
                TimelineView()
            }
            Tab("Insights", systemImage: "chart.bar") {
                InsightsView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
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

    /// Year-to-date: monthly total × months elapsed this year (including partial current month)
    private var ytdTotal: Double {
        let now = Date()
        let cal = Calendar.current
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1
        let daysInYear = cal.range(of: .day, in: .year, for: now)?.count ?? 365
        let yearFraction = Double(dayOfYear) / Double(daysInYear)
        return yearlyTotal * yearFraction
    }

    /// Lifetime: sum of (monthly cost × months since createdAt) for each item
    private var lifetimeTotal: Double {
        activeItems.reduce(0) { sum, item in
            guard let monthly = item.monthlyCostConverted(to: preferredCurrency) else { return sum }
            let months = max(1, Calendar.current.dateComponents([.month], from: item.createdAt, to: Date()).month ?? 1)
            return sum + monthly * Double(months)
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
                    Picker("Period", selection: $costPeriod) {
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
        if costPeriod == .lifetime {
            let months = max(1, Calendar.current.dateComponents([.month], from: item.createdAt, to: Date()).month ?? 1)
            return monthly * Double(months)
        }
        return monthly * periodMultiplier
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
                    List {
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
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(groupedBackground.ignoresSafeArea())
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
}

// MARK: - Categories View

struct CategoriesView: View {
    @Query(filter: #Predicate<SubscriptionItem> { !$0.isArchived && $0.itemTypeRaw == "subscription" })
    private var allSubscriptions: [SubscriptionItem]

    @State private var userCategories: [UserCategory] = []
    @State private var showingAdd = false
    @State private var editingCategory: UserCategory? = nil
    @State private var newCategoryName = ""
    @State private var newCategoryIcon = UserCategory.defaultIcon

    private func count(rawName: String) -> Int {
        allSubscriptions.filter { $0.categoryRaw == rawName }.count
    }

    private var uncategorisedCount: Int {
        allSubscriptions.filter { $0.categoryRaw == nil }.count
    }

    var body: some View {
        List {
            Section {
                ForEach(SubscriptionCategory.allCases, id: \.self) { cat in
                    HStack {
                        Label(cat.displayName, systemImage: cat.icon)
                        Spacer()
                        let n = count(rawName: cat.rawValue)
                        if n > 0 {
                            Text("\(n)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Built-in")
            }

            Section {
                ForEach($userCategories) { $cat in
                    HStack {
                        Label(cat.name, systemImage: cat.icon)
                        Spacer()
                        let n = count(rawName: cat.name)
                        if n > 0 {
                            Text("\(n)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            userCategories.removeAll { $0.id == cat.id }
                            UserCategoryStore.save(userCategories)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            newCategoryName = cat.name
                            newCategoryIcon = cat.icon
                            editingCategory = cat
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onMove { source, destination in
                    userCategories.move(fromOffsets: source, toOffset: destination)
                    UserCategoryStore.save(userCategories)
                }
                Button {
                    newCategoryName = ""
                    newCategoryIcon = UserCategory.defaultIcon
                    editingCategory = nil
                    showingAdd = true
                } label: {
                    Label("Add Category", systemImage: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
            } header: {
                Text("Custom")
            } footer: {
                Text("Swipe left to edit or delete. Drag to reorder.")
            }

            Section {
                HStack {
                    Label("Uncategorised", systemImage: "circle.dashed")
                    Spacer()
                    if uncategorisedCount > 0 {
                        Text("\(uncategorisedCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .largeNavigationTitle()
        .toolbar { EditButton() }
        .onAppear { userCategories = UserCategoryStore.load() }
        .sheet(isPresented: $showingAdd) {
            CategoryEditSheet(
                name: $newCategoryName,
                icon: $newCategoryIcon,
                title: editingCategory == nil ? "Add Category" : "Edit Category"
            ) {
                if let editing = editingCategory,
                   let idx = userCategories.firstIndex(where: { $0.id == editing.id }) {
                    userCategories[idx].name = newCategoryName
                    userCategories[idx].icon = newCategoryIcon
                } else {
                    userCategories.append(UserCategory(name: newCategoryName, icon: newCategoryIcon))
                }
                UserCategoryStore.save(userCategories)
            }
        }
        .onChange(of: editingCategory) { _, cat in
            if cat != nil { showingAdd = true }
        }
    }
}

struct CategoryEditSheet: View {
    @Binding var name: String
    @Binding var icon: String
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

    /// A Date representing the stored notification hour/minute (today's date at that time).
    private var notificationTime: Date {
        Calendar.current.date(
            bySettingHour: notificationHour, minute: notificationMinute, second: 0,
            of: Date()
        ) ?? Date()
    }

    /// Best-guess currency from the device locale, falling back to USD.
    static var localeCurrencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Base currency row — taps open the full currency picker
                    Button {
                        showCurrencyPicker = true
                    } label: {
                        HStack {
                            Label("Base Currency", systemImage: "dollarsign.circle")
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
                    // Appearance row — custom button to avoid Picker opacity bug when alerts appear
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
                    DatePicker(
                        selection: Binding(
                            get: { notificationTime },
                            set: { newDate in
                                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                notificationHour   = comps.hour   ?? 9
                                notificationMinute = comps.minute ?? 0
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    ) {
                        Label("Reminder Time", systemImage: "clock")
                            .foregroundStyle(.primary, .secondary)
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
#if os(macOS)
                    // macOS has no pull-to-refresh; this nudges CloudKit to process pending changes.
                    Button {
                        guard !isSyncing else { return }
                        isSyncing = true
                        NotificationCenter.default.post(name: .expiredManualSync, object: nil)
                        // Brief visual feedback — CloudKit is async and has no completion callback
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            isSyncing = false
                        }
                    } label: {
                        HStack {
                            Label("Sync Now", systemImage: isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise.icloud")
                                .foregroundStyle(.primary, .secondary)
                            if isSyncing {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(!iCloudSyncEnabled || isSyncing)
#endif
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
                            Label("Refresh All Icons", systemImage: "arrow.clockwise.circle")
                                .foregroundStyle(.primary)
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

