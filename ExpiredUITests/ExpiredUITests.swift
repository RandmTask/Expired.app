//
//  ExpiredUITests.swift
//  ExpiredUITests
//
//  Created by Deon O'Brien on 29/7/2026.
//
//  Despite the target name (inherited from Xcode's default naming when the
//  target was created via File > New > Target > Unit Testing Bundle — rename
//  the target/scheme to ExpiredTests in Xcode's Project Navigator if desired),
//  this is a plain XCTest unit test bundle, not a UI test bundle.
//
//  Covers ROADMAP.md R3 AC5: ForecastEngine's four contribution rules.

import XCTest
@testable import Expired

/// Minimal `ForecastContributing` test double. Lets each test control exactly
/// which occurrences an item produces, independent of `SubscriptionItem`'s own
/// occurrence-stepping logic (that logic has its own coverage need, but R3's
/// AC5 is specifically about `ForecastEngine`'s filtering/bucketing/aggregation).
private struct MockItem: ForecastContributing {
    let id = UUID()
    let name: String
    var itemType: ItemType = .subscription
    var isCancelled: Bool = false
    var billingCycle: BillingCycle = .monthly
    var cost: Double?
    var currency: String = "AUD"
    var occurrences: [Date] = []

    func upcomingRenewalOccurrences(monthsAhead: Int, referenceDate: Date, calendar: Calendar) -> [Date] {
        occurrences
    }
}

final class ExpiredUITests: XCTestCase {

    private let calendar = Calendar.current
    /// Identity conversion — currency conversion itself is `CurrencyInfo`'s concern, not `ForecastEngine`'s.
    private let identityConvert: (Double, String, String) -> Double = { amount, _, _ in amount }

    private func daysFromNow(_ days: Int, from reference: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: days, to: reference)!
    }

    // MARK: - AC1: monthly $10 sub -> ~$10 / $30 / $120 across 30/90/365 days

    func testMonthlySubscriptionScalesAcrossHorizons() {
        let reference = Date()
        // Renews every ~30 days starting a few days out, so 30d catches exactly 1,
        // 90d catches 3, 365d catches 12 (cycle-alignment tolerance applies).
        let occurrences = stride(from: 5, to: 400, by: 30).map { daysFromNow($0, from: reference) }
        let item = MockItem(name: "Monthly $10", cost: 10, occurrences: occurrences)

        let total30 = ForecastEngine.total(for: [item], horizonDays: 30, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)
        let total90 = ForecastEngine.total(for: [item], horizonDays: 90, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)
        let total365 = ForecastEngine.total(for: [item], horizonDays: 365, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)

        XCTAssertEqual(total30, 10, accuracy: 0.01)
        XCTAssertEqual(total90, 30, accuracy: 0.01)
        // 365 days / 30-day cycle ≈ 12.17 occurrences before the horizon edge; assert the
        // documented cycle-alignment tolerance rather than a brittle exact multiple.
        XCTAssertEqual(total365, 120, accuracy: 20)
    }

    // MARK: - AC2: yearly sub renewing in 40 days appears in 90/365 but not 30

    func testYearlySubscriptionAppearsOnlyAtLongerHorizons() {
        let reference = Date()
        let item = MockItem(name: "Yearly", billingCycle: .yearly, cost: 99, occurrences: [daysFromNow(40, from: reference)])

        let total30 = ForecastEngine.total(for: [item], horizonDays: 30, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)
        let total90 = ForecastEngine.total(for: [item], horizonDays: 90, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)
        let total365 = ForecastEngine.total(for: [item], horizonDays: 365, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)

        XCTAssertEqual(total30, 0, "A renewal 40 days out must not appear in a 30-day forecast")
        XCTAssertEqual(total90, 99, accuracy: 0.01)
        XCTAssertEqual(total365, 99, accuracy: 0.01)
    }

    // MARK: - AC3: trial converting in 10 days contributes from its trial-end date

    func testTrialContributesFromTrialEndDate() {
        let reference = Date()
        let trialEnd = daysFromNow(10, from: reference)
        let item = MockItem(name: "Trial converting soon", cost: 15, occurrences: [trialEnd])

        let contributions = ForecastEngine.contributions(for: [item], horizonDays: 30, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)

        XCTAssertEqual(contributions.count, 1)
        XCTAssertEqual(contributions.first?.amount ?? -1, 15, accuracy: 0.01)
        XCTAssertEqual(
            calendar.dateComponents([.day], from: reference, to: contributions.first?.date ?? .distantPast).day, 10,
            "Contribution date must be the trial-end date, not today or the eventual renewal date"
        )
    }

    // MARK: - AC4: cancelled-but-active and one-off items contribute nothing

    func testCancelledItemContributesNothing() {
        let reference = Date()
        let item = MockItem(name: "Cancelled but active", isCancelled: true, cost: 100, occurrences: [daysFromNow(5, from: reference)])

        let total = ForecastEngine.total(for: [item], horizonDays: 30, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)

        XCTAssertEqual(total, 0, "A cancelled-but-active item must never contribute to the forecast, even with an in-window occurrence")
    }

    func testOneOffItemContributesNothing() {
        let reference = Date()
        let item = MockItem(name: "One-off purchase", billingCycle: .oneOff, cost: 200, occurrences: [daysFromNow(5, from: reference)])

        let total = ForecastEngine.total(for: [item], horizonDays: 30, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)

        XCTAssertEqual(total, 0, "A one-off item must never contribute to the recurring-spend forecast")
    }

    func testDocumentItemContributesNothing() {
        let reference = Date()
        let item = MockItem(name: "Passport", itemType: .document, cost: 300, occurrences: [daysFromNow(5, from: reference)])

        let total = ForecastEngine.total(for: [item], horizonDays: 30, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)

        XCTAssertEqual(total, 0, "Document items have no cost relevance to the forecast")
    }

    func testMissingCostContributesNothing() {
        let reference = Date()
        let item = MockItem(name: "No cost set", cost: nil, occurrences: [daysFromNow(5, from: reference)])

        let total = ForecastEngine.total(for: [item], horizonDays: 30, referenceDate: reference, targetCurrency: "AUD", convert: identityConvert)

        XCTAssertEqual(total, 0)
    }
}
