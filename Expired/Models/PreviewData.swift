import Foundation
import SwiftData

@MainActor
struct PreviewData {
    static var inMemoryContainer: ModelContainer = {
        let schema = Schema([SubscriptionItem.self, NotificationRule.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])

        let samples = sampleSubscriptions
        for item in samples {
            container.mainContext.insert(item)
        }
        return container
    }()

    static var sampleSubscriptions: [SubscriptionItem] {
        let now = Date()
        let calendar = Calendar.current

        let netflix = SubscriptionItem(
            name: "Netflix",
            provider: "Netflix",
            iconSource: .system,
            cost: 22.99,
            currency: "USD",
            billingCycle: .monthly,
            nextRenewalDate: calendar.date(byAdding: .day, value: 6, to: now)!,
            trialEndDate: nil,
            isAutoRenew: true,
            isCancelled: false,
            paymentMethod: "Amex •••• 1234",
            emailUsed: "me@example.com",
            notes: "Premium plan"
        )

        let audible = SubscriptionItem(
            name: "Audible",
            provider: "Audible",
            iconSource: .system,
            cost: 14.95,
            currency: "USD",
            billingCycle: .monthly,
            nextRenewalDate: calendar.date(byAdding: .day, value: 15, to: now)!,
            trialEndDate: nil,
            isAutoRenew: false,
            isCancelled: false,
            paymentMethod: "Visa •••• 8891",
            emailUsed: "me@icloud.com"
        )

        let spotifyTrial = SubscriptionItem(
            name: "Spotify",
            provider: "Spotify",
            iconSource: .system,
            cost: 0.0,
            currency: "USD",
            billingCycle: .monthly,
            nextRenewalDate: calendar.date(byAdding: .day, value: 12, to: now)!,
            trialEndDate: calendar.date(byAdding: .day, value: 3, to: now)!,
            isAutoRenew: true,
            isCancelled: false
        )
        spotifyTrial.notifications = [
            NotificationRule(offsetType: .daysBefore, value: 3),
            NotificationRule(offsetType: .daysBefore, value: 1)
        ]

        let gymCancelled = SubscriptionItem(
            name: "Gym",
            provider: "Local Gym",
            iconSource: .system,
            cost: 45.00,
            currency: "USD",
            billingCycle: .monthly,
            nextRenewalDate: calendar.date(byAdding: .day, value: 28, to: now)!,
            trialEndDate: nil,
            isAutoRenew: false,
            isCancelled: true,
            activeUntilDate: calendar.date(byAdding: .day, value: 20, to: now)!,
            paymentMethod: "Mastercard •••• 1122"
        )

        return [netflix, audible, spotifyTrial, gymCancelled]
    }
}
