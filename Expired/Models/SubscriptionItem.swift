import Foundation
import SwiftData

enum BillingCycle: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly
    case yearly
    case custom

    var id: String { rawValue }
}

enum IconSource: String, Codable, CaseIterable, Identifiable {
    case system
    case appBundle
    case favicon
    case customImage

    var id: String { rawValue }
}

enum NotificationOffsetType: String, Codable, CaseIterable, Identifiable {
    case daysBefore
    case weeksBefore
    case monthsBefore
    case exactDate

    var id: String { rawValue }
}

enum SubscriptionStatus: String, Codable, CaseIterable, Identifiable {
    case autoRenew
    case manualRenew
    case cancelledButActive
    case expired

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autoRenew:
            return "Auto-renew"
        case .manualRenew:
            return "Manual"
        case .cancelledButActive:
            return "Cancelled"
        case .expired:
            return "Expired"
        }
    }
}

@Model
final class NotificationRule {
    @Attribute(.unique) var id: UUID
    var offsetType: NotificationOffsetType
    var value: Int
    var isCritical: Bool

    var subscription: SubscriptionItem?

    init(
        id: UUID = UUID(),
        offsetType: NotificationOffsetType,
        value: Int,
        isCritical: Bool = false
    ) {
        self.id = id
        self.offsetType = offsetType
        self.value = value
        self.isCritical = isCritical
    }
}

@Model
final class SubscriptionItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var provider: String?
    var iconSource: IconSource
    var iconData: Data?
    var cost: Double?
    var currency: String
    var billingCycle: BillingCycle
    var nextRenewalDate: Date
    var trialEndDate: Date?
    var isAutoRenew: Bool
    var isCancelled: Bool
    var activeUntilDate: Date?
    var paymentMethod: String?
    var emailUsed: String?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade) var notifications: [NotificationRule]

    init(
        id: UUID = UUID(),
        name: String,
        provider: String? = nil,
        iconSource: IconSource = .system,
        iconData: Data? = nil,
        cost: Double? = nil,
        currency: String = "USD",
        billingCycle: BillingCycle = .monthly,
        nextRenewalDate: Date,
        trialEndDate: Date? = nil,
        isAutoRenew: Bool = true,
        isCancelled: Bool = false,
        activeUntilDate: Date? = nil,
        paymentMethod: String? = nil,
        emailUsed: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        notifications: [NotificationRule] = []
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.iconSource = iconSource
        self.iconData = iconData
        self.cost = cost
        self.currency = currency
        self.billingCycle = billingCycle
        self.nextRenewalDate = nextRenewalDate
        self.trialEndDate = trialEndDate
        self.isAutoRenew = isAutoRenew
        self.isCancelled = isCancelled
        self.activeUntilDate = activeUntilDate
        self.paymentMethod = paymentMethod
        self.emailUsed = emailUsed
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notifications = notifications
    }
}

extension SubscriptionItem {
    var status: SubscriptionStatus {
        let now = Date()
        if let activeUntilDate {
            if now > activeUntilDate {
                return .expired
            }
            if isCancelled {
                return .cancelledButActive
            }
        }
        if isAutoRenew {
            return .autoRenew
        }
        return .manualRenew
    }

    var isTrial: Bool {
        trialEndDate != nil
    }

    var nextRelevantDate: Date {
        if let trialEndDate {
            return trialEndDate
        }
        if let activeUntilDate, isCancelled {
            return activeUntilDate
        }
        return nextRenewalDate
    }

    var monthlyCost: Double? {
        guard let cost else { return nil }
        switch billingCycle {
        case .weekly:
            return cost * 52.0 / 12.0
        case .monthly:
            return cost
        case .yearly:
            return cost / 12.0
        case .custom:
            return nil
        }
    }

    var yearlyCost: Double? {
        guard let cost else { return nil }
        switch billingCycle {
        case .weekly:
            return cost * 52.0
        case .monthly:
            return cost * 12.0
        case .yearly:
            return cost
        case .custom:
            return nil
        }
    }
}
