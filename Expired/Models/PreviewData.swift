import Foundation
import SwiftData

@MainActor
enum PreviewData {

    // MARK: - Container

    static let container: ModelContainer = {
        let schema = Schema([SubscriptionItem.self, NotificationRule.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: config)

        for item in makeSamples() {
            container.mainContext.insert(item)
        }
        return container
    }()

    static func makeSamples() -> [SubscriptionItem] {
        [
            // Netflix — active, auto-renew
            {
                let item = SubscriptionItem(
                    name: "Netflix",
                    provider: "Netflix Inc.",
                    iconSource: .system,
                    cost: 22.99,
                    currency: "AUD",
                    billingCycle: .monthly,
                    nextRenewalDate: Calendar.current.date(byAdding: .day, value: 8, to: Date()) ?? Date(),
                    isAutoRenew: true,
                    isCancelled: false,
                    paymentMethod: "Visa ****4242",
                    emailUsed: "john@example.com",
                    notifications: [
                        NotificationRule(offsetType: .daysBefore, value: 3)
                    ]
                )
                return item
            }(),

            // Spotify — free trial ending soon
            {
                let item = SubscriptionItem(
                    name: "Spotify",
                    provider: "Spotify AB",
                    iconSource: .system,
                    cost: 11.99,
                    currency: "AUD",
                    billingCycle: .monthly,
                    nextRenewalDate: Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date(),
                    trialEndDate: Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date(),
                    isAutoRenew: true,
                    isCancelled: false,
                    paymentMethod: "Amex ****1234",
                    emailUsed: "john@example.com",
                    notifications: [
                        NotificationRule(offsetType: .daysBefore, value: 3),
                        NotificationRule(offsetType: .daysBefore, value: 1)
                    ]
                )
                return item
            }(),

            // Audible — active, manual
            {
                let item = SubscriptionItem(
                    name: "Audible",
                    provider: "Amazon",
                    iconSource: .system,
                    cost: 16.45,
                    currency: "AUD",
                    billingCycle: .monthly,
                    nextRenewalDate: Calendar.current.date(byAdding: .day, value: 22, to: Date()) ?? Date(),
                    isAutoRenew: false,
                    isCancelled: false,
                    paymentMethod: "Visa ****4242",
                    emailUsed: "john@example.com",
                    notifications: [
                        NotificationRule(offsetType: .weeksBefore, value: 1)
                    ]
                )
                return item
            }(),

            // Gym — cancelled but still active
            {
                let item = SubscriptionItem(
                    name: "Local Gym",
                    provider: "Fitness First",
                    iconSource: .system,
                    cost: 49.00,
                    currency: "AUD",
                    billingCycle: .monthly,
                    nextRenewalDate: Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date(),
                    isAutoRenew: false,
                    isCancelled: true,
                    activeUntilDate: Calendar.current.date(byAdding: .day, value: 18, to: Date()) ?? Date(),
                    paymentMethod: "Amex ****1234",
                    emailUsed: "john@example.com"
                )
                return item
            }(),

            // iCloud — due soon
            {
                let item = SubscriptionItem(
                    name: "iCloud+",
                    provider: "Apple",
                    iconSource: .system,
                    cost: 4.49,
                    currency: "AUD",
                    billingCycle: .monthly,
                    nextRenewalDate: Calendar.current.date(byAdding: .day, value: 4, to: Date()) ?? Date(),
                    isAutoRenew: true,
                    isCancelled: false,
                    paymentMethod: "Apple Pay",
                    emailUsed: "john@icloud.com",
                    notifications: [
                        NotificationRule(offsetType: .daysBefore, value: 1)
                    ]
                )
                return item
            }(),

            // Adobe — yearly
            {
                let item = SubscriptionItem(
                    name: "Adobe Creative Cloud",
                    provider: "Adobe",
                    iconSource: .system,
                    cost: 87.49,
                    currency: "AUD",
                    billingCycle: .yearly,
                    nextRenewalDate: Calendar.current.date(byAdding: .month, value: 4, to: Date()) ?? Date(),
                    isAutoRenew: true,
                    isCancelled: false,
                    paymentMethod: "Visa ****4242",
                    emailUsed: "john@example.com",
                    notifications: [
                        NotificationRule(offsetType: .monthsBefore, value: 1),
                        NotificationRule(offsetType: .weeksBefore, value: 1)
                    ]
                )
                return item
            }(),

            // Australian Passport — document expiry (3 years out)
            {
                let item = SubscriptionItem(
                    itemType: .document,
                    name: "Australian Passport",
                    provider: "Department of Foreign Affairs",
                    iconSource: .system,
                    billingCycle: .yearly,
                    nextRenewalDate: Calendar.current.date(byAdding: .year, value: 3, to: Date()) ?? Date(),
                    expiryDate: Calendar.current.date(byAdding: .year, value: 3, to: Date()),
                    isAutoRenew: false,
                    isCancelled: false,
                    notes: "Passport No: PA1234567",
                    notifications: [
                        NotificationRule(offsetType: .monthsBefore, value: 6, isCritical: true),
                        NotificationRule(offsetType: .monthsBefore, value: 3)
                    ]
                )
                return item
            }(),

            // Driver's Licence — expiring soon (warning zone)
            {
                let item = SubscriptionItem(
                    itemType: .document,
                    name: "Driver's Licence",
                    provider: "Service NSW",
                    iconSource: .system,
                    billingCycle: .yearly,
                    nextRenewalDate: Calendar.current.date(byAdding: .day, value: 20, to: Date()) ?? Date(),
                    expiryDate: Calendar.current.date(byAdding: .day, value: 20, to: Date()),
                    isAutoRenew: false,
                    isCancelled: false,
                    notes: "Licence No: 12345678",
                    notifications: [
                        NotificationRule(offsetType: .weeksBefore, value: 4, isCritical: true),
                        NotificationRule(offsetType: .weeksBefore, value: 1, isCritical: true)
                    ]
                )
                return item
            }(),

            // Car Insurance — critical (expires in 5 days)
            {
                let item = SubscriptionItem(
                    itemType: .document,
                    name: "Car Insurance",
                    provider: "NRMA",
                    iconSource: .system,
                    billingCycle: .yearly,
                    nextRenewalDate: Calendar.current.date(byAdding: .day, value: 5, to: Date()) ?? Date(),
                    expiryDate: Calendar.current.date(byAdding: .day, value: 5, to: Date()),
                    isAutoRenew: false,
                    isCancelled: false,
                    notifications: [
                        NotificationRule(offsetType: .daysBefore, value: 7, isCritical: true),
                        NotificationRule(offsetType: .daysBefore, value: 1, isCritical: true)
                    ]
                )
                return item
            }()
        ]
    }

    // MARK: - Individual items for row previews

    static var netflix: SubscriptionItem {
        SubscriptionItem(
            name: "Netflix",
            iconSource: .system,
            cost: 22.99,
            currency: "AUD",
            billingCycle: .monthly,
            nextRenewalDate: Calendar.current.date(byAdding: .day, value: 8, to: Date()) ?? Date(),
            isAutoRenew: true
        )
    }

    static var spotify: SubscriptionItem {
        SubscriptionItem(
            name: "Spotify",
            iconSource: .system,
            cost: 11.99,
            currency: "AUD",
            billingCycle: .monthly,
            nextRenewalDate: Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date(),
            trialEndDate: Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date(),
            isAutoRenew: false
        )
    }

    static var gym: SubscriptionItem {
        SubscriptionItem(
            name: "Local Gym",
            iconSource: .system,
            cost: 49.00,
            currency: "AUD",
            billingCycle: .monthly,
            nextRenewalDate: Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date(),
            isAutoRenew: false,
            isCancelled: true,
            activeUntilDate: Calendar.current.date(byAdding: .day, value: 18, to: Date()) ?? Date()
        )
    }

    static var passport: SubscriptionItem {
        SubscriptionItem(
            itemType: .document,
            name: "Australian Passport",
            iconSource: .system,
            billingCycle: .yearly,
            nextRenewalDate: Calendar.current.date(byAdding: .day, value: 20, to: Date()) ?? Date(),
            expiryDate: Calendar.current.date(byAdding: .day, value: 20, to: Date()),
            isAutoRenew: false
        )
    }
}
