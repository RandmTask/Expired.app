import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PurchaseManager.self) private var purchaseManager
    @Query(filter: #Predicate<SubscriptionItem> { !$0.isArchived },
           sort: \SubscriptionItem.nextRenewalDate)
    private var allItems: [SubscriptionItem]

    /// Free tier allows up to this many active (non-archived) items.
    private static let freeItemLimit = 5

    private var subscriptionItems: [SubscriptionItem] {
        allItems.filter { $0.itemType == .subscription }
    }

    @State private var showingAdd = false
    @State private var showingImportReview = false
    @State private var editingItem: SubscriptionItem?
    @State private var searchText = ""
    @State private var importPhotoItem: PhotosPickerItem?
    @State private var importDrafts: [ScreenshotSubscriptionDraft] = []
    @State private var importWarning: String?
    @State private var importError: String?
    @State private var isAnalyzingScreenshot = false
    @State private var showPaywall = false
    @State private var undoToast: UndoToast?
    @State private var toastDismissTask: Task<Void, Never>?
#if os(iOS)
    @State private var showingPhotoImporter = false
#else
    @State private var showingScreenshotFileImporter = false
#endif

    // Sort & filter
    enum SortOrder: String, CaseIterable {
        case status      = "Status"
        case category    = "Category"
        case name        = "Name"
        case renewalDate = "Renewal Date"
        case price       = "Price"
    }
    enum FilterOption: String, CaseIterable { case all = "All"; case autoRenew = "Auto-Renew"; case trials = "Trials"; case cancelled = "Cancelled"; case expired = "Expired" }
    /// Switchable section-header treatments (A/B test for the pinned-header bleed-through).
    enum SectionHeaderStyle: String, CaseIterable {
        case scrolling       = "Non-Sticky"
        case pillTranslucent = "Pill (Translucent)"
        case pillSolid       = "Pill (Solid)"
        case pillOpaque      = "Pill (Sticky)"
        case rowSolid        = "Solid Bar"
        case rowMaterial     = "Material Bar"
    }
    @AppStorage("homeSortOrder") private var sortOrderRaw: String = SortOrder.status.rawValue
    @AppStorage("homeFilterOption") private var filterOptionRaw: String = FilterOption.all.rawValue
    @AppStorage("homeHideExpired") private var hideExpired: Bool = false
    @AppStorage("homeSectionHeaderStyle") private var headerStyleRaw: String = SectionHeaderStyle.rowSolid.rawValue
    @AppStorage("iconDisplayStyle") private var iconStyleRaw: String = IconDisplayStyle.natural.rawValue
    private var sortOrder: SortOrder { SortOrder(rawValue: sortOrderRaw) ?? .status }
    private var filterOption: FilterOption { FilterOption(rawValue: filterOptionRaw) ?? .all }
    private var headerStyle: SectionHeaderStyle { SectionHeaderStyle(rawValue: headerStyleRaw) ?? .rowSolid }

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
        subscriptionItems
            .filter(\.contributesToCurrentRecurringSpend)
            .compactMap { $0.monthlyCostConverted(to: preferredCurrency) }
            .reduce(0, +)
    }

    private var yearlyTotal: Double { monthlyTotal * 12 }

    private var displayCurrency: String { preferredCurrency }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                heroBackground.ignoresSafeArea()

                primaryContent
#if os(iOS)
                .refreshable {
                    try? await Task.sleep(for: .seconds(1))
                }
#endif

                if let undoToast {
                    VStack {
                        Spacer()
                        UndoToastView(toast: undoToast) {
                            undoToast.action()
                            dismissUndoToast()
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .animation(.spring(duration: 0.28), value: undoToast.id)
                }
            }
            .navigationTitle("Subscriptions")
            .largeNavigationTitle()
#if os(iOS)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search subscriptions")
            .photosPicker(isPresented: $showingPhotoImporter, selection: $importPhotoItem, matching: .images)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { openAddSheet() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    overflowMenu
                }
            }
            .sheet(isPresented: $showingAdd) { AddEditSubscriptionView(item: nil) }
            .sheet(item: $editingItem) { AddEditSubscriptionView(item: $0) }
            .expiredPaywallSheet(isPresented: $showPaywall)
            .sheet(isPresented: $showingImportReview) {
                ScreenshotImportReviewSheet(
                    drafts: $importDrafts,
                    warning: importWarning,
                    onApply: applyImportDrafts
                )
            }
