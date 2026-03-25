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
        // Request including criticalAlert — system will show a separate prompt for that
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound, .criticalAlert])
    }

    // MARK: - Reschedule (call after every save)

    func reschedule(for item: SubscriptionItem) async {
        await requestAuthorization()
        removeAll(for: item)
        await schedule(for: item)
    }

    func rescheduleAll(_ items: [SubscriptionItem]) async {
        for item in items {
            await reschedule(for: item)
        }
    }

    // MARK: - Remove

    func removeAll(for item: SubscriptionItem) {
        let ids = pendingIdentifiers(for: item)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Schedule

    private func schedule(for item: SubscriptionItem) async {
        // Don't schedule if expired or cancelled with no active period
        if case .expired = item.status { return }

        let center = UNUserNotificationCenter.current()
        let baseDate = item.nextRelevantDate

        for rule in item.notifications {
            guard let fireDate = fireDate(baseDate: baseDate, rule: rule) else { continue }
            guard fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = item.name
            content.body = body(for: item, rule: rule, fireDate: fireDate, baseDate: baseDate)
            content.sound = rule.isCritical ? .defaultCritical : .default
            content.badge = 1

            // Include relevant metadata in userInfo for deep-link later
            content.userInfo = ["itemID": item.id.uuidString]

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
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
            // Fire at 9am on the date itself
            return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: baseDate)
        }
    }

    // MARK: - Notification body

    private func body(for item: SubscriptionItem, rule: NotificationRule, fireDate: Date, baseDate: Date) -> String {
        let dateStr = baseDate.formatted(date: .abbreviated, time: .omitted)

        // Cost string
        let costStr: String
        if let monthly = item.monthlyCost {
            costStr = " · " + monthly.formatted(.currency(code: item.currency)) + "/mo"
        } else {
            costStr = ""
        }

        switch item.status {
        case .trial:
            return "Free trial ends \(dateStr)\(costStr) — cancel to avoid charges"
        case .cancelledButActive(let until):
            return "Active until \(until.formatted(date: .abbreviated, time: .omitted))"
        case .autoRenew:
            return "Auto-renews \(dateStr)\(costStr)"
        case .manualRenew:
            return "Renewal due \(dateStr)\(costStr)"
        case .expired:
            return "Expired \(dateStr)"
        }
    }

    // MARK: - Identifier helpers

    private func identifier(itemID: UUID, ruleID: UUID) -> String {
        "expired.\(itemID.uuidString).\(ruleID.uuidString)"
    }

    private func pendingIdentifiers(for item: SubscriptionItem) -> [String] {
        item.notifications.map { identifier(itemID: item.id, ruleID: $0.id) }
    }
}
