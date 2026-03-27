import Foundation
import SwiftData

// MARK: - Enums

/// High-level category — drives UI layout and notification copy.
enum ItemType: String, Codable, CaseIterable {
    case subscription   = "Subscription"
    case document       = "Document"

    var icon: String {
        switch self {
        case .subscription: return "creditcard.fill"
        case .document:     return "doc.text.fill"
        }
    }
}

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

/// User-defined category for grouping subscriptions.
enum SubscriptionCategory: String, Codable, CaseIterable {
    case streaming  = "Streaming"
    case music      = "Music"
    case software   = "Software"
    case fitness    = "Fitness"
    case gaming     = "Gaming"
    case finance    = "Finance"
    case news       = "News"
    case shopping   = "Shopping"
    case utilities  = "Utilities"
    case other      = "Other"

    var icon: String {
        switch self {
        case .streaming:  return "play.tv.fill"
        case .music:      return "sparkles"
        case .software:   return "app.fill"
        case .fitness:    return "figure.run"
        case .gaming:     return "gamecontroller.fill"
        case .finance:    return "dollarsign.circle.fill"
        case .news:       return "newspaper.fill"
        case .shopping:   return "bag.fill"
        case .utilities:  return "wrench.and.screwdriver.fill"
        case .other:      return "square.grid.2x2.fill"
        }
    }