#if os(iOS)
            .onChange(of: importPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        await analyzeScreenshot(data)
                    }
                    importPhotoItem = nil
                }
            }
#else
            .fileImporter(
                isPresented: $showingScreenshotFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                guard let url = try? result.get().first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url) {
                    Task { await analyzeScreenshot(data) }
                }
            }
#endif
            .alert("Screenshot Import", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    @ViewBuilder
    private var primaryContent: some View {
#if os(iOS)
        List {
            if !allItems.isEmpty && !isSearching {
                HeroSummaryCard(
                    monthlyTotal: monthlyTotal,
                    yearlyTotal: yearlyTotal,
                    currency: displayCurrency,
                    activeCount: subscriptionItems.filter(\.isActiveSubscription).count
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }

            if filterOption != .all {
                activeFilterChips
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            }

            iosListSections

            if allItems.isEmpty {
                EmptyStateView { openAddSheet() }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if allSectionsEmpty && filterOption != .all {
                VStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No \(filterOption.rawValue) subscriptions")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.spring(duration: 0.3), value: isSearching)
        .scrollEdgeEffectStyle(.soft, for: .top)
#else
        ScrollView {
            LazyVStack(spacing: 20) {
                if !allItems.isEmpty && !isSearching {
                    HeroSummaryCard(
                        monthlyTotal: monthlyTotal,
                        yearlyTotal: yearlyTotal,
                        currency: displayCurrency,
                        activeCount: subscriptionItems.filter(\.isActiveSubscription).count
                    )
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if filterOption != .all || hideExpired {
                    activeFilterChips
                        .padding(.horizontal)
                }

                contentSections
                    .padding(.horizontal)

                if allItems.isEmpty {
                    EmptyStateView { openAddSheet() }
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
#endif
    }

    private var activeFilterChips: some View {
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
        }
    }

#if os(iOS)
    @ViewBuilder
    private var iosListSections: some View {
        switch sortOrder {
        case .status:
            iosSection(title: "Trials Ending", icon: "clock.badge.exclamationmark", accentColor: .purple, items: trialsEnding)
            iosSection(title: "Due Soon", icon: "bell.fill", accentColor: .red, items: dueSoon)
            iosSection(title: "Cancelled but Active", icon: "calendar.badge.minus", accentColor: .orange, items: cancelledActive)
            iosSection(title: "Upcoming", icon: "calendar", accentColor: .blue, items: upcoming)
            iosSection(title: "Expired", icon: "xmark.circle", accentColor: .secondary, items: expiredSubscriptions)
            iosSection(title: "Documents - Action Needed", icon: "exclamationmark.triangle.fill", accentColor: .orange, items: urgentDocuments)
            iosSection(title: "Documents", icon: "doc.text.fill", accentColor: .indigo, items: upcomingDocuments)
        case .category:
            ForEach(categoryGroups) { group in
                iosSection(title: group.title, icon: group.icon, accentColor: .blue, items: group.items)
            }
            iosSection(title: "Documents - Action Needed", icon: "exclamationmark.triangle.fill", accentColor: .orange, items: urgentDocuments)
            iosSection(title: "Documents", icon: "doc.text.fill", accentColor: .indigo, items: upcomingDocuments)
        default:
            iosSection(title: sortOrder.rawValue, icon: sortSectionIcon, accentColor: .blue, items: flatSortedSubscriptions)
            iosSection(title: "Documents - Action Needed", icon: "exclamationmark.triangle.fill", accentColor: .orange, items: urgentDocuments)
            iosSection(title: "Documents", icon: "doc.text.fill", accentColor: .indigo, items: upcomingDocuments)
        }
    }

    @ViewBuilder
    private func iosSection(title: String, icon: String, accentColor: Color, items: [SubscriptionItem]) -> some View {
        if !items.isEmpty {
            if headerStyle == .scrolling {
                Section {
                    // Header rendered as a plain row — scrolls with content, no pinning
                    iosSectionHeader(title: title, icon: icon, accentColor: accentColor)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 4, trailing: 0))
                    ForEach(items) { item in
                        itemRow(item)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    }
                }
            } else {
                Section {
                    ForEach(items) { item in
                        itemRow(item)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    }
                } header: {
                    iosSectionHeader(title: title, icon: icon, accentColor: accentColor)
                }
            }
        }
    }

    /// Section header honoring the user-selected `SectionHeaderStyle`. Pinned plain-list
    /// headers are transparent by default, so list rows bleed through the title — the
    /// "Bar" styles fill the full row width with a solid/material background to fix that.
    @ViewBuilder
    private func iosSectionHeader(title: String, icon: String, accentColor: Color) -> some View {
        let color: Color = (accentColor == .secondary) ? .secondary : accentColor
        let pill = HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
        }

        switch headerStyle {
        case .scrolling, .pillTranslucent:
            pill
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color.opacity(0.12), in: Capsule())
                .padding(.leading, 16)
        case .pillSolid:
            pill
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color, in: Capsule())
                .padding(.leading, 16)
        case .pillOpaque:
            pill
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color.opacity(0.12), in: Capsule())
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
                .padding(.top, -20)
                .background(groupedBackground)
                .listRowInsets(EdgeInsets())
        case .rowSolid:
            pill
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color.opacity(0.12), in: Capsule())
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
                .padding(.top, -20)
                .background(groupedBackground)
                .listRowInsets(EdgeInsets())
        case .rowMaterial:
            pill
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color.opacity(0.12), in: Capsule())
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
                .padding(.top, -20)
                .background(.regularMaterial)
                .listRowInsets(EdgeInsets())
        }
    }
