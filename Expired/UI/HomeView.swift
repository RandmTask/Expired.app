import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SubscriptionItem.nextRenewalDate) private var allItems: [SubscriptionItem]

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

    // Due within 14 days, not cancelled, not trial
    private var dueSoon: [SubscriptionItem] {
        visibleItems.filter {
            !$0.isCancelled &&
            !$0.isTrial &&
            $0.daysUntilRenewal >= 0 &&
            $0.daysUntilRenewal <= 14
        }
    }

    private var trialsEnding: [SubscriptionItem] {
        visibleItems.filter { $0.isTrial }
            .sorted { ($0.trialEndDate ?? .distantFuture) < ($1.trialEndDate ?? .distantFuture) }
    }

    private var cancelledActive: [SubscriptionItem] {
        visibleItems.filter {
            if case .cancelledButActive = $0.status { return true }
            return false
        }
    }

    private var upcoming: [SubscriptionItem] {
        visibleItems.filter {
            !$0.isCancelled &&
            !$0.isTrial &&
            $0.daysUntilRenewal > 14
        }
    }

    private var expired: [SubscriptionItem] {
        visibleItems.filter {
            if case .expired = $0.status { return true }
            return false
        }
    }

    // MARK: - Cost totals

    private var monthlyTotal: Double {
        allItems.compactMap(\.monthlyCost).reduce(0, +)
    }

    private var yearlyTotal: Double {
        monthlyTotal * 12
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 24) {
                    // Summary card
                    if !allItems.isEmpty {
                        SummaryCardView(
                            monthlyTotal: monthlyTotal,
                            yearlyTotal: yearlyTotal,
                            activeCount: allItems.filter { if case .expired = $0.status { return false }; return true }.count
                        )
                        .padding(.horizontal)
                    }

                    // Trials ending — highest urgency
                    if !trialsEnding.isEmpty {
                        SectionView(title: "Trials Ending", icon: "clock.badge.exclamationmark", accentColor: .purple) {
                            ForEach(trialsEnding) { item in
                                itemRow(item)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Due soon
                    if !dueSoon.isEmpty {
                        SectionView(title: "Due Soon", icon: "bell.fill", accentColor: .red) {
                            ForEach(dueSoon) { item in
                                itemRow(item)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Cancelled but still active
                    if !cancelledActive.isEmpty {
                        SectionView(title: "Cancelled but Active", icon: "calendar.badge.minus", accentColor: .orange) {
                            ForEach(cancelledActive) { item in
                                itemRow(item)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Upcoming
                    if !upcoming.isEmpty {
                        SectionView(title: "Upcoming", icon: "calendar", accentColor: .blue) {
                            ForEach(upcoming) { item in
                                itemRow(item)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Expired
                    if !expired.isEmpty {
                        SectionView(title: "Expired", icon: "xmark.circle", accentColor: .gray) {
                            ForEach(expired) { item in
                                itemRow(item)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Empty state
                    if allItems.isEmpty {
                        EmptyStateView {
                            showingAdd = true
                        }
                        .padding(.top, 60)
                    }

                    Spacer(minLength: 100)
                }
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Subscriptions")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, isPresented: $showSearch, prompt: "Search subscriptions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddEditSubscriptionView(item: nil)
            }
            .sheet(item: $editingItem) { item in
                AddEditSubscriptionView(item: item)
            }
        }
    }

    // MARK: - Row with swipe actions

    @ViewBuilder
    private func itemRow(_ item: SubscriptionItem) -> some View {
        SubscriptionRowView(item: item)
            .onTapGesture {
                editingItem = item
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteItem(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    toggleCancelled(item)
                } label: {
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
        withAnimation {
            modelContext.delete(item)
        }
    }

    private func toggleCancelled(_ item: SubscriptionItem) {
        withAnimation {
            item.isCancelled.toggle()
            if item.isCancelled {
                item.activeUntilDate = item.nextRenewalDate
            } else {
                item.activeUntilDate = nil
            }
            item.updatedAt = Date()
        }
    }
}

// MARK: - Section Container

struct SectionView<Content: View>: View {
    let title: String
    let icon: String
    let accentColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                content
            }
        }
    }
}

// MARK: - Summary Card

struct SummaryCardView: View {
    let monthlyTotal: Double
    let yearlyTotal: Double
    let activeCount: Int

    var body: some View {
        HStack(spacing: 0) {
            summaryItem(
                label: "Monthly",
                value: monthlyTotal.formatted(.currency(code: "AUD"))
            )

            Divider()
                .frame(height: 36)

            summaryItem(
                label: "Yearly",
                value: yearlyTotal.formatted(.currency(code: "AUD"))
            )

            Divider()
                .frame(height: 36)

            summaryItem(
                label: "Active",
                value: "\(activeCount)"
            )
        }
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func summaryItem(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.blue.opacity(0.7))
            }

            VStack(spacing: 8) {
                Text("No Subscriptions Yet")
                    .font(.system(size: 20, weight: .semibold))
                Text("Track your subscriptions,\nfree trials, and documents.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onAdd) {
                Label("Add Subscription", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.blue, in: Capsule())
            }
        }
        .padding()
    }
}

// MARK: - Preview

#Preview {
    HomeView()
        .modelContainer(PreviewData.container)
}
