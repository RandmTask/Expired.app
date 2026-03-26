import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    // MARK: - Permission

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        // criticalAlert requires a separate entitlement; the system will show an extra prompt
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound, .criticalAlert])
        registerCategories()
    }

    // MARK: - Notification categories (enables "View" action on lock screen)

    private func registerCategories() {
        let viewAction = UNNotificationAction(
            identifier: "VIEW_ITEM",
            title: "View",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "EXPIRY_REMINDER",
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Reschedule

    func reschedule(for item: SubscriptionItem) async {
        await requestAuthorization()
        removeAll(for: item)
        await schedule(for: item)
    }

    func rescheduleAll(_ items: [SubscriptionItem]) async {
        for item in items { await reschedule(for: item) }
    }

    // MARK: - Remove

    func removeAll(for item: SubscriptionItem) {
        let ids = pendingIdentifiers(for: item)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Schedule

    private func schedule(for item: SubscriptionItem) async {
        if case .expired = item.status { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return }

        let baseDate = item.nextRelevantDate

        for rule in item.notificationsList {
            guard var fireDate = fireDate(baseDate: baseDate, rule: rule) else { continue }

            // Always fire at 9am so the alert lands at a sensible time
            fireDate = Calendar.current.date(
                bySettingHour: 9, minute: 0, second: 0, of: fireDate
            ) ?? fireDate

            guard fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = notificationTitle(for: item)
            content.subtitle = rule.label.capitalized
            content.body = notificationBody(for: item, baseDate: baseDate)
            content.categoryIdentifier = "EXPIRY_REMINDER"
            content.userInfo = ["itemID": item.id.uuidString]
            content.badge = 1

            if rule.isCritical {
                // Critical alerts bypass Do Not Disturb / Silent mode
                // On macOS they're delivered normally; they push to iPhone when
                // the device is signed into the same iCloud account.
                content.sound = .defaultCritical
                content.interruptionLevel = .critical
            } else {
                content.sound = .default
                content.interruptionLevel = .timeSensitive
            }

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: identifier(itemID: item.id, ruleID: rule.id),
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    // MARK: - Fire date calculation

    private func fireDate(baseDate: Date, rule: NotificationRule) -> Date? {
        switch rule.offsetType {
        case .daysBefore:
            return Calendar.current.date(byAdding: .day, value: -rule.value, to: baseDate)
        case .weeksBefore:
            return Calendar.current.date(byAdding: .day, value: -(rule.value * 7), to: baseDate)
        case .monthsBefore:
            return Calendar.current.date(byAdding: .month, value: -rule.value, to: baseDate)
        case .exactDate:
            return baseDate
        }
    }

    // MARK: - Notification copy

    private func notificationTitle(for item: SubscriptionItem) -> String {
        switch item.itemType {
        case .document:
            return "\(item.name) Expiring"
        case .subscription:
            switch item.status {
            case .trial:   return "\(item.name) — Trial Ending"
            case .autoRenew: return "\(item.name) — Auto-Renews Soon"
            default:       return "\(item.name) — Renewal Due"
            }
        }
    }

    private func notificationBody(for item: SubscriptionItem, baseDate: Date) -> String {
        let dateStr = baseDate.formatted(date: .abbreviated, time: .omitted)
        let days = Calendar.current.dateComponents([.day], from: Date(), to: baseDate).day ?? 0
        let daysStr = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"

        let costStr: String
        if let monthly = item.monthlyCost {
            costStr = " · \(monthly.formatted(.currency(code: item.currency)))/mo"
        } else { costStr = "" }

        switch item.itemType {
        case .document:
            return "Expires \(dateStr) (\(daysStr)) — renew before it lapses"
        case .subscription:
            switch item.status {
            case .trial:
                return "Free trial ends \(dateStr)\(costStr) — cancel to avoid charges"
            case .cancelledButActive(let until):
                return "Access ends \(until.formatted(date: .abbreviated, time: .omitted))"
            case .autoRenew:
                return "Auto-renews \(dateStr)\(costStr)"
            case .manualRenew:
                return "Renewal due \(dateStr)\(costStr)"
            case .expired:
                return "Expired \(dateStr)"
            }
        }
    }

    // MARK: - Identifier helpers

    private func identifier(itemID: UUID, ruleID: UUID) -> String {
        "expired.\(itemID.uuidString).\(ruleID.uuidString)"
    }

    private func pendingIdentifiers(for item: SubscriptionItem) -> [String] {
        item.notificationsList.map { identifier(itemID: item.id, ruleID: $0.id) }
    }
}
