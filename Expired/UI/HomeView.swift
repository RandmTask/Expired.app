import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import Photos
#endif

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
    @State private var importPhotoItems: [PhotosPickerItem] = []
    @State private var importDrafts: [ScreenshotSubscriptionDraft] = []
    @State private var importWarning: String?
    @State private var importDebugLog: String?
    @State private var importError: String?
    @State private var isAnalyzingScreenshot = false
    @State private var analyzingMessageIndex = 0
    @State private var analyzingMessages: [String] = Self.shuffledAnalyzingMessages()
    @State private var importedPhotoIdentifiers: [String] = []
    @State private var pendingScreenshotDeletionIdentifiers: [String] = []
    @State private var showingDeleteImportedScreenshotPrompt = false
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
    @AppStorage("appStoreRegion") private var appStoreRegion = "auto"

    private var monthlyTotal: Double {
        subscriptionItems
            .filter(\.contributesToCurrentRecurringSpend)
            .compactMap { $0.monthlyCostConverted(to: preferredCurrency) }
            .reduce(0, +)
    }

    private var yearlyTotal: Double { monthlyTotal * 12 }

    private var displayCurrency: String { preferredCurrency }

    private var appStoreRegionCode: String {
        let trimmed = appStoreRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "auto" {
            return Locale.current.region?.identifier.uppercased() ?? "US"
        }
        return trimmed.uppercased()
    }

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

                if isAnalyzingScreenshot {
                    analyzingScreenshotOverlay
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(10)
                }
            }
            .animation(.spring(duration: 0.28), value: isAnalyzingScreenshot)
            .task(id: isAnalyzingScreenshot) {
                guard isAnalyzingScreenshot else { return }
                resetAnalyzingMessages()
                while !Task.isCancelled && isAnalyzingScreenshot {
                    try? await Task.sleep(for: .seconds(3.4))
                    guard !Task.isCancelled && isAnalyzingScreenshot else { break }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        advanceAnalyzingMessage()
                    }
                }
            }
            .navigationTitle("Subscriptions")
            .largeNavigationTitle()
#if os(iOS)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search subscriptions")
            .photosPicker(isPresented: $showingPhotoImporter, selection: $importPhotoItems, maxSelectionCount: 0, matching: .images)
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
                    debugLog: importDebugLog,
                    onApply: applyImportDrafts
                )
            }
#if os(iOS)
            .confirmationDialog(
                pendingScreenshotDeletionIdentifiers.count == 1 ? "Delete imported photo?" : "Delete imported photos?",
                isPresented: $showingDeleteImportedScreenshotPrompt,
                titleVisibility: .visible
            ) {
                Button("Move to Recently Deleted", role: .destructive) {
                    deleteImportedScreenshots()
                }
                Button(pendingScreenshotDeletionIdentifiers.count == 1 ? "Keep Photo" : "Keep Photos", role: .cancel) {
                    pendingScreenshotDeletionIdentifiers = []
                }
            } message: {
                Text("The import is complete. You can remove the imported image\(pendingScreenshotDeletionIdentifiers.count == 1 ? "" : "s") from Photos now.")
            }
#endif
#if os(iOS)
            .onChange(of: importPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    await analyzeSelectedPhotos(newItems)
                    importPhotoItems = []
                }
            }
