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
    @Query(sort: \SubscriptionItem.nextRenewalDate) private var allItems: [SubscriptionItem]

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
    @Query private var allItems: [SubscriptionItem]
    @AppStorage("preferredCurrency") private var preferredCurrency = "AUD"

    private var activeItems: [SubscriptionItem] {
        allItems.filter { if case .expired = $0.status { return false }; return true }
    }
    private var monthlyTotal: Double { activeItems.compactMap(\.monthlyCost).reduce(0, +) }
    private var yearlyTotal: Double { monthlyTotal * 12 }

    private var displayCurrency: String {
        let codes = activeItems.map(\.currency)
        let counts = Dictionary(codes.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max(by: { $0.value < $1.value })?.key ?? preferredCurrency
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
                    costRow
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

    private var costRow: some View {
        HStack(spacing: 12) {
            GlassInsightCard(title: "Monthly", value: CurrencyInfo.format(monthlyTotal, code: displayCurrency), icon: "calendar", color: .blue)
            GlassInsightCard(title: "Yearly", value: CurrencyInfo.format(yearlyTotal, code: displayCurrency), icon: "chart.line.uptrend.xyaxis", color: .indigo)
        }
        .padding(.horizontal)
    }

    private var countsRow: some View {
        HStack(spacing: 12) {
            GlassInsightCard(title: "Auto-Renewing", value: "\(autoRenewCount)", icon: "arrow.clockwise", color: .green)
            GlassInsightCard(title: "Free Trials", value: "\(trialCount)", icon: "gift.fill", color: .purple)
            GlassInsightCard(title: "Cancelled", value: "\(cancelledCount)", icon: "xmark.circle", color: .orange)
        }
        .padding(.horizontal)
    }

    private var costBreakdown: some View {
        let sorted = activeItems.sorted { ($0.monthlyCost ?? 0) > ($1.monthlyCost ?? 0) }.prefix(6)
        let maxCost = activeItems.compactMap(\.monthlyCost).max() ?? 1

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "list.number")
                    .font(.system(size: 11, weight: .bold))
                Text("TOP BY COST")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
            }
            .foregroundStyle(.secondary)
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
    let maxCost: Double

    var body: some View {
        HStack(spacing: 12) {
            ItemIconView(item: item, size: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    if let monthly = item.monthlyCost {
                        Text(monthly.formatted(.currency(code: item.currency)))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                GeometryReader { geo in
                    let fraction = max(0, min(1, (item.monthlyCost ?? 0) / maxCost))
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
    @State private var showRestartAlert = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $iCloudSyncEnabled) {
                        Label("iCloud Sync", systemImage: "icloud")
                    }
                    .onChange(of: iCloudSyncEnabled) { _, _ in
                        showRestartAlert = true
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("When enabled, your data syncs across all devices signed into the same iCloud account. Requires an iCloud account and internet connection. Restart the app after changing this setting.")
                }
            }
            .navigationTitle("Settings")
            .largeNavigationTitle()
            .alert("Restart Required", isPresented: $showRestartAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please restart the app for the iCloud sync change to take effect.")
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .modelContainer(PreviewData.container)
}
