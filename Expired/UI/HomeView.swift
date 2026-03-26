import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SubscriptionItem.nextRenewalDate) private var allItems: [SubscriptionItem]

    private var subscriptionItems: [SubscriptionItem] {
        allItems.filter { $0.itemType == .subscription }
    }

    private var documentItems: [SubscriptionItem] {
        allItems.filter { $0.itemType == .document }
            .sorted { $0.nextRelevantDate < $1.nextRelevantDate }
    }

    @State private var showingAdd = false
    @State private var editingItem: SubscriptionItem?
    @State private var searchText = ""
    @State private var showSearch = false

    // MARK: - Filtered groups

    private var visibleItems: [SubscriptionItem] {
        guard !searchText.isEmpty else { return allItems }
        return allItems.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.provider.localizedCaseInsensitiveContains(searchText) ||
            $0.emailUsed.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var visibleSubscriptions: [SubscriptionItem] {
        visibleItems.filter { $0.itemType == .subscription }
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

    // Documents split by urgency
    private var urgentDocuments: [SubscriptionItem] {
        visibleDocuments.filter { $0.urgency == .critical || $0.urgency == .warning || $0.urgency == .expired }
    }

    private var upcomingDocuments: [SubscriptionItem] {
        visibleDocuments.filter { $0.urgency == .normal }
    }

    @AppStorage("preferredCurrency") private var preferredCurrency = "AUD"

    private var monthlyTotal: Double {
        subscriptionItems.compactMap(\.monthlyCost).reduce(0, +)
    }

    private var yearlyTotal: Double { monthlyTotal * 12 }

    /// The most-used currency among subscriptions, falling back to preferredCurrency
    private var displayCurrency: String {
        let codes = subscriptionItems.map(\.currency)
        let counts = Dictionary(codes.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max(by: { $0.value < $1.value })?.key ?? preferredCurrency
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // Mesh gradient hero backdrop
                heroBackground
                    .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 20) {
                        // Hero summary card
                        if !allItems.isEmpty {
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
                        }

                        Group {
                            // Subscriptions
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

                            // Documents
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
                        .padding(.horizontal)

                        if allItems.isEmpty {
                            EmptyStateView { showingAdd = true }
                                .padding(.top, 60)
                        }

                        Spacer(minLength: 100)
                    }
                    .padding(.top, 8)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            .navigationTitle("Expired")
            .largeNavigationTitle()
            .searchable(text: $searchText, isPresented: $showSearch, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .sheet(isPresented: $showingAdd) { AddEditSubscriptionView(item: nil) }
            .sheet(item: $editingItem) { AddEditSubscriptionView(item: $0) }
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
            // Section header pill — solid tinted background for legibility
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