#else
            .fileImporter(
                isPresented: $showingScreenshotFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                guard let urls = try? result.get(), !urls.isEmpty else { return }
                let imageData = urls.compactMap { url -> Data? in
                    guard url.startAccessingSecurityScopedResource() else { return nil }
                    defer { url.stopAccessingSecurityScopedResource() }
                    return try? Data(contentsOf: url)
                }
                if !imageData.isEmpty {
                    Task { await analyzeScreenshots(imageData) }
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

    private var analyzingScreenshotOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()

            VStack(spacing: 16) {
                AnalyzingScanIcon()

                VStack(spacing: 5) {
                    Text(analyzingMessage)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: analyzingMessage)
                    Text("AI is sorting subscriptions from your screenshot.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
            .frame(maxWidth: 310)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
            .padding(.horizontal, 24)
        }
    }

    private static let analyzingLoadingMessages = [
        "Parsing the fine print",
        "Sussing out the details",
        "Deciphering the subtext",
        "Untangling the nodes",
        "Consulting the oracle",
        "Correlating the coordinates",
        "Defragmenting the thought stream",
        "Extrapolating the obvious",
        "Synthesizing the signals",
        "Distilling the core logic",
        "Percolating the data",
        "Herding the digital cats",
        "Reticulating the splines",
        "Recombobulating the data stream",
        "Calibrating the flux capacitor",
        "Polishing the pixels",
        "Consulting the magic 8-ball",
        "Untwisting the hyperdrive",
        "Un-fuddling the logic",
        "Chasing down the loose ends",
        "Excavating the details",
        "Forging the framework",
        "Assembling the scaffolding",
        "Tightening the loose bolts",
        "Lubricating the gears",
        "Stoking the engine room",
        "Routing the pathways",
        "Mining the deep layers",
        "Casting the foundation",
        "Welding the connections",
        "Brewing the data",
        "Fermenting the feedback",
        "Stirring the secret sauce",
        "Simmering the code base",
        "Marinating the variables",
        "Cultivating the results",
        "Infusing the logic gates",
        "Crystallizing the concepts",
        "Sprouting new connections",
        "Steeping the telemetry",
        "Scouting the perimeter",
        "Mapping the uncharted zones",
        "Aligning the constellations",
        "Scanning the stratosphere",
        "Traversing the network grid",
        "Navigating the labyrinth",
        "Plumbing the depths",
        "Sifting through the ether",
        "Unearthing hidden patterns",
        "Tuning into the frequency"
    ]

    private static func shuffledAnalyzingMessages(avoiding firstMessageToAvoid: String? = nil) -> [String] {
        var messages = analyzingLoadingMessages.shuffled()
        guard
            let firstMessageToAvoid,
            messages.count > 1,
            messages.first == firstMessageToAvoid,
            let replacementIndex = messages.dropFirst().firstIndex(where: { $0 != firstMessageToAvoid })
        else {
            return messages
        }

        messages.swapAt(0, replacementIndex)
        return messages
    }

    private var analyzingMessage: String {
        guard !analyzingMessages.isEmpty else { return Self.analyzingLoadingMessages[0] }
        return analyzingMessages[analyzingMessageIndex]
    }

    private func resetAnalyzingMessages() {
        analyzingMessages = Self.shuffledAnalyzingMessages()
        analyzingMessageIndex = 0
    }

    private func advanceAnalyzingMessage() {
        guard !analyzingMessages.isEmpty else {
            resetAnalyzingMessages()
            return
        }

        guard analyzingMessageIndex < analyzingMessages.count - 1 else {
            let previousMessage = analyzingMessages[analyzingMessageIndex]
            analyzingMessages = Self.shuffledAnalyzingMessages(avoiding: previousMessage)
            analyzingMessageIndex = 0
            return
        }

        analyzingMessageIndex += 1
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
        await analyzeScreenshots([data])
    }

#if os(iOS)
    @MainActor
    private func analyzeSelectedPhotos(_ items: [PhotosPickerItem]) async {
        importedPhotoIdentifiers = items.compactMap(\.itemIdentifier)
        var imageData: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                imageData.append(data)
            }
        }
        await analyzeScreenshots(imageData)
    }