#endif

    @MainActor
    private func analyzeScreenshot(_ data: Data) async {
        isAnalyzingScreenshot = true
        defer { isAnalyzingScreenshot = false }

        do {
            let result = try await ScreenshotImportAnalyzer.analyze(
                imageData: data,
                existingItems: allItems
            )
            guard !result.drafts.isEmpty else {
                importError = result.warning ?? "No subscriptions were detected in that screenshot."
                return
            }
            importDrafts = result.drafts
            importWarning = result.warning
            showingImportReview = true
        } catch {
            importError = error.localizedDescription
        }
    }

    private func applyImportDrafts() {
        let selected = importDrafts.filter { $0.action != .skip }
        for draft in selected {
            switch draft.action {
            case .updateExisting:
                guard let id = draft.matchedItemID,
                      let item = allItems.first(where: { $0.id == id })
                else { continue }
                apply(draft, to: item)
            case .addNew:
                let item = SubscriptionItem(
                    itemType: .subscription,
                    name: draft.name,
                    cost: draft.cost,
                    currency: draft.currency,
                    billingCycle: .monthly,
                    nextRenewalDate: draft.renewalDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date(),
                    isAutoRenew: draft.status == .active,
                    isCancelled: draft.status != .active,
                    activeUntilDate: draft.status != .active ? draft.renewalDate : nil
                )
                item.notes = importNote(for: draft)
                modelContext.insert(item)
            case .skip:
                break
            }
        }

        try? modelContext.save()
        showingImportReview = false
        importDrafts = []
        importWarning = nil
    }

    private func apply(_ draft: ScreenshotSubscriptionDraft, to item: SubscriptionItem) {
        if let renewalDate = draft.renewalDate {
            item.nextRenewalDate = renewalDate
        }
        if let cost = draft.cost {
            item.cost = cost
            item.currency = draft.currency
        }
        if draft.status == .expired || draft.status == .expiring {
            item.isAutoRenew = false
            item.isCancelled = true
            item.activeUntilDate = draft.renewalDate ?? item.nextRenewalDate
        } else {
            item.isCancelled = false
            item.activeUntilDate = nil
            item.isAutoRenew = true
        }
        item.notes = [item.notes, importNote(for: draft)]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        item.updatedAt = Date()
    }

    private func importNote(for draft: ScreenshotSubscriptionDraft) -> String {
        var parts = ["Imported from subscription screenshot."]
        if let plan = draft.plan { parts.append("Plan: \(plan).") }
        parts.append("Confidence: \(Int(draft.confidence * 100))%.")
        return parts.joined(separator: " ")
    }

    // MARK: - Overflow menu (sort, filter, expired toggle, header style, import)

    private var overflowMenu: some View {
        Menu {
            Button {
                triggerScreenshotImport()
            } label: {
                let locked = !purchaseManager.isPremium
                Label(isAnalyzingScreenshot ? "Analyzing…" : "Import from Screenshot",
                      systemImage: isAnalyzingScreenshot ? "hourglass" : (locked ? "lock.fill" : "doc.viewfinder"))
            }
            .disabled(isAnalyzingScreenshot)

            Divider()

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
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }

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
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }

            Button {
                hideExpired.toggle()
            } label: {
                if hideExpired {
                    Text("Show Expired")
                } else {
                    Label("Show Expired", systemImage: "checkmark")
                }
            }

            Divider()

            Menu {
                ForEach(SectionHeaderStyle.allCases, id: \.self) { style in
                    Button {
                        headerStyleRaw = style.rawValue
                    } label: {
                        if headerStyle == style {
                            Label(style.rawValue, systemImage: "checkmark")
                        } else {
                            Text(style.rawValue)
                        }
                    }
                }
            } label: {
                Label("Header Style", systemImage: "textformat")
            }

            Menu {
                ForEach(IconDisplayStyle.allCases, id: \.self) { style in
                    Button {
                        iconStyleRaw = style.rawValue
                    } label: {
                        let isCurrent = iconStyleRaw == style.rawValue
                        if isCurrent {
                            Label(style.rawValue, systemImage: "checkmark")
                        } else {
                            Text(style.rawValue)
                        }
                    }
                }
            } label: {
                Label("Icon Style", systemImage: "photo")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
        }
