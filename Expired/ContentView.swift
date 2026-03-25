import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Subscriptions", systemImage: "creditcard.fill") {
                HomeView()
            }

            Tab("Timeline", systemImage: "calendar") {
                TimelineView()
            }

            Tab("Insights", systemImage: "chart.bar.fill") {
                InsightsView()
            }
        }
    }
}

// MARK: - Timeline View

struct TimelineView: View {
    @Query(sort: \SubscriptionItem.nextRenewalDate) private var allItems: [SubscriptionItem]

    private var upcoming: [SubscriptionItem] {
        allItems
            .filter { $0.daysUntilRenewal >= 0 }
            .sorted { $0.nextRelevantDate < $1.nextRelevantDate }
    }

    var body: some View {
        NavigationStack {
            timelineContent
                .navigationTitle("Timeline")
                .navigationBarTitleDisplayMode(.large)
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
            List {
                ForEach(upcoming) { item in
                    TimelineRow(item: item)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(groupedBackground)
        }
    }
}

struct TimelineRow: View {
    let item: SubscriptionItem

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)

            SubscriptionRowView(item: item)
        }
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
    @Query private var allItems: [SubscriptionItem]

    private var activeItems: [SubscriptionItem] {
        allItems.filter {
            if case .expired = $0.status { return false }
            return true
        }
    }

    private var monthlyTotal: Double {
        activeItems.compactMap(\.monthlyCost).reduce(0, +)
    }

    private var yearlyTotal: Double { monthlyTotal * 12 }

    private var autoRenewCount: Int { activeItems.filter(\.isAutoRenew).count }
    private var trialCount: Int { activeItems.filter(\.isTrial).count }

    private var cancelledCount: Int {
        allItems.filter {
            if case .cancelledButActive = $0.status { return true }
            return false
        }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    costRow
                    countsRow
                    if !activeItems.isEmpty {
                        costBreakdown
                    }
                    Spacer(minLength: 40)
                }
                .padding(.top, 12)
            }
            .background(groupedBackground.ignoresSafeArea())
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var costRow: some View {
        HStack(spacing: 12) {
            InsightCard(title: "Monthly Cost",
                        value: monthlyTotal.formatted(.currency(code: "AUD")),
                        icon: "calendar",
                        color: .blue)
            InsightCard(title: "Yearly Cost",
                        value: yearlyTotal.formatted(.currency(code: "AUD")),
                        icon: "chart.line.uptrend.xyaxis",
                        color: .indigo)
        }
        .padding(.horizontal)
    }

    private var countsRow: some View {
        HStack(spacing: 12) {
            InsightCard(title: "Auto-Renewing",
                        value: "\(autoRenewCount)",
                        icon: "arrow.clockwise",
                        color: .green)
            InsightCard(title: "Free Trials",
                        value: "\(trialCount)",
                        icon: "gift.fill",
                        color: .purple)
            InsightCard(title: "Cancelled",
                        value: "\(cancelledCount)",
                        icon: "xmark.circle",
                        color: .orange)
        }
        .padding(.horizontal)
    }

    private var costBreakdown: some View {
        let sorted = activeItems
            .sorted { ($0.monthlyCost ?? 0) > ($1.monthlyCost ?? 0) }
            .prefix(5)
        let maxCost = activeItems.compactMap(\.monthlyCost).max() ?? 1

        return VStack(alignment: .leading, spacing: 10) {
            Text("By Cost")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(Array(sorted)) { item in
                    CostBarRow(item: item, maxCost: maxCost)
                }
            }
        }
        .padding(.horizontal)
    }
}

struct InsightCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Spacer()
            }
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct CostBarRow: View {
    let item: SubscriptionItem
    let maxCost: Double

    var body: some View {
        HStack(spacing: 12) {
            ItemIconView(item: item, size: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    if let monthly = item.monthlyCost {
                        Text(monthly.formatted(.currency(code: item.currency)))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                GeometryReader { geo in
                    let fraction = max(0, min(1, (item.monthlyCost ?? 0) / maxCost))
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: geo.size.width)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Cross-platform grouped background

private var groupedBackground: Color {
#if os(iOS)
    Color(uiColor: .systemGroupedBackground)
#else
    Color(nsColor: .windowBackgroundColor)
#endif
}

// MARK: - Preview

#Preview {
    ContentView()
        .modelContainer(PreviewData.container)
}
