import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<SubscriptionItem> { !$0.isArchived },
           sort: \SubscriptionItem.nextRenewalDate)
    private var allItems: [SubscriptionItem]

    private var subscriptionItems: [SubscriptionItem] {
        allItems.filter { $0.itemType == .subscription }
    }

    @State private var showingAdd = false
    @State private var editingItem: SubscriptionItem?
    @State private var searchText = ""

    // Sort & filter
    enum SortOrder: String, CaseIterable {
        case status      = "Status"
        case category    = "Category"
        case name        = "Name"
        case renewalDate = "Renewal Date"
        case price       = "Price"
    }
    enum FilterOption: String, CaseIterable { case all = "All"; case autoRenew = "Auto-Renew"; case trials = "Trials"; case cancelled = "Cancelled"; case expired = "Expired" }
    @AppStorage("homeSortOrder") private var sortOrderRaw: String = SortOrder.status.rawValue
    @AppStorage("homeFilterOption") private var filterOptionRaw: String = FilterOption.all.rawValue
    @AppStorage("homeHideExpired") private var hideExpired: Bool = false
    private var sortOrder: SortOrder { SortOrder(rawValue: sortOrderRaw) ?? .status }
    private var filterOption: FilterOption { FilterOption(rawValue: filterOptionRaw) ?? .all }

    // MARK: - Filtered groups

    private var isSearching: Bool { !searchText.isEmpty }

    private func applySort(_ items: [SubscriptionItem]) -> [SubscriptionItem] {
        switch sortOrder {
        case .status:      return items.sorted { $0.nextRelevantDate < $1.nextRelevantDate }
        case .category:    return items.sorted { ($0.categoryRaw ?? "zzz").localizedCompare($1.categoryRaw ?? "zzz") == .orderedAscending }
        case .name:        return items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .renewalDate:
            return items.sorted { lhs, rhs in
                let lhsExpired = { if case .expired = lhs.status { return true } else { return false } }()
                let rhsExpired = { if case .expired = rhs.status { return true } else { return false } }()
                if lhsExpired != rhsExpired { return !lhsExpired }
                return lhs.nextRelevantDate < rhs.nextRelevantDate
            }
        case .price:       return items.sorted { ($0.monthlyCost ?? 0) > ($1.monthlyCost ?? 0) }
        }
    }

    private func applyFilter(_ items: [SubscriptionItem]) -> [SubscriptionItem] {
        var result: [SubscriptionItem]
        switch filterOption {
        case .all:        result = items
        case .autoRenew:  result = items.filter { $0.isAutoRenew && !$0.isCancelled && !$0.isTrial }
        case .trials:     result = items.filter { $0.isTrial }
        case .cancelled:  result = items.filter { if case .cancelledButActive = $0.status { return true }; return false }
        case .expired:    result = items.filter { if case .expired = $0.status { return true }; return false }
        }
        if hideExpired && filterOption != .expired {
            result = result.filter { if case .expired = $0.status { return false }; return true }
        }
        return result
    }

    private var visibleItems: [SubscriptionItem] {
        guard isSearching else { return allItems }
        return allItems.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.provider.localizedCaseInsensitiveContains(searchText) ||
            $0.emailUsed.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var visibleSubscriptions: [SubscriptionItem] {
        applySort(applyFilter(visibleItems.filter { $0.itemType == .subscription }))
    }

    private var visibleDocuments: [SubscriptionItem] {
        visibleItems.filter { $0.itemType == .document }
            .sorted { $0.nextRelevantDate < $1.nextRelevantDate }
    }

    private var dueSoon: [SubscriptionItem] {
        visibleSubscriptions.filter {
            !$0.isCancelled && !$0.isTrial &&
            $0.daysUntilRenewal >= 0 && $0.daysUntilRenewal <= 14
        }
    }

    private var trialsEnding: [SubscriptionItem] {
        visibleSubscriptions.filter { $0.isTrial }
            .sorted { ($0.trialEndDate ?? .distantFuture) < ($1.trialEndDate ?? .distantFuture) }
    }

    private var cancelledActive: [SubscriptionItem] {
        visibleSubscriptions.filter {
            if case .cancelledButActive = $0.status { return true }
            return false
        }
    }

    private var upcoming: [SubscriptionItem] {
        visibleSubscriptions.filter { !$0.isCancelled && !$0.isTrial && $0.daysUntilRenewal > 14 }
    }

    private var expiredSubscriptions: [SubscriptionItem] {
        visibleSubscriptions.filter {
            if case .expired = $0.status { return true }
            return false
        }
    }

    private var allSectionsEmpty: Bool {
        switch sortOrder {
        case .status:
            return trialsEnding.isEmpty && dueSoon.isEmpty && cancelledActive.isEmpty &&
                   upcoming.isEmpty && expiredSubscriptions.isEmpty &&
                   urgentDocuments.isEmpty && upcomingDocuments.isEmpty
        default:
            return visibleSubscriptions.isEmpty && urgentDocuments.isEmpty && upcomingDocuments.isEmpty
        }
    }

    // Documents split by urgency
    private var urgentDocuments: [SubscriptionItem] {
        visibleDocuments.filter { $0.urgency == .critical || $0.urgency == .warning || $0.urgency == .expired }
    }

    private var upcomingDocuments: [SubscriptionItem] {
        visibleDocuments.filter { $0.urgency == .normal }
    }

    @AppStorage("preferredCurrency") private var preferredCurrency = SettingsView.localeCurrencyCode

    private var monthlyTotal: Double {
        subscriptionItems.compactMap { $0.monthlyCostConverted(to: preferredCurrency) }.reduce(0, +)
    }

    private var yearlyTotal: Double { monthlyTotal * 12 }

    private var displayCurrency: String { preferredCurrency }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                heroBackground.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 20) {
                        if !allItems.isEmpty && !isSearching {
                            HeroSummaryCard(
                                monthlyTotal: monthlyTotal,
                                yearlyTotal: yearlyTotal,
                                currency: displayCurrency,
                                activeCount: subscriptionItems.filter {
                                    if case .expired = $0.status { return false }
                                    return true
                                }.count
                            )
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // Active filter chips
                        if filterOption != .all || hideExpired {
                            HStack(spacing: 8) {
                                if filterOption != .all {
                                    HStack {
                                        Label(filterOption.rawValue, systemImage: "line.3.horizontal.decrease.circle.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Button {
                                            filterOptionRaw = FilterOption.all.rawValue
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white.opacity(0.8))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue, in: Capsule())
                                }
                                if hideExpired {
                                    HStack {
                                        Label("Hiding Expired", systemImage: "eye.slash")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Button {
                                            hideExpired = false
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white.opacity(0.8))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.5), in: Capsule())
                                }
                            }
                            .padding(.horizontal)
                        }

                        contentSections
                            .padding(.horizontal)

                        if allItems.isEmpty {
                            EmptyStateView { showingAdd = true }
                                .padding(.top, 60)
                        } else if allSectionsEmpty && filterOption != .all {
                            VStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.secondary)
                                Text("No \(filterOption.rawValue) subscriptions")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 60)
                        }

                        Spacer(minLength: 100)
                    }
                    .animation(.spring(duration: 0.3), value: isSearching)
                    .padding(.top, 8)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