#if os(macOS)
        .menuIndicator(.hidden)
#endif
    }

    private func triggerScreenshotImport() {
        // AI / screenshot import is a Pro feature (also enforced server-side by the proxy).
        guard purchaseManager.isPremium else {
            showPaywall = true
            return
        }
#if os(iOS)
        showingPhotoImporter = true
#else
        showingScreenshotFileImporter = true
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
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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

    private func openAddSheet() {
        // Free tier is capped at `freeItemLimit` active items; adding beyond that is Pro.
        if allItems.count >= Self.freeItemLimit && !purchaseManager.isPremium {
            showPaywall = true
            return
        }
        editingItem = nil
        showingAdd = true
    }

    private func deleteItem(_ item: SubscriptionItem) {
        let snapshot = SubscriptionSnapshot(item: item)
        withAnimation {
            NotificationManager.shared.removeAll(for: item)
            modelContext.delete(item)
            try? modelContext.save()
        }
        showUndoToast(message: "Deleted \(snapshot.name)", undoTitle: "Undo Delete") {
            restore(snapshot)
        }
    }

    private func toggleCancelled(_ item: SubscriptionItem) {
        let itemID = item.id
        let previousCancelled = item.isCancelled
        let previousAutoRenew = item.isAutoRenew
        let previousActiveUntil = item.activeUntilDate
        let didCancel = !item.isCancelled
        withAnimation {
            item.isCancelled.toggle()
            if item.isCancelled {
                item.isAutoRenew = false
                item.activeUntilDate = item.nextRelevantDate
            } else {
                item.activeUntilDate = nil
            }
            item.updatedAt = Date()
            try? modelContext.save()
        }
        showUndoToast(message: "\(didCancel ? "Cancelled" : "Reinstated") \(item.name)",
                      undoTitle: didCancel ? "Undo Cancel" : "Undo Reinstate") {
            restoreCancellation(
                itemID: itemID,
                isCancelled: previousCancelled,
                isAutoRenew: previousAutoRenew,
                activeUntilDate: previousActiveUntil
            )
        }
    }

    private func archiveItem(_ item: SubscriptionItem) {
        let name = item.name
        withAnimation {
            item.isArchived = true
            item.updatedAt = Date()
            try? modelContext.save()
        }
        showUndoToast(message: "Archived \(name)", undoTitle: "Undo Archive") {
            restoreArchive(item)
        }
    }

    private func showUndoToast(message: String, undoTitle: String, action: @escaping () -> Void) {
        toastDismissTask?.cancel()
        undoToast = UndoToast(message: message, undoTitle: undoTitle, action: action)
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run { dismissUndoToast() }
        }
    }

    private func dismissUndoToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        withAnimation(.easeOut(duration: 0.2)) {
            undoToast = nil
        }
    }

    private func restore(_ snapshot: SubscriptionSnapshot) {
        withAnimation {
            modelContext.insert(snapshot.restoredItem())
            try? modelContext.save()
        }
    }

    private func restoreCancellation(
        itemID: UUID,
        isCancelled: Bool,
        isAutoRenew: Bool,
        activeUntilDate: Date?
    ) {
        guard let item = allItems.first(where: { $0.id == itemID }) else { return }
        withAnimation {
            item.isCancelled = isCancelled
            item.isAutoRenew = isAutoRenew
            item.activeUntilDate = activeUntilDate
            item.updatedAt = Date()
            try? modelContext.save()
        }
    }

    private func restoreArchive(_ item: SubscriptionItem) {
        withAnimation {
            item.isArchived = false
            item.updatedAt = Date()
            try? modelContext.save()
        }
    }
}