#endif

    @MainActor
    private func analyzeScreenshots(_ images: [Data]) async {
        guard !images.isEmpty else { return }
        isAnalyzingScreenshot = true
        defer { isAnalyzingScreenshot = false }

        do {
            var allDrafts: [ScreenshotSubscriptionDraft] = []
            var warnings: [String] = []
            var debugDetails: [String] = []

            for data in images {
                let result = try await ScreenshotImportAnalyzer.analyze(
                    imageData: data,
                    existingItems: allItems
                )
                allDrafts.append(contentsOf: result.drafts)
                if let warning = result.warning, !warning.isEmpty {
                    warnings.append(warning)
                }
                if let debugDetail = result.debugDetail, !debugDetail.isEmpty {
                    debugDetails.append(debugDetail)
                }
            }

            // Track whether AI is degrading over repeated tries — a lone blip isn't
            // worth surfacing, but a sustained streak means something's actually down.
            let consecutiveFallbacks = warnings.isEmpty
                ? { ScreenshotAIHealthLog.recordSuccess(); return 0 }()
                : ScreenshotAIHealthLog.recordFallback()

            let uniqueDrafts = deduplicatedImportDrafts(allDrafts)
            guard !uniqueDrafts.isEmpty else {
                importError = warnings.first ?? "No subscriptions were detected in the selected images."
                return
            }

            importDrafts = uniqueDrafts
            var warningText = warnings.isEmpty ? nil : Array(Set(warnings)).joined(separator: "\n")
            if consecutiveFallbacks >= ScreenshotAIHealthLog.alertThreshold {
                let streakNote = "AI import failed again — that's \(consecutiveFallbacks) in a row. Check your connection, or look for an app update."
                warningText = [warningText, streakNote].compactMap { $0 }.joined(separator: "\n")
            }
            importWarning = warningText
            importDebugLog = debugDetails.isEmpty ? nil : buildDebugLog(details: Array(Set(debugDetails)), consecutiveFallbacks: consecutiveFallbacks)
            showingImportReview = true
            Haptics.fire(.success)

            Task {
                await enrichVisibleDraftsWithAppStoreIcons(uniqueDrafts)
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Assembles the copyable diagnostic log for an AI-import failure — everything
    /// needed to root-cause it (server-reported entitlement check, local RevenueCat
    /// identity/premium state, failure streak, app version, timestamp) in one paste,
    /// without the user needing to attach an Xcode console.
    private func buildDebugLog(details: [String], consecutiveFallbacks: Int) -> String {
        var lines: [String] = ["Expired AI import debug log"]
        let formatter = ISO8601DateFormatter()
        lines.append("time: \(formatter.string(from: Date()))")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            lines.append("appVersion: \(version) (\(build))")
        }
        lines.append("consecutiveFallbacks: \(consecutiveFallbacks)")
        lines.append("localPurchaseManager: isPremium=\(purchaseManager.isPremium) appUserID=\(purchaseManager.appUserID ?? "nil")")
        lines.append(contentsOf: details)
        return lines.joined(separator: "\n")
    }

    private func deduplicatedImportDrafts(_ drafts: [ScreenshotSubscriptionDraft]) -> [ScreenshotSubscriptionDraft] {
        var bestByKey: [String: ScreenshotSubscriptionDraft] = [:]
        for draft in drafts {
            let key = ScreenshotImportAnalyzer.canonicalName(draft.name)
            guard !key.isEmpty else { continue }
            if let existingKey = bestByKey.keys.first(where: { importDraftKeysMatch($0, key) }),
               let existing = bestByKey[existingKey] {
                bestByKey[existingKey] = preferredImportDraft(existing, draft)
            } else {
                bestByKey[key] = draft
            }
        }

        return drafts.compactMap { draft in
            let key = ScreenshotImportAnalyzer.canonicalName(draft.name)
            guard let best = bestByKey.first(where: { importDraftKeysMatch($0.key, key) })?.value,
                  best.id == draft.id else {
                return nil
            }
            return best
        }
    }

    private func importDraftKeysMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs) { return true }
        return importDraftSimilarity(lhs, rhs) >= 0.78
    }

    private func importDraftSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var matrix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { matrix[i][0] = i }
        for j in 0...b.count { matrix[0][j] = j }

        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + cost
                )
            }
        }

        return 1 - (Double(matrix[a.count][b.count]) / Double(max(a.count, b.count)))
    }

    private func preferredImportDraft(
        _ lhs: ScreenshotSubscriptionDraft,
        _ rhs: ScreenshotSubscriptionDraft
    ) -> ScreenshotSubscriptionDraft {
        if lhs.hasMatch != rhs.hasMatch { return lhs.hasMatch ? lhs : rhs }

        switch (lhs.renewalDate, rhs.renewalDate) {
        case let (left?, right?):
            if left != right { return right > left ? rhs : lhs }
        case (nil, _?):
            return rhs
        case (_?, nil):
            return lhs
        case (nil, nil):
            break
        }

        switch (lhs.cost, rhs.cost) {
        case (nil, _?):
            return rhs
        case (_?, nil):
            return lhs
        default:
            return rhs.confidence > lhs.confidence ? rhs : lhs
        }
    }

    private func enrichVisibleDraftsWithAppStoreIcons(_ drafts: [ScreenshotSubscriptionDraft]) async {
        await withTaskGroup(of: (UUID, FaviconFetcher.AppStoreIconMatch?).self) { group in
            for draft in drafts {
                group.addTask {
                    let match = await FaviconFetcher.fetchAppStoreIconMatch(for: draft.name, country: appStoreRegionCode)
                    return (draft.id, match)
                }
            }

            for await (id, match) in group {
                guard let match else { continue }
                await MainActor.run {
                    guard let index = importDrafts.firstIndex(where: { $0.id == id }) else { return }
                    importDrafts[index].appStoreURL = match.appStoreURL
                    importDrafts[index].iconData = match.artworkData
                }
            }
        }
    }

    private func applyImportDrafts() {
        let selected = importDrafts.filter { $0.action != .skip }
        Haptics.fire(selected.isEmpty ? .light : .success)
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
                    provider: draft.plan ?? "",
                    iconSource: draft.iconData == nil ? .system : .customImage,
                    iconData: draft.iconData,
                    cost: draft.cost,
                    currency: draft.currency,
                    billingCycle: draft.billingCycle,
                    nextRenewalDate: draft.renewalDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date(),
                    isAutoRenew: draft.status == .active,
                    isCancelled: draft.status != .active,
                    activeUntilDate: draft.status != .active ? draft.renewalDate : nil,
                    url: draft.appStoreURL ?? ""
                )
                item.notes = importNote(for: draft)
                modelContext.insert(item)
            case .skip:
                break
            }
        }

        try? modelContext.save()