#if os(iOS)
                .refreshable {
                    try? await Task.sleep(for: .seconds(1))
                }
#endif
            }
            .navigationTitle("")
            .largeNavigationTitle()
#if os(iOS)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search subscriptions")
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    filterMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    sortMenu
                }
            }
            .sheet(isPresented: $showingAdd) { AddEditSubscriptionView(item: nil) }
            .sheet(item: $editingItem) { AddEditSubscriptionView(item: $0) }
        }
    }

    // MARK: - Sort menu

    private var sortMenu: some View {
        Menu {
            ForEach(SortOrder.allCases, id: \.self) { option in
                Button {
                    sortOrderRaw = option.rawValue
                } label: {
                    if sortOrder == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 16, weight: .semibold))
        }
#if os(macOS)
        .menuIndicator(.hidden)
#endif
    }

    // MARK: - Filter menu

    private var filterMenu: some View {
        Menu {
            ForEach(FilterOption.allCases, id: \.self) { option in
                Button {
                    filterOptionRaw = option.rawValue
                } label: {
                    if filterOption == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
            Divider()
            Button {
                hideExpired.toggle()
            } label: {
                Label(
                    hideExpired ? "Show Expired" : "Hide Expired",
                    systemImage: hideExpired ? "eye" : "eye.slash"
                )
            }
        } label: {
            let isActive = filterOption != .all || hideExpired
            Image(systemName: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? Color.blue : Color.primary)
        }
#if os(macOS)
        .menuIndicator(.hidden)
#endif
    }

    // MARK: - Content sections

    @ViewBuilder
    private var contentSections: some View {
        switch sortOrder {
        case .status:
            statusSections
        case .category:
            categorySections
        default:
            flatSections
        }
    }

    /// Status-grouped view (original layout)
    @ViewBuilder
    private var statusSections: some View {
        if !trialsEnding.isEmpty {
            GlassSectionView(title: "Trials Ending", icon: "clock.badge.exclamationmark", accentColor: .purple) {
                ForEach(trialsEnding) { itemRow($0) }
            }
        }
        if !dueSoon.isEmpty {
            GlassSectionView(title: "Due Soon", icon: "bell.fill", accentColor: .red) {
                ForEach(dueSoon) { itemRow($0) }
            }
        }
        if !cancelledActive.isEmpty {
            GlassSectionView(title: "Cancelled but Active", icon: "calendar.badge.minus", accentColor: .orange) {
                ForEach(cancelledActive) { itemRow($0) }
            }
        }
        if !upcoming.isEmpty {
            GlassSectionView(title: "Upcoming", icon: "calendar", accentColor: .blue) {
                ForEach(upcoming) { itemRow($0) }
            }
        }
        if !expiredSubscriptions.isEmpty {
            GlassSectionView(title: "Expired", icon: "xmark.circle", accentColor: .secondary) {
                ForEach(expiredSubscriptions) { itemRow($0) }
            }
        }
        if !urgentDocuments.isEmpty {
            GlassSectionView(title: "Documents — Action Needed", icon: "exclamationmark.triangle.fill", accentColor: .orange) {
                ForEach(urgentDocuments) { itemRow($0) }
            }
        }
        if !upcomingDocuments.isEmpty {
            GlassSectionView(title: "Documents", icon: "doc.text.fill", accentColor: .indigo) {
                ForEach(upcomingDocuments) { itemRow($0) }
            }
        }
    }

    private struct CategoryGroup: Identifiable {
        let id: String
        let title: String
        let icon: String
        let items: [SubscriptionItem]
    }

    private var categoryGroups: [CategoryGroup] {
        let filtered = applyFilter(visibleItems.filter { $0.itemType == .subscription })
        // Use user-defined order for built-in categories
        let builtInKeys = BuiltInCategoryStore.orderedRawValues()
        let userKeys = UserCategoryStore.load().map { $0.name }
        var groups: [CategoryGroup] = []
        for key in (builtInKeys + userKeys) {
            let items = filtered.filter { $0.categoryRaw == key }
            guard !items.isEmpty else { continue }
            let title: String
            let icon: String
            if let cat = SubscriptionCategory(rawValue: key) {
                title = cat.displayName; icon = cat.icon
            } else {
                title = key; icon = UserCategoryStore.icon(for: key)
            }
            groups.append(CategoryGroup(id: key, title: title, icon: icon, items: items))
        }
        let uncatItems = filtered.filter { $0.categoryRaw == nil }
        if !uncatItems.isEmpty {
            groups.append(CategoryGroup(id: "__none__", title: "Uncategorised", icon: "square.grid.2x2", items: uncatItems))
        }
        return groups
    }

    /// Category-grouped view
    @ViewBuilder
    private var categorySections: some View {
        ForEach(categoryGroups) { group in
            GlassSectionView(title: group.title, icon: group.icon, accentColor: .blue) {
                ForEach(group.items) { itemRow($0) }
            }
        }
        if !urgentDocuments.isEmpty {
            GlassSectionView(title: "Documents — Action Needed", icon: "exclamationmark.triangle.fill", accentColor: .orange) {
                ForEach(urgentDocuments) { itemRow($0) }
            }
        }
        if !upcomingDocuments.isEmpty {
            GlassSectionView(title: "Documents", icon: "doc.text.fill", accentColor: .indigo) {
                ForEach(upcomingDocuments) { itemRow($0) }
            }
        }
    }

    /// Flat single-section view for name/renewal date/price sorts
    private var flatSortedSubscriptions: [SubscriptionItem] {
        applySort(applyFilter(visibleItems.filter { $0.itemType == .subscription }))
    }

    @ViewBuilder
    private var flatSections: some View {
        if !flatSortedSubscriptions.isEmpty {
            GlassSectionView(title: sortOrder.rawValue, icon: sortSectionIcon, accentColor: .blue) {
                ForEach(flatSortedSubscriptions) { itemRow($0) }
            }
        }
        if !urgentDocuments.isEmpty {
            GlassSectionView(title: "Documents — Action Needed", icon: "exclamationmark.triangle.fill", accentColor: .orange) {
                ForEach(urgentDocuments) { itemRow($0) }
            }
        }
        if !upcomingDocuments.isEmpty {
            GlassSectionView(title: "Documents", icon: "doc.text.fill", accentColor: .indigo) {
                ForEach(upcomingDocuments) { itemRow($0) }
            }
        }
    }

    private var sortSectionIcon: String {
        switch sortOrder {
        case .name:        return "textformat.abc"
        case .renewalDate: return "calendar"
        case .price:       return "dollarsign.circle"
        default:           return "list.bullet"
        }
    }

    // MARK: - Hero background

    @ViewBuilder
    private var heroBackground: some View {
        Rectangle()
            .fill(groupedBackground)
    }

    // MARK: - Row with swipe actions

    @ViewBuilder
    private func itemRow(_ item: SubscriptionItem) -> some View {
        SubscriptionRowView(item: item)
            .onTapGesture { editingItem = item }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { deleteItem(item) } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { toggleCancelled(item) } label: {
                    Label(
                        item.isCancelled ? "Reinstate" : "Cancel",
                        systemImage: item.isCancelled ? "arrow.uturn.left" : "xmark"
                    )
                }
                .tint(item.isCancelled ? .green : .orange)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { archiveItem(item) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.indigo)
            }
    }

    // MARK: - Actions

    private func deleteItem(_ item: SubscriptionItem) {
        withAnimation { modelContext.delete(item) }
    }

    private func toggleCancelled(_ item: SubscriptionItem) {
        withAnimation {
            item.isCancelled.toggle()
            if item.isCancelled { item.activeUntilDate = item.nextRenewalDate }
            else { item.activeUntilDate = nil }
            item.updatedAt = Date()
        }
    }

    private func archiveItem(_ item: SubscriptionItem) {
        withAnimation {
            item.isArchived = true
            item.updatedAt = Date()
        }
    }
}