private struct UndoToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let undoTitle: String
    let action: () -> Void

    static func == (lhs: UndoToast, rhs: UndoToast) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
private struct SubscriptionSnapshot {
    let itemType: ItemType
    let name: String
    let provider: String
    let iconSource: IconSource
    let iconData: Data?
    let cost: Double?
    let currency: String
    let billingCycle: BillingCycle
    let nextRenewalDate: Date
    let trialEndDate: Date?
    let expiryDate: Date?
    let isAutoRenew: Bool
    let isCancelled: Bool
    let activeUntilDate: Date?
    let personName: String
    let paymentMethod: String
    let emailUsed: String
    let phoneNumber: String
    let notes: String
    let url: String
    let documentNumber: String?
    let validFromDate: Date?
    let categoryRaw: String?
    let startDate: Date?
    let isArchived: Bool
    let notifications: [NotificationSnapshot]

    init(item: SubscriptionItem) {
        itemType = item.itemType
        name = item.name
        provider = item.provider
        iconSource = item.iconSource
        iconData = item.iconData
        cost = item.cost
        currency = item.currency
        billingCycle = item.billingCycle
        nextRenewalDate = item.nextRenewalDate
        trialEndDate = item.trialEndDate
        expiryDate = item.expiryDate
        isAutoRenew = item.isAutoRenew
        isCancelled = item.isCancelled
        activeUntilDate = item.activeUntilDate
        personName = item.personName
        paymentMethod = item.paymentMethod
        emailUsed = item.emailUsed
        phoneNumber = item.phoneNumber
        notes = item.notes
        url = item.url
        documentNumber = item.documentNumber
        validFromDate = item.validFromDate
        categoryRaw = item.categoryRaw
        startDate = item.startDate
        isArchived = item.isArchived
        notifications = item.notificationsList.map(NotificationSnapshot.init(rule:))
    }

