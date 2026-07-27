import SwiftUI
import SwiftData

/// R4 Page B — one compact, inline-editable row per grid selection. Never pushes N
/// sequential `AddEditSubscriptionView` sheets (unbearable past a couple of items).
/// Commit is a single insert loop + one `save()` + one `NotificationManager.refreshAll`
/// call, matching `_shared/onboarding-conventions.md`'s "commit as one transaction" rule.
struct QuickSetupPage: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var existingItems: [SubscriptionItem]

    @Binding var selectedTileIDs: [String]
    let reminderOffsetDays: Int
    let currency: String
    let onCommit: () -> Void
    let onSkip: () -> Void

    struct Row: Identifiable {
        let tile: AppCatalog.OnboardingTile
        var id: String { tile.id }
        var costText: String = ""
        var billingCycle: BillingCycle = .monthly
        var dayOfMonth: Int = Calendar.current.component(.day, from: Date())
        var yearlyMonth: Int = Calendar.current.component(.month, from: Date())
    }

    @State private var rows: [Row] = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Quick Setup")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Cost is optional — fill it in later if you're not sure.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(rows) { row in
                        rowCard(row)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            footer
        }
        .onAppear { syncRows() }
        .onChange(of: selectedTileIDs) { _, _ in syncRows() }
    }

    // MARK: - Rows

    private func syncRows() {
        let tilesByID = Dictionary(uniqueKeysWithValues: AppCatalog.onboardingTiles().map { ($0.id, $0) })
        rows = selectedTileIDs.compactMap { id in
            if let existing = rows.first(where: { $0.id == id }) { return existing }
            guard let tile = tilesByID[id] else { return nil }
            return Row(tile: tile)
        }
    }

    private func removeRow(_ row: Row) {
        Haptics.fire(.light)
        selectedTileIDs.removeAll { $0 == row.id }
    }

    private func binding(for row: Row) -> Binding<Row> {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else {
            return .constant(row)
        }
        return $rows[index]
    }

    @ViewBuilder
    private func rowCard(_ row: Row) -> some View {
        let rowBinding = binding(for: row)
        FormCard {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    tileIcon(row.tile)
                        .frame(width: 36, height: 36)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text(row.tile.name)
                        .font(.system(size: 15, weight: .semibold))

                    Spacer()

                    Button {
                        removeRow(row)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                FormDivider()

                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Text(CurrencyInfo.symbol(for: currency))
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        TextField("Cost", text: rowBinding.costText)
                            .font(.system(size: 15))
#if os(iOS)
                            .keyboardType(.decimalPad)
#endif
                            .frame(width: 56)
                    }

                    Spacer()

                    Menu {
                        ForEach(BillingCycle.allCases.filter { $0 != .custom }, id: \.self) { cycle in
                            Button(cycle.rawValue) { rowBinding.wrappedValue.billingCycle = cycle }
                        }
                    } label: {
                        Text(row.billingCycle.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                    }
#if os(macOS)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
#endif

                    if row.billingCycle == .yearly {
                        Menu {
                            ForEach(1...12, id: \.self) { month in
                                Button(Calendar.current.monthSymbols[month - 1]) {
                                    rowBinding.wrappedValue.yearlyMonth = month
                                }
                            }
                        } label: {
                            Text(Calendar.current.shortMonthSymbols[row.yearlyMonth - 1])
                                .font(.system(size: 13, weight: .semibold))
                        }
#if os(macOS)
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
#endif
                    }

                    Menu {
                        ForEach(1...31, id: \.self) { day in
                            Button("\(day)") { rowBinding.wrappedValue.dayOfMonth = day }
                        }
                    } label: {
                        Text("Renews \(ordinal(row.dayOfMonth))")
                            .font(.system(size: 13, weight: .semibold))
                    }
#if os(macOS)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
#endif
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func tileIcon(_ tile: AppCatalog.OnboardingTile) -> some View {
        if let symbolName = tile.symbolName {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
        } else if let iconData = tile.iconData, let image = platformImage(from: iconData) {
            Image(platformImage: image).resizable().scaledToFill()
        } else {
            Text(tile.name.prefix(1).uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func ordinal(_ day: Int) -> String {
        let suffix: String
        switch (day % 10, day % 100) {
        case (1, let tens) where tens != 11: suffix = "st"
        case (2, let tens) where tens != 12: suffix = "nd"
        case (3, let tens) where tens != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(day)\(suffix)"
    }

    // MARK: - Footer / commit

    private var footer: some View {
        Button {
            Haptics.fire(.success)
            commit()
        } label: {
            Text(rows.isEmpty ? "Skip for now" : "Add \(rows.count) item\(rows.count == 1 ? "" : "s")")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.glassProminent)
        .padding(.horizontal, 32)
        .padding(.top, 4)
    }

    private func commit() {
        guard !rows.isEmpty else {
            onSkip()
            return
        }

        let existingNames = Set(existingItems.map { AppCatalog.canonicalName($0.name) })

        for row in rows {
            guard !existingNames.contains(AppCatalog.canonicalName(row.tile.name)) else { continue }

            let cost = Double(row.costText.replacingOccurrences(of: ",", with: "."))
            let renewalDate = nextRenewalDate(
                dayOfMonth: row.dayOfMonth,
                yearlyMonth: row.billingCycle == .yearly ? row.yearlyMonth : nil
            )

            let item = SubscriptionItem(
                itemType: row.tile.itemType,
                name: row.tile.name,
                iconSource: row.tile.iconData != nil ? .customImage : .system,
                iconData: row.tile.iconData,
                cost: cost,
                currency: currency,
                billingCycle: row.billingCycle,
                nextRenewalDate: renewalDate,
                expiryDate: row.tile.itemType == .document ? renewalDate : nil,
                isAutoRenew: row.tile.itemType == .subscription,
                category: SubscriptionCategory(rawValue: row.tile.category),
                notifications: [NotificationRule(offsetType: .daysBefore, value: reminderOffsetDays)]
            )
            modelContext.insert(item)
        }

        try? modelContext.save()
        let ctx = modelContext
        Task { await NotificationManager.shared.refreshAll(context: ctx) }
        onCommit()
    }

    /// Derives the next future occurrence from a day-of-month (and, for yearly billing,
    /// a month) rather than requiring a full date — `nextRenewalDate` stays non-optional
    /// with no schema change (R4 locked decision).
    private func nextRenewalDate(dayOfMonth: Int, yearlyMonth: Int?, referenceDate: Date = Date(), calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        if let yearlyMonth { comps.month = yearlyMonth }
        comps.day = dayOfMonth

        guard var candidate = calendar.date(from: comps) else { return referenceDate }
        if candidate < referenceDate {
            if yearlyMonth != nil {
                comps.year = (comps.year ?? 0) + 1
            } else {
                comps.month = (comps.month ?? 1) + 1
            }
            candidate = calendar.date(from: comps) ?? candidate
        }
        return candidate
    }
}