// MARK: - Hero Summary Card

struct HeroSummaryCard: View {
    let monthlyTotal: Double
    let yearlyTotal: Double
    let currency: String
    let activeCount: Int

    var body: some View {
        HStack(spacing: 0) {
            heroItem(
                label: "Monthly",
                value: CurrencyInfo.format(monthlyTotal, code: currency),
                icon: "calendar",
                color: .blue
            )
            Divider().frame(height: 44)
            heroItem(
                label: "Yearly",
                value: CurrencyInfo.format(yearlyTotal, code: currency),
                icon: "chart.line.uptrend.xyaxis",
                color: .indigo
            )
            Divider().frame(height: 44)
            heroItem(
                label: "Active",
                value: "\(activeCount)",
                icon: "checkmark.seal.fill",
                color: .green
            )
        }
        .padding(.vertical, 18)
        .glassEffect(in: .rect(cornerRadius: 24))
    }

    @ViewBuilder
    private func heroItem(label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Glass Section View

struct GlassSectionView<Content: View>: View {
    let title: String
    let icon: String
    let accentColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header pill
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
            }
            .foregroundStyle(accentColor == .secondary ? Color.secondary : accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (accentColor == .secondary ? Color.secondary : accentColor).opacity(0.12),
                in: Capsule()
            )
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                content
            }
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.08))
                    .frame(width: 88, height: 88)
                    .glassEffect(in: Circle())
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue.opacity(0.8))
            }

            VStack(spacing: 8) {
                Text("Nothing Here Yet")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Track your subscriptions,\nfree trials, and documents.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onAdd) {
                Label("Add Subscription", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
        }
        .padding()
    }
}

// MARK: - Preview

#Preview {
    HomeView()
        .modelContainer(PreviewData.container)
}