    /// Human-readable display name (kept separate from rawValue which is used for CloudKit storage)
    var displayName: String {
        switch self {
        case .streaming:  return "Streaming & Music"
        case .music:      return "AI Services"
        default:          return rawValue
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
    // CloudKit: no @Attribute(.unique); all stored props need defaults or be optional
    var id: UUID = UUID()
    /// Stored as raw string for CloudKit compatibility; use `offsetType` computed property.
    var offsetTypeRaw: String = NotificationOffsetType.daysBefore.rawValue
    var value: Int = 1
    var isCritical: Bool = false

    /// Back-reference required by CloudKit (inverse relationship).
    var item: SubscriptionItem?

    init(
        id: UUID = UUID(),
        offsetType: NotificationOffsetType = .daysBefore,
        value: Int = 1,
        isCritical: Bool = false
    ) {
        self.id = id
        self.offsetTypeRaw = offsetType.rawValue
        self.value = value
        self.isCritical = isCritical
    }

    var offsetType: NotificationOffsetType {
        get { NotificationOffsetType(rawValue: offsetTypeRaw) ?? .daysBefore }
        set { offsetTypeRaw = newValue.rawValue }
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
    // CloudKit: no @Attribute(.unique) on id; all stored non-optional props need defaults
    var id: UUID = UUID()
    /// Stored as an optional String so CloudKit can deliver nil for old records.
    var itemTypeRaw: String? = nil
    var name: String = ""
    var provider: String = ""
    /// Stored as raw string for CloudKit compatibility.
    var iconSourceRaw: String = IconSource.system.rawValue
    @Attribute(.externalStorage) var iconData: Data? = nil
    var cost: Double? = nil
    var currency: String = "AUD"
    /// Stored as raw string for CloudKit compatibility.
    var billingCycleRaw: String = BillingCycle.monthly.rawValue
    var nextRenewalDate: Date = Date()
    var trialEndDate: Date? = nil
    var expiryDate: Date? = nil
    var isAutoRenew: Bool = true
    var isCancelled: Bool = false
    var activeUntilDate: Date? = nil
    var personName: String = ""
    var paymentMethod: String = ""
    var emailUsed: String = ""
    var phoneNumber: String = ""
    var notes: String = ""
    var url: String = ""
    var documentNumber: String? = nil
    var validFromDate: Date? = nil
    /// Stored as optional String for CloudKit compatibility with older records.
    var categoryRaw: String? = nil
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // CloudKit: relationship must be optional with an inverse (defined on NotificationRule.item)
    @Relationship(deleteRule: .cascade, inverse: \NotificationRule.item)
    var notifications: [NotificationRule]? = nil

    // MARK: - Computed wrappers (enum ↔ raw string)

    var itemType: ItemType {
        get { ItemType(rawValue: itemTypeRaw ?? "") ?? .subscription }
        set { itemTypeRaw = newValue.rawValue }
    }

    var iconSource: IconSource {
        get { IconSource(rawValue: iconSourceRaw) ?? .system }
        set { iconSourceRaw = newValue.rawValue }
    }

    var billingCycle: BillingCycle {
        get { BillingCycle(rawValue: billingCycleRaw) ?? .monthly }
        set { billingCycleRaw = newValue.rawValue }
    }

    var category: SubscriptionCategory? {
        get { categoryRaw.flatMap { SubscriptionCategory(rawValue: $0) } }
        set { categoryRaw = newValue?.rawValue }
    }

    /// Safe accessor — never nil in practice; returns [] when CloudKit delivers nil.
    var notificationsList: [NotificationRule] { notifications ?? [] }

    init(
        id: UUID = UUID(),
        itemType: ItemType = .subscription,
        name: String = "",
        provider: String = "",
        iconSource: IconSource = .system,
        iconData: Data? = nil,
        cost: Double? = nil,
        currency: String = Locale.current.currency?.identifier ?? "AUD",
        billingCycle: BillingCycle = .monthly,
        nextRenewalDate: Date = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date(),
        trialEndDate: Date? = nil,
        expiryDate: Date? = nil,
        isAutoRenew: Bool = true,
        isCancelled: Bool = false,
        activeUntilDate: Date? = nil,
        personName: String = "",
        paymentMethod: String = "",
        emailUsed: String = "",
        phoneNumber: String = "",
        notes: String = "",
        url: String = "",
        documentNumber: String? = nil,
        validFromDate: Date? = nil,
        category: SubscriptionCategory? = nil,
        notifications: [NotificationRule] = []
    ) {
        self.id = id
        self.itemTypeRaw = itemType.rawValue
        self.name = name
        self.provider = provider
        self.iconSourceRaw = iconSource.rawValue
        self.iconData = iconData
        self.cost = cost
        self.currency = currency
        self.billingCycleRaw = billingCycle.rawValue
        self.nextRenewalDate = nextRenewalDate
        self.trialEndDate = trialEndDate
        self.expiryDate = expiryDate
        self.isAutoRenew = isAutoRenew
        self.isCancelled = isCancelled
        self.activeUntilDate = activeUntilDate
        self.personName = personName
        self.paymentMethod = paymentMethod
        self.emailUsed = emailUsed
        self.phoneNumber = phoneNumber
        self.notes = notes
        self.url = url
        self.documentNumber = documentNumber
        self.validFromDate = validFromDate
        self.categoryRaw = category?.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.notifications = notifications
    }

    // MARK: - Computed Status

    var status: SubscriptionStatus {
        let now = Date()

        if itemType == .document {
            let target = expiryDate ?? nextRenewalDate
            if target < now { return .expired }
            return .manualRenew
        }

        if let trial = trialEndDate, trial > now, !isCancelled {
            return .trial(endsOn: trial)
        }

        if isCancelled {
            if let until = activeUntilDate, until > now {
                return .cancelledButActive(until: until)
            }
            return .expired
        }

        if !isAutoRenew && nextRenewalDate < now {
            return .expired
        }

        return isAutoRenew ? .autoRenew : .manualRenew
    }

    var isTrial: Bool {
        guard let trial = trialEndDate else { return false }
        return trial > Date() && !isCancelled
    }

    var nextRelevantDate: Date {
        if itemType == .document {
            return expiryDate ?? nextRenewalDate
        }
        if let trial = trialEndDate, trial > Date() { return trial }
        if isCancelled, let until = activeUntilDate { return until }
        return nextRenewalDate
    }

    var daysUntilRenewal: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: nextRelevantDate).day ?? 0
    }

    enum Urgency { case critical, warning, normal, expired }
    var urgency: Urgency {
        if case .expired = status { return .expired }
        let d = daysUntilRenewal
        if d < 0  { return .expired }
        if d <= 7  { return .critical }
        if d <= 30 { return .warning }
        return .normal
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

    func monthlyCostConverted(to targetCurrency: String) -> Double? {
        guard let monthly = monthlyCost else { return nil }
        return CurrencyInfo.convert(monthly, from: currency, to: targetCurrency)
    }

    // MARK: - System Icon Name

    var systemIconName: String {
        let lower = name.lowercased()
        let providerLower = provider.lowercased()
        let combined = lower + providerLower

        if itemType == .document {
            if combined.contains("passport") { return "person.text.rectangle.fill" }
            if combined.contains("licence") || combined.contains("license") || combined.contains("driver") { return "car.fill" }
            if combined.contains("insurance") || combined.contains("policy") { return "shield.fill" }
            if combined.contains("visa") { return "airplane" }
            if combined.contains("membership") || combined.contains("card") { return "creditcard.fill" }
            if combined.contains("certificate") || combined.contains("cert") { return "rosette" }
            if combined.contains("registration") || combined.contains("rego") { return "car.rear.fill" }
            return "doc.text.fill"
        }

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