    func restoredItem() -> SubscriptionItem {
        let item = SubscriptionItem(
            itemType: itemType,
            name: name,
            provider: provider,
            iconSource: iconSource,
            iconData: iconData,
            cost: cost,
            currency: currency,
            billingCycle: billingCycle,
            nextRenewalDate: nextRenewalDate,
            trialEndDate: trialEndDate,
            expiryDate: expiryDate,
            isAutoRenew: isAutoRenew,
            isCancelled: isCancelled,
            activeUntilDate: activeUntilDate,
            personName: personName,
            paymentMethod: paymentMethod,
            emailUsed: emailUsed,
            phoneNumber: phoneNumber,
            notes: notes,
            url: url,
            documentNumber: documentNumber,
            validFromDate: validFromDate,
            startDate: startDate,
            notifications: notifications.map { $0.restoredRule() }
        )
        item.categoryRaw = categoryRaw
        item.isArchived = isArchived
        item.updatedAt = Date()
        return item
    }
}

@MainActor
private struct NotificationSnapshot {
    let offsetType: NotificationOffsetType
    let value: Int
    let isCritical: Bool
    let customDate: Date?

    init(rule: NotificationRule) {
        offsetType = rule.offsetType
        value = rule.value
        isCritical = rule.isCritical
        customDate = rule.customDate
    }

    func restoredRule() -> NotificationRule {
        NotificationRule(offsetType: offsetType, value: value, isCritical: isCritical, customDate: customDate)
    }
}


private struct UndoToastView: View {
    let toast: UndoToast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Button(toast.undoTitle, action: onUndo)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.blue)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 13)
        .background(.black.opacity(0.86), in: Capsule())
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
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

// MARK: - Screenshot Import Review

struct ScreenshotImportReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var drafts: [ScreenshotSubscriptionDraft]
    var warning: String?
    let onApply: () -> Void

    private var selectedCount: Int {
        drafts.filter { $0.action != .skip }.count
    }

    var body: some View {
        NavigationStack {
            List {
                if let warning {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(warning)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach($drafts) { $draft in
                        ScreenshotImportDraftRow(draft: $draft)
                    }
                } header: {
                    Text("Detected")
                } footer: {
                    Text("Possible duplicates default to updating the existing subscription. Review each row before applying.")
                }
            }
            .navigationTitle("Import Screenshot")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply() }
                        .fontWeight(.semibold)
                        .disabled(selectedCount == 0)
                }
            }
        }
    }
}

private struct ScreenshotImportDraftRow: View {
    @Binding var draft: ScreenshotSubscriptionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: draft.hasMatch ? "arrow.triangle.2.circlepath.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(draft.hasMatch ? .blue : .green)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.name)
                        .font(.system(size: 16, weight: .semibold))
                    if let plan = draft.plan {
                        Text(plan)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    if let matched = draft.matchedItemName {
                        Text("Possible duplicate: \(matched)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                }

                Spacer()
            }

            Picker("", selection: $draft.action) {
                ForEach(availableActions, id: \.self) { action in
                    Text(action.rawValue).tag(action)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 6)
    }

    private var availableActions: [ScreenshotSubscriptionDraft.ImportAction] {
        draft.hasMatch ? [.updateExisting, .addNew, .skip] : [.addNew, .skip]
    }

    private var summary: String {
        var parts: [String] = []
        if let renewalDate = draft.renewalDate {
            let verb = draft.status == .expiring ? "Expires" : "Renews"
            parts.append("\(verb) \(renewalDate.formatted(date: .abbreviated, time: .omitted))")
        }
        if let cost = draft.cost {
            parts.append(CurrencyInfo.format(cost, code: draft.currency))
        }
        parts.append("\(Int(draft.confidence * 100))% confidence")
        return parts.joined(separator: " • ")
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
