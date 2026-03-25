import Foundation
import SwiftData

// MARK: - Enums

enum BillingCycle: String, Codable, CaseIterable {
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"
    case custom = "Custom"

    var monthlyMultiplier: Double {
        switch self {
        case .weekly: return 52.0 / 12.0
        case .monthly: return 1.0
        case .yearly: return 1.0 / 12.0
        case .custom: return 1.0
        }
    }
}

enum IconSource: String, Codable {
    case system
    case appBundle
    case favicon
    case customImage
}

enum NotificationOffsetType: String, Codable, CaseIterable {
    case daysBefore = "Days Before"
    case weeksBefore = "Weeks Before"
    case monthsBefore = "Months Before"
    case exactDate = "On Date"
}

enum SubscriptionStatus {
    case autoRenew
    case manualRenew
    case cancelledButActive(until: Date)
    case expired
    case trial(endsOn: Date)

    var label: String {
        switch self {
        case .autoRenew: return "Auto-Renew"
        case .manualRenew: return "Manual"
        case .cancelledButActive: return "Cancelled"
        case .expired: return "Expired"
        case .trial: return "Trial"
        }
    }

    var color: String {
        switch self {
        case .autoRenew: return "statusGreen"
        case .manualRenew: return "statusBlue"
        case .cancelledButActive: return "statusOrange"
        case .expired: return "statusRed"
        case .trial: return "statusPurple"
        }
    }
}

// MARK: - NotificationRule

@Model
final class NotificationRule {
    @Attribute(.unique) var id: UUID
    var offsetType: NotificationOffsetType
    var value: Int
    var isCritical: Bool

    init(
        id: UUID = UUID(),
        offsetType: NotificationOffsetType = .daysBefore,
        value: Int = 1,
        isCritical: Bool = false
    ) {
        self.id = id
        self.offsetType = offsetType
        self.value = value
        self.isCritical = isCritical
    }

    var label: String {
        switch offsetType {
        case .daysBefore:
            return value == 1 ? "1 day before" : "\(value) days before"
        case .weeksBefore:
            return value == 1 ? "1 week before" : "\(value) weeks before"
        case .monthsBefore:
            return value == 1 ? "1 month before" : "\(value) months before"
        case .exactDate:
            return "On the date"
        }
    }
}

// MARK: - SubscriptionItem

@Model
final class SubscriptionItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var provider: String
    var iconSource: IconSource
    @Attribute(.externalStorage) var iconData: Data?
    var cost: Double?
    var currency: String
    var billingCycle: BillingCycle
    var nextRenewalDate: Date
    var trialEndDate: Date?
    var isAutoRenew: Bool
    var isCancelled: Bool
    var activeUntilDate: Date?
    var paymentMethod: String
    var emailUsed: String
    var notes: String
    var url: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade)
    var notifications: [NotificationRule]

    init(
        id: UUID = UUID(),
        name: String = "",
        provider: String = "",
        iconSource: IconSource = .system,
        iconData: Data? = nil,
        cost: Double? = nil,
        currency: String = "AUD",
        billingCycle: BillingCycle = .monthly,
        nextRenewalDate: Date = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date(),
        trialEndDate: Date? = nil,
        isAutoRenew: Bool = true,
        isCancelled: Bool = false,
        activeUntilDate: Date? = nil,
        paymentMethod: String = "",
        emailUsed: String = "",
        notes: String = "",
        url: String = "",
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
        self.url = url
        self.createdAt = Date()
        self.updatedAt = Date()
        self.notifications = notifications
    }

    // MARK: - Computed Status

    var status: SubscriptionStatus {
        let now = Date()

        // Active trial
        if let trial = trialEndDate, trial > now, !isCancelled {
            return .trial(endsOn: trial)
        }

        // Cancelled — check if still in grace period
        if isCancelled {
            if let until = activeUntilDate, until > now {
                return .cancelledButActive(until: until)
            }
            return .expired
        }

        // Check if past renewal date with no auto-renew
        if !isAutoRenew && nextRenewalDate < now {
            return .expired
        }

        return isAutoRenew ? .autoRenew : .manualRenew
    }

    var isTrial: Bool {
        guard let trial = trialEndDate else { return false }
        return trial > Date() && !isCancelled
    }

    // The date most relevant to surface in the UI
    var nextRelevantDate: Date {
        if let trial = trialEndDate, trial > Date() {
            return trial
        }
        if isCancelled, let until = activeUntilDate {
            return until
        }
        return nextRenewalDate
    }

    // Days until the next relevant date
    var daysUntilRenewal: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: nextRelevantDate).day ?? 0
    }

    // MARK: - Cost Normalization

    var monthlyCost: Double? {
        guard let cost = cost else { return nil }
        return cost * billingCycle.monthlyMultiplier
    }

    var yearlyCost: Double? {
        guard let monthly = monthlyCost else { return nil }
        return monthly * 12.0
    }

    // MARK: - System Icon Name

    var systemIconName: String {
        let lower = name.lowercased()
        let providerLower = provider.lowercased()
        let combined = lower + providerLower

        if combined.contains("netflix") { return "play.tv.fill" }
        if combined.contains("spotify") { return "music.note" }
        if combined.contains("apple") || combined.contains("icloud") { return "apple.logo" }
        if combined.contains("amazon") || combined.contains("prime") { return "shippingbox.fill" }
        if combined.contains("audible") { return "headphones" }
        if combined.contains("youtube") { return "play.rectangle.fill" }
        if combined.contains("disney") { return "sparkles" }
        if combined.contains("hbo") || combined.contains("max") { return "tv.fill" }
        if combined.contains("gym") || combined.contains("fitness") { return "figure.run" }
        if combined.contains("microsoft") || combined.contains("office") { return "doc.fill" }
        if combined.contains("adobe") { return "paintbrush.fill" }
        if combined.contains("dropbox") || combined.contains("drive") { return "internaldrive.fill" }
        if combined.contains("slack") { return "bubble.left.and.bubble.right.fill" }
        if combined.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if combined.contains("passport") || combined.contains("document") { return "person.text.rectangle.fill" }
        if combined.contains("licence") || combined.contains("license") { return "car.fill" }
        if combined.contains("insurance") { return "shield.fill" }
        return "creditcard.fill"
    }
}