#if os(iOS)
        if !importedPhotoIdentifiers.isEmpty {
            pendingScreenshotDeletionIdentifiers = importedPhotoIdentifiers
            showingDeleteImportedScreenshotPrompt = true
        }
        importedPhotoIdentifiers = []
#endif
        showingImportReview = false
        importDrafts = []
        importWarning = nil
        importDebugLog = nil
    }

    private func apply(_ draft: ScreenshotSubscriptionDraft, to item: SubscriptionItem) {
        if let renewalDate = draft.renewalDate {
            item.nextRenewalDate = renewalDate
        }
        if let cost = draft.cost {
            item.cost = cost
            item.currency = draft.currency
        }
        if draft.cost != nil || draft.billingCycle != .monthly {
            item.billingCycle = draft.billingCycle
        }
        if let iconData = draft.iconData, item.iconData == nil {
            item.iconData = iconData
            item.iconSource = .customImage
        }
        if let appStoreURL = draft.appStoreURL, item.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.url = appStoreURL
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

#if os(iOS)
    private func deleteImportedScreenshots() {
        let identifiers = pendingScreenshotDeletionIdentifiers
        pendingScreenshotDeletionIdentifiers = []
        guard !identifiers.isEmpty else { return }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    Haptics.fire(.warning)
                    importError = "Photos permission is needed to delete the imported images."
                }
                return
            }

            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            guard assets.count > 0 else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                Task { @MainActor in
                    if success {
                        Haptics.fire(.success)
                    } else if let error {
                        Haptics.fire(.error)
                        importError = error.localizedDescription
                    }
                }
            }
        }
    }
