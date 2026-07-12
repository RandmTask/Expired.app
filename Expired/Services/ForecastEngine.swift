import Foundation

/// Minimal surface `SubscriptionItem` must expose for forecasting. Kept Foundation-only
/// and decoupled from SwiftData/CurrencyInfo so the engine below is a pure, standalone-testable
/// unit (roadmap R3 AC5).
protocol ForecastContributing {
    var id: UUID { get }
    var name: String { get }
    var itemType: ItemType { get }
    var isCancelled: Bool { get }
    var billingCycle: BillingCycle { get }
    var cost: Double? { get }
    var currency: String { get }
    func upcomingRenewalOccurrences(monthsAhead: Int, referenceDate: Date, calendar: Calendar) -> [Date]
}

extension SubscriptionItem: ForecastContributing {}

/// Pure struct: expands each contributing item's occurrences over a horizon, converts
/// currency, and returns dated amounts / monthly buckets. No SwiftUI, no SwiftData query.
///
/// Contribution rules (locked 2026-07-05): active trials count from trial-end at full
/// cost; cancelled-but-active, one-off, and document items contribute nothing.
enum ForecastEngine {
    struct Contribution: Identifiable {
        let id = UUID()
        let itemID: UUID
        let itemName: String
        let date: Date
        /// Already converted to the requested target currency.
        let amount: Double
    }

    struct MonthBucket: Identifiable {
        let id = UUID()
        let monthStart: Date
        let total: Double
    }

    static func contributions<Item: ForecastContributing>(
        for items: [Item],
        horizonDays: Int,
        referenceDate: Date = Date(),
        calendar: Calendar = .current,
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> [Contribution] {
        guard horizonDays > 0,
              let horizonEnd = calendar.date(byAdding: .day, value: horizonDays, to: referenceDate)
        else { return [] }

        // Occurrence expansion is month-granular; pad by one month past the horizon so a
        // day-granular horizon (e.g. 30/90/365 days) never truncates the last occurrence early.
        let horizonMonths = Int((Double(horizonDays) / 30.0).rounded(.up)) + 1

        var result: [Contribution] = []
        for item in items {
            guard item.itemType == .subscription,
                  !item.isCancelled,
                  item.billingCycle != .oneOff,
                  let cost = item.cost
            else { continue }

            let converted = convert(cost, item.currency, targetCurrency)
            let occurrences = item.upcomingRenewalOccurrences(
                monthsAhead: horizonMonths, referenceDate: referenceDate, calendar: calendar
            )
            for date in occurrences where date >= referenceDate && date <= horizonEnd {
                result.append(Contribution(itemID: item.id, itemName: item.name, date: date, amount: converted))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    static func total<Item: ForecastContributing>(
        for items: [Item],
        horizonDays: Int,
        referenceDate: Date = Date(),
        calendar: Calendar = .current,
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> Double {
        contributions(
            for: items, horizonDays: horizonDays, referenceDate: referenceDate, calendar: calendar,
            targetCurrency: targetCurrency, convert: convert
        ).reduce(0) { $0 + $1.amount }
    }

    /// One bucket per calendar month from `referenceDate`'s month through `monthsAhead - 1`
    /// months later, even if a month has zero contributions (needed for a continuous bar chart).
    static func monthlyBuckets<Item: ForecastContributing>(
        for items: [Item],
        monthsAhead: Int = 12,
        referenceDate: Date = Date(),
        calendar: Calendar = .current,
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> [MonthBucket] {
        guard monthsAhead > 0,
              let horizonEnd = calendar.date(byAdding: .month, value: monthsAhead, to: referenceDate)
        else { return [] }
        let horizonDays = calendar.dateComponents([.day], from: referenceDate, to: horizonEnd).day ?? monthsAhead * 31

        let all = contributions(
            for: items, horizonDays: horizonDays, referenceDate: referenceDate, calendar: calendar,
            targetCurrency: targetCurrency, convert: convert
        )

        var totals: [Date: Double] = [:]
        var order: [Date] = []
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate)) ?? referenceDate
        for _ in 0..<monthsAhead {
            totals[cursor] = 0
            order.append(cursor)
            cursor = calendar.date(byAdding: .month, value: 1, to: cursor) ?? cursor
        }
        for contribution in all {
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: contribution.date)) ?? contribution.date
            totals[monthStart, default: 0] += contribution.amount
        }
        return order.map { MonthBucket(monthStart: $0, total: totals[$0] ?? 0) }
    }

    static func biggestUpcoming<Item: ForecastContributing>(
        for items: [Item],
        horizonDays: Int,
        referenceDate: Date = Date(),
        calendar: Calendar = .current,
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        limit: Int = 5
    ) -> [Contribution] {
        contributions(
            for: items, horizonDays: horizonDays, referenceDate: referenceDate, calendar: calendar,
            targetCurrency: targetCurrency, convert: convert
        )
        .sorted { $0.amount > $1.amount }
        .prefix(limit)
        .map { $0 }
    }
}
