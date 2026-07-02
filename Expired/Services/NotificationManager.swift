import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    // MARK: - Permission

    func requestAuthorization() async {
        // Re-register every launch — categories are not persisted across launches,
        // so already-authorized users would otherwise lose the "View"/"Dismiss" actions.
        registerCategories()
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            print("[Notifications] Authorization request failed: \(error)")
        }
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

            // Fire at the user's preferred notification time (default 9:00 am)
            let prefHour   = UserDefaults.standard.object(forKey: "notificationHour")   as? Int ?? 9
            let prefMinute = UserDefaults.standard.object(forKey: "notificationMinute") as? Int ?? 0
            fireDate = Calendar.current.date(
                bySettingHour: prefHour, minute: prefMinute, second: 0, of: fireDate
            ) ?? fireDate

            guard fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = notificationTitle(for: item, baseDate: baseDate)
            content.body = notificationBody(for: item, baseDate: baseDate)
            content.categoryIdentifier = "EXPIRY_REMINDER"
            content.userInfo = ["itemID": item.id.uuidString]
            content.badge = 1

            content.sound = .default
            content.interruptionLevel = .timeSensitive

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
        case .onDay:
            return baseDate
        case .daysAfter:
            return Calendar.current.date(byAdding: .day, value: rule.value, to: baseDate)
        case .weeksBefore:
            return Calendar.current.date(byAdding: .day, value: -(rule.value * 7), to: baseDate)
        case .weeksAfter:
            return Calendar.current.date(byAdding: .day, value: rule.value * 7, to: baseDate)
        case .monthsBefore:
            return Calendar.current.date(byAdding: .month, value: -rule.value, to: baseDate)
        case .monthsAfter:
            return Calendar.current.date(byAdding: .month, value: rule.value, to: baseDate)
        case .exactDate:
            return rule.customDate ?? baseDate
        }
    }

    // MARK: - Notification copy

    private func notificationTitle(for item: SubscriptionItem, baseDate: Date) -> String {
        let relativeDate = relativeDayPhrase(to: baseDate)
        switch item.itemType {
        case .document:
            return "\(item.name) expires \(relativeDate)"
        case .subscription:
            return "\(item.name) renewal \(relativeDate)"
        }
    }

    private func notificationBody(for item: SubscriptionItem, baseDate: Date) -> String {
        let dateStr = baseDate.formatted(.dateTime.month(.abbreviated).day())

        switch item.itemType {
        case .document:
            return "Expires: \(dateStr)"
        case .subscription:
            switch item.status {
            case .trial:
                return "Trial ends: \(dateStr)"
            case .cancelledButActive:
                return "Access ends: \(dateStr)"
            case .autoRenew:
                return "Auto-renews: \(dateStr)"
            case .manualRenew:
                return "Renewal: \(dateStr)"
            case .expired:
                return "Expired: \(dateStr)"
            }
        }
    }

    private func relativeDayPhrase(to date: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let targetDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: targetDay).day ?? 0

        switch days {
        case 0:
            return "today"
        case 1:
            return "in 1 day"
        case 2...:
            return "in \(days) days"
        case -1:
            return "1 day ago"
        default:
            return "\(-days) days ago"
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