#endif

    // MARK: - Overflow menu (sort, filter, expired toggle, header style, import)

    private var overflowMenu: some View {
        Menu {
            Button {
                Haptics.fire(.light)
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
                        Haptics.fire(.selectionChanged)
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
                        Haptics.fire(.selectionChanged)
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
                    Haptics.fire(.selectionChanged)
                    hideExpired.toggle()
                } label: {
                    if hideExpired {
                        Text("Show Expired")
                    } else {
                        Label("Show Expired", systemImage: "checkmark")
                    }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }

            Divider()

            Menu {
                ForEach(SectionHeaderStyle.allCases, id: \.self) { style in
                    Button {
                        Haptics.fire(.selectionChanged)
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
                        Haptics.fire(.selectionChanged)
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
            Haptics.fire(.warning)
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
            .contextMenu {
                Button {
                    Haptics.fire(.light)
                    editingItem = item
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button {
                    duplicateItem(item)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }

                Button {
                    archiveItem(item)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }

                Button {
                    toggleCancelled(item)
                } label: {
                    Label(
                        item.isCancelled ? "Reinstate" : "Cancel",
                        systemImage: item.isCancelled ? "arrow.uturn.backward.circle" : "xmark"
                    )
                }

                Button(role: .destructive) {
                    deleteItem(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
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
            Haptics.fire(.warning)
            showPaywall = true
            return
        }
        Haptics.fire(.light)
        editingItem = nil
        showingAdd = true
    }

    private func deleteItem(_ item: SubscriptionItem) {
        Haptics.fire(.error)
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
        Haptics.fire(item.isCancelled ? .success : .light)
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
        Haptics.fire(.light)
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

    private func duplicateItem(_ item: SubscriptionItem) {
        Haptics.fire(.medium)
        let duplicate = SubscriptionSnapshot(item: item).duplicatedItem()
        withAnimation {
            modelContext.insert(duplicate)
            try? modelContext.save()
        }
        showUndoToast(message: "Duplicated \(item.name)", undoTitle: "Undo Duplicate") {
            deleteDuplicate(duplicate)
        }
    }

    private func deleteDuplicate(_ item: SubscriptionItem) {
        Haptics.fire(.light)
        withAnimation {
            NotificationManager.shared.removeAll(for: item)
            modelContext.delete(item)
            try? modelContext.save()
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
        Haptics.fire(.success)
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
        Haptics.fire(.light)
        withAnimation {
            item.isCancelled = isCancelled
            item.isAutoRenew = isAutoRenew
            item.activeUntilDate = activeUntilDate
            item.updatedAt = Date()
            try? modelContext.save()
        }
    }

    private func restoreArchive(_ item: SubscriptionItem) {
        Haptics.fire(.success)
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

    func duplicatedItem() -> SubscriptionItem {
        let item = SubscriptionItem(
            itemType: itemType,
            name: "\(name) Copy",
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
        item.isArchived = false
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

private struct AnalyzingScanIcon: View {
    @State private var isScanning = false
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.14))
                .frame(width: 78, height: 78)

            Circle()
                .stroke(Color.blue.opacity(isPulsing ? 0.08 : 0.28), lineWidth: 1.5)
                .frame(width: 78, height: 78)
                .scaleEffect(isPulsing ? 1.12 : 0.92)

            scanTile

            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .offset(x: 27, y: -25)
                .scaleEffect(isPulsing ? 1.08 : 0.94)
        }
        .frame(width: 88, height: 88)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
            withAnimation(.smooth(duration: 2.6).repeatForever(autoreverses: true)) {
                isScanning = true
            }
        }
    }

    private var scanTile: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.blue.opacity(0.16))
            .frame(width: 52, height: 52)
            .overlay {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.blue.opacity(0.9))
            }
            .overlay {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.35),
                                Color.blue.opacity(0.75),
                                Color.white.opacity(0.35),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 42, height: 3)
                    .offset(y: isScanning ? 20 : -20)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
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
    var debugLog: String?
    let onApply: () -> Void

    @State private var currentIndex = 0
    @State private var dragOffset: CGFloat = 0
    @State private var showingPriceEditor = false
    @State private var isAdvancing = false
    @State private var dragThresholdDirection = 0
    @State private var stackPromotionProgress: CGFloat = 0

    private var handledCount: Int { drafts.prefix(currentIndex).count }
    private var addedDrafts: [ScreenshotSubscriptionDraft] { drafts.filter { $0.action == .addNew } }
    private var selectedCount: Int { drafts.filter { $0.action != .skip }.count }
    private var addedCount: Int { addedDrafts.count }
    private var addedMonthlyTotal: Double {
        addedDrafts.compactMap { draft in
            draft.cost.map { $0 * draft.billingCycle.monthlyMultiplier }
        }.reduce(0, +)
    }
    private var summaryCurrency: String { addedDrafts.first?.currency ?? drafts.first?.currency ?? Locale.current.currency?.identifier ?? "USD" }
    private var isComplete: Bool { currentIndex >= drafts.count }
    private var hasNextCard: Bool { !isComplete && currentIndex < drafts.count - 1 }

    var body: some View {
        NavigationStack {
            ZStack {
                groupedBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    if let warning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(warning)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button {
                                copyImportWarning(debugLog ?? warning)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy detailed debug log")
                            .help("Copies a detailed technical log for troubleshooting — not the message shown above.")
                        }
                        .padding(.horizontal, 18)
                        // 44pt wasn't enough on device (iOS 26's floating toolbar
                        // capsules don't reserve normal nav-bar safe-area space) —
                        // going generous rather than guess again with another small bump.
                        .padding(.top, 100)
                    }

                    Text(isComplete ? "Ready to import" : title)
                        .font(.system(size: 32, weight: .bold))
                        .padding(.horizontal, 28)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    progressStrip
                        .padding(.horizontal, 28)

                    ZStack {
                        if hasNextCard, drafts.indices.contains(currentIndex + 1) {
                            ScreenshotImportCard(
                                draft: $drafts[currentIndex + 1],
                                dragOffset: 0,
                                onEditPrice: {}
                            )
                            .frame(maxWidth: 330)
                            .scaleEffect(nextCardScale)
                            .offset(x: nextCardOffsetX, y: nextCardOffsetY)
                            .opacity(nextCardOpacity)
                            .allowsHitTesting(false)
                            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: nextCardPromotionProgress)
                            .transition(.opacity)
                        }

                        if isComplete {
                            completionView
                                .transition(.scale.combined(with: .opacity))
                        } else if drafts.indices.contains(currentIndex) {
                            ScreenshotImportCard(
                                draft: $drafts[currentIndex],
                                dragOffset: dragOffset,
                                onEditPrice: { showingPriceEditor = true }
                            )
                            .frame(maxWidth: 330)
                            .rotationEffect(.degrees(Double(dragOffset / 22)))
                            .offset(x: dragOffset)
                            .id(drafts[currentIndex].id)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        dragOffset = value.translation.width
                                        updateDragThresholdFeedback(for: value.translation.width)
                                    }
                                    .onEnded { value in
                                        finishDrag(value.translation.width)
                                    }
                            )
                            .animation(.spring(duration: 0.28), value: dragOffset)
                            .transition(.asymmetric(insertion: .identity,
                                                    removal: .scale(scale: 0.94).combined(with: .opacity)))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 510)

                    actionButtons
                        .padding(.top, 4)

                    HStack {
                        Text("\(addedCount) added · \(CurrencyInfo.format(addedMonthlyTotal, code: summaryCurrency))/mo")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Done") { onApply() }
                            .font(.system(size: 17, weight: .semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(.blue.opacity(isComplete && selectedCount > 0 ? 1 : 0.35))
                            .disabled(!isComplete || selectedCount == 0)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                }
                .padding(.top, 18)
            }
            .navigationTitle("")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Undo") { undoLast() }
                        .disabled(currentIndex == 0 || isAdvancing)
                }
            }
            .sheet(isPresented: $showingPriceEditor) {
                if drafts.indices.contains(currentIndex) {
                    ScreenshotImportPriceEditor(draft: $drafts[currentIndex])
                        .presentationDetents([.medium])
                }
            }
        }
    }

    private var title: String {
        currentIndex == 0 ? "Swipe to sort" : "Subscription \(currentIndex + 1) of \(drafts.count)"
    }

    private var nextCardPromotionProgress: CGFloat {
        max(stackPromotionProgress, min(abs(dragOffset) / 170, 1) * 0.72)
    }

    private var nextCardScale: CGFloat {
        0.94 + (0.06 * nextCardPromotionProgress)
    }

    private var nextCardOffsetX: CGFloat {
        34 * (1 - nextCardPromotionProgress)
    }

    private var nextCardOffsetY: CGFloat {
        16 * (1 - nextCardPromotionProgress)
    }

    private var nextCardOpacity: Double {
        Double(0.68 + (0.32 * nextCardPromotionProgress))
    }

    private var progressStrip: some View {
        HStack(spacing: 8) {
            ForEach(drafts.indices, id: \.self) { index in
                Capsule()
                    .fill(progressColor(for: index))
                    .frame(height: 5)
            }
        }
    }

    private func progressColor(for index: Int) -> Color {
        if index < handledCount {
            return drafts[index].action == .skip ? .red.opacity(0.75) : .green
        }
        if index == currentIndex && !isComplete { return .blue }
        return .secondary.opacity(0.18)
    }

    private var completionView: some View {
        VStack(spacing: 14) {
            Image(systemName: selectedCount == 0 ? "xmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 62, weight: .semibold))
                .foregroundStyle(selectedCount == 0 ? Color.secondary : Color.green)
            Text(selectedCount == 0 ? "Nothing selected" : "\(selectedCount) ready")
                .font(.system(size: 24, weight: .bold))
            Text("Tap Done to apply your choices.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 330, minHeight: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var actionButtons: some View {
        HStack(spacing: 34) {
            Button {
                Haptics.fire(.light)
                markCurrent(.skip)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(width: 72, height: 72)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
            }
            .disabled(isComplete || isAdvancing)

            Button {
                acceptCurrent()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 92, height: 92)
                    .background(.green, in: Circle())
                    .shadow(color: .green.opacity(0.28), radius: 18, y: 10)
            }
            .disabled(isComplete || isAdvancing)

            Button {
                markCurrent(.addNew)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 72, height: 72)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
            }
            .opacity(canAddDuplicateAsNew ? 1 : 0)
            .disabled(!canAddDuplicateAsNew || isAdvancing)
        }
        .frame(maxWidth: .infinity)
    }

    private var canAddDuplicateAsNew: Bool {
        drafts.indices.contains(currentIndex) && drafts[currentIndex].hasMatch && !isComplete
    }

    private func finishDrag(_ width: CGFloat) {
        dragThresholdDirection = 0
        if width < -110 {
            markCurrent(.skip)
        } else if width > 110 {
            acceptCurrent()
        } else {
            dragOffset = 0
        }
    }

    private func acceptCurrent() {
        guard drafts.indices.contains(currentIndex) else { return }
        markCurrent(drafts[currentIndex].hasMatch ? .updateExisting : .addNew)
    }

    private func markCurrent(_ action: ScreenshotSubscriptionDraft.ImportAction) {
        guard drafts.indices.contains(currentIndex), !isAdvancing else { return }
        isAdvancing = true
        drafts[currentIndex].action = action

        let exitOffset: CGFloat = action == .skip ? -620 : 620
        Haptics.fire(action == .skip ? .light : .success)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            dragOffset = exitOffset
            stackPromotionProgress = 1
        }

        Task {
            try? await Task.sleep(for: .milliseconds(240))
            await MainActor.run {
                currentIndex += 1
                dragOffset = 0
                stackPromotionProgress = 0
                isAdvancing = false
                dragThresholdDirection = 0
            }
        }
    }

    private func undoLast() {
        guard currentIndex > 0, !isAdvancing else { return }
        Haptics.fire(.light)
        withAnimation(.spring(duration: 0.3)) {
            currentIndex -= 1
            drafts[currentIndex].action = drafts[currentIndex].hasMatch ? .updateExisting : .addNew
            dragOffset = 0
            stackPromotionProgress = 0
            dragThresholdDirection = 0
        }
    }

    private func copyImportWarning(_ text: String) {
#if os(iOS)
        UIPasteboard.general.string = text
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
        Haptics.fire(.light)
    }

    private func updateDragThresholdFeedback(for width: CGFloat) {
        let direction: Int
        if width > 110 {
            direction = 1
        } else if width < -110 {
            direction = -1
        } else {
            direction = 0
        }

        if direction != 0 && direction != dragThresholdDirection {
            Haptics.fire(.selectionChanged)
        }
        dragThresholdDirection = direction
    }
}

private struct ScreenshotImportCard: View {
    @Binding var draft: ScreenshotSubscriptionDraft
    let dragOffset: CGFloat
    let onEditPrice: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                if dragOffset < 0 {
                    Spacer()
                    statusStamp
                } else {
                    statusStamp
                    Spacer()
                }
            }
            .frame(height: 34)

            iconView

            VStack(spacing: 5) {
                Text(draft.name)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                if let plan = draft.plan {
                    Text(plan)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.gray)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
            }

            Button {
                Haptics.fire(.light)
                onEditPrice()
            } label: {
                if isPricePlaceholder {
                    HStack(spacing: 7) {
                        Image(systemName: "dollarsign.circle")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Set price")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Color.blue)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 14)
                    .background(Color.blue.opacity(0.10), in: Capsule())
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(priceText)
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(draft.billingCycle.shortSuffix)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.gray)
                    }
                }
            }
            .buttonStyle(.plain)

            Divider()

            HStack {
                Text(dateLabel)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.gray)
                Spacer()
                Text(dateText)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.black)
            }

            if draft.hasMatch {
                HStack(spacing: 10) {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                    Text("Possible duplicate")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.brown)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(height: 480)
        .background(cardBackground)
        .shadow(color: .black.opacity(0.10), radius: 28, y: 16)
    }

    @ViewBuilder
    private var iconView: some View {
        if let data = draft.iconData, let image = platformImage(from: data) {
#if os(iOS)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
#else
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
#endif
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: fallbackIconColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 76, height: 76)
                .overlay(
                    Group {
                        if let symbol = serviceFallbackSymbol {
                            Image(systemName: symbol)
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.white)
                        } else {
                            Text(initials)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                )
        }
    }

    private var statusStamp: some View {
        Text(stampText)
            .font(.system(size: 16, weight: .heavy))
            .tracking(1.5)
            .foregroundStyle(stampColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(stampColor, lineWidth: 2)
            )
            .rotationEffect(.degrees(stampRotation))
            .opacity(abs(dragOffset) > 45 ? 1 : 0)
    }

    private var stampText: String { dragOffset < 0 ? "SKIP" : (draft.hasMatch ? "UPDATE" : "ADD") }
    private var stampColor: Color { dragOffset < 0 ? .red : .green }
    private var stampRotation: Double { dragOffset < 0 ? 4 : -4 }
    private var tintProgress: Double { min(Double(abs(dragOffset)) / 150, 1) }
    private var cardTint: Color { dragOffset < 0 ? .red : .green }
    private var cardTintOpacity: Double { tintProgress * 0.48 }
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(cardTint.opacity(cardTintOpacity))
            )
    }
    private var initials: String {
        draft.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var serviceFallbackSymbol: String? {
        let lower = draft.name.lowercased()
        if lower.contains("icloud") { return "icloud.fill" }
        if lower.contains("fitness") { return "figure.run" }
        if lower.contains("news") { return "newspaper.fill" }
        if lower.contains("apple tv") { return "play.tv.fill" }
        return nil
    }

    private var fallbackIconColors: [Color] {
        let lower = draft.name.lowercased()
        if lower.contains("icloud") { return [.cyan, .blue] }
        if lower.contains("fitness") { return [.orange, .red] }
        if lower.contains("news") { return [.red, .pink] }
        if lower.contains("apple tv") { return [.gray, .black] }
        return [.pink, .orange]
    }

    private var priceText: String {
        if let cost = draft.cost {
            return CurrencyInfo.format(cost, code: draft.currency)
        }
        return "Set price"
    }
    private var isPricePlaceholder: Bool { draft.cost == nil }
    private var dateLabel: String {
        draft.status == .active ? "Next charge" : "Access until"
    }
    private var dateText: String {
        draft.renewalDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown"
    }
}

private struct ScreenshotImportPriceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: ScreenshotSubscriptionDraft
    @State private var priceText = ""
    @State private var currency = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Price", text: $priceText)
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif
#if os(iOS)
                    TextField("Currency", text: $currency)
                        .textInputAutocapitalization(.characters)
#else
                    TextField("Currency", text: $currency)
#endif
                    Picker("Billing", selection: $draft.billingCycle) {
                        ForEach(BillingCycle.allCases, id: \.self) { cycle in
                            Text(cycle.rawValue).tag(cycle)
                        }
                    }
                }
            }
            .navigationTitle("Price")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                priceText = draft.cost.map { String(format: "%.2f", $0) } ?? ""
                currency = draft.currency
            }
        }
    }

    private func save() {
        let normalized = priceText.replacingOccurrences(of: ",", with: ".")
        draft.cost = Double(normalized)
        let trimmedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !trimmedCurrency.isEmpty {
            draft.currency = trimmedCurrency
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
