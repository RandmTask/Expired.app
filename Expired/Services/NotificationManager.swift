import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound, .criticalAlert])
    }

    func rescheduleNotifications(for item: SubscriptionItem) async {
        await requestAuthorizationIfNeeded()
        await removeNotifications(for: item)
        await scheduleNotifications(for: item)
    }

    func removeNotifications(for item: SubscriptionItem) async {
        let center = UNUserNotificationCenter.current()
        let identifiers = item.notifications.map { notificationIdentifier(itemID: item.id, ruleID: $0.id) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func scheduleNotifications(for item: SubscriptionItem) async {
        let center = UNUserNotificationCenter.current()
        let baseDate = item.nextRelevantDate

        for rule in item.notifications {
            guard let fireDate = makeFireDate(baseDate: baseDate, rule: rule) else { continue }
            guard fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = item.name
            content.body = notificationBody(item: item, rule: rule)
            content.sound = rule.isCritical ? .defaultCritical : .default

            let dateComponents = Calendar.current.dateComponents([
                .year, .month, .day, .hour, .minute
            ], from: fireDate)

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
            let request = UNNotificationRequest(
                identifier: notificationIdentifier(itemID: item.id, ruleID: rule.id),
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    private func makeFireDate(baseDate: Date, rule: NotificationRule) -> Date? {
        switch rule.offsetType {
        case .daysBefore:
            return Calendar.current.date(byAdding: .day, value: -rule.value, to: baseDate)
        case .weeksBefore:
            return Calendar.current.date(byAdding: .day, value: -(rule.value * 7), to: baseDate)
        case .monthsBefore:
            return Calendar.current.date(byAdding: .month, value: -rule.value, to: baseDate)
        case .exactDate:
            return Calendar.current.date(byAdding: .day, value: rule.value, to: baseDate)
        }
    }

    private func notificationBody(item: SubscriptionItem, rule: NotificationRule) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let dateString = formatter.string(from: item.nextRelevantDate)

        if item.isTrial {
            return "Trial ends \(dateString)"
        }

        return "Renews \(dateString)"
    }

    private func notificationIdentifier(itemID: UUID, ruleID: UUID) -> String {
        "subscription.\(itemID.uuidString).\(ruleID.uuidString)"
    }
}
