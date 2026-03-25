import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SubscriptionItem.nextRenewalDate, order: .forward) private var items: [SubscriptionItem]

    @State private var showingAddSheet = false

    private let dueSoonWindowDays = 7

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    summaryCard
                    section(title: "Due Soon", items: dueSoonItems)
                    section(title: "Trials Ending", items: trialItems)
                    section(title: "Upcoming", items: upcomingItems)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(backgroundView)
            .navigationTitle("Expired")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddEditSubscriptionView()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var summaryCard: some View {
        let monthlyTotal = items.compactMap { $0.monthlyCost }.reduce(0, +)
        let yearlyTotal = items.compactMap { $0.yearlyCost }.reduce(0, +)

        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Monthly Total")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(.secondary)
                Text(currencyLabel(monthlyTotal))
                    .font(.custom("Avenir Next", size: 22))
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Yearly Total")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(.secondary)
                Text(currencyLabel(yearlyTotal))
                    .font(.custom("Avenir Next", size: 22))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)
        )
    }

    private func section(title: String, items: [SubscriptionItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.custom("Avenir Next", size: 20))
                Spacer()
                Text("\(items.count)")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Text("Nothing here yet")
                    .font(.custom("Avenir Next", size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(items) { item in
                        SubscriptionRowView(item: item)
                    }
                }
            }
        }
    }

    private var dueSoonItems: [SubscriptionItem] {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: dueSoonWindowDays, to: now) ?? now
        return items.filter { !$0.isTrial && $0.nextRelevantDate <= cutoff }
    }

    private var trialItems: [SubscriptionItem] {
        items.filter { $0.isTrial }
            .sorted { $0.nextRelevantDate < $1.nextRelevantDate }
    }

    private var upcomingItems: [SubscriptionItem] {
        let now = Date()
        return items.filter { !$0.isTrial && $0.nextRelevantDate > now }
    }

    private func currencyLabel(_ value: Double) -> String {
        let formatted = String(format: "%.2f", value)
        return "USD \(formatted)"
    }

    private var backgroundView: some View {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                Color(.systemGray6),
                Color(.systemGray5)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

#Preview {
    HomeView()
        .modelContainer(PreviewData.inMemoryContainer)
}
