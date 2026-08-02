import Foundation
import SwiftData
import UserNotifications
import Combine

// MARK: - Global notification-time settings

/// Authoritative read/write for the global reminder time and quiet-hours settings.
///
/// Reads pull from `NSUbiquitousKeyValueStore` first (with a `synchronize()`), then fall
/// back to `UserDefaults`, then a hardcoded default. This matters because a refresh can be
/// triggered before `SettingsView` has ever appeared this launch (app launch, CloudKit
/// import) — previously the manager read `UserDefaults` directly and could see stale data.
/// The KV↔UserDefaults sync in `SettingsView` only ran while that view was on screen.
enum NotificationTimeSettings {
    // Key names kept identical to the ones SettingsView already uses so both stores stay in sync.
    static let hourKey   = "notificationHour"
    static let minuteKey = "notificationMinute"
    static let quietEnabledKey = "quietHoursEnabled"
    static let quietStartKey   = "quietHoursStartMinutes"
    static let quietEndKey     = "quietHoursEndMinutes"

    static let defaultHour = 9
    static let defaultMinute = 0
    static let defaultQuietStartMinutes = 22 * 60   // 22:00
    static let defaultQuietEndMinutes   = 8 * 60    // 08:00

    private static func readInt(_ key: String, default fallback: Int) -> Int {
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        if kv.object(forKey: key) != nil {
            return Int(kv.longLong(forKey: key))
        }
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.integer(forKey: key)
        }
        return fallback
    }

    private static func readBool(_ key: String, default fallback: Bool) -> Bool {
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        if kv.object(forKey: key) != nil {
            return kv.bool(forKey: key)
        }
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return fallback
    }

    static var globalHour: Int   { readInt(hourKey, default: defaultHour) }
    static var globalMinute: Int { readInt(minuteKey, default: defaultMinute) }

    static var quietHoursEnabled: Bool { readBool(quietEnabledKey, default: false) }
    static var quietStartMinutes: Int  { readInt(quietStartKey, default: defaultQuietStartMinutes) }
    static var quietEndMinutes: Int    { readInt(quietEndKey, default: defaultQuietEndMinutes) }

    /// Writes an Int setting to both iCloud KV and UserDefaults so every read path agrees.
    static func writeInt(_ value: Int, forKey key: String) {
        let kv = NSUbiquitousKeyValueStore.default
        kv.set(Int64(value), forKey: key)
        kv.synchronize()
        UserDefaults.standard.set(value, forKey: key)
    }

    static func writeBool(_ value: Bool, forKey key: String) {
        let kv = NSUbiquitousKeyValueStore.default
        kv.set(value, forKey: key)
        kv.synchronize()
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - FireMoment (pure compute result)

/// One resolved future notification: an item's rule applied to one occurrence, with the
/// delivery time already resolved through the cascade and quiet-hours adjustment.
struct FireMoment: Identifiable, Hashable {
    let id: String              // the notification identifier
    let itemID: UUID
    let itemName: String
    let itemType: ItemType
    let ruleID: UUID
    let occurrenceDate: Date    // the renewal/expiry date this reminder is about
    let fireDate: Date          // the resolved, quiet-hours-adjusted delivery moment
    let isCritical: Bool
}

// MARK: - Notification tap routing

/// Single source of truth for "a notification tap wants this subscription open."
/// `NotificationManager`'s `UNUserNotificationCenterDelegate` callback sets
/// `pendingItemID`; `ContentView` switches to the Subscriptions tab and `HomeView`
/// dismisses whatever sheet it currently has open before presenting the target
/// item, so the notification's destination never stacks on top of another sheet.
@MainActor
final class SubscriptionNavigationRouter: ObservableObject {
    static let shared = SubscriptionNavigationRouter()
    private init() {}

    @Published var pendingItemID: UUID?

    func openSubscription(_ id: UUID) {
        pendingItemID = id
    }
}

@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()
    private override init() { super.init() }

    /// Identifier prefix — used to find and clear only this app's scheduled requests.
    static let identifierPrefix = "expired."

    /// Soft cap under iOS's hard 64-pending-request limit; leaves headroom.
    static let scheduleCap = 62

    // MARK: - Permission

    /// Shows the system permission dialog. **Only ever call this from an explicit,
    /// user-visible "enable reminders" moment** (the onboarding reminders page, or
    /// Settings) — never from app launch or as a side effect of saving data. See
    /// `refreshAll(context:requestingAuthorization:)` and
    /// `_shared/onboarding-conventions.md` "Never fire a permission prompt before
    /// the page that explains it".
    func requestAuthorization() async {
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

    /// Re-registers notification categories without ever prompting. Categories are
    /// not persisted across launches, so already-authorized users would otherwise
    /// lose the "View"/"Dismiss" actions — but a user who hasn't been asked yet must
    /// not be prompted just because the app launched.
    func registerCategoriesOnly() {
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

    // MARK: - Full rebuild (the single entry point)

    /// Idempotent full rebuild: fetch every item fresh from `context`, recompute all future
    /// fire moments, cap to the soonest ~62, clear all app-prefixed pending requests, and
    /// reschedule. Fetching fresh here (rather than accepting a caller-supplied array) means
    /// there is one authoritative source — every old call site had a different `@Query` filter.
    /// - Parameter requestingAuthorization: when `true` (the default) an undecided
    ///   user is prompted before scheduling. Pass `false` from any path that runs
    ///   *before* the UI has explained what reminders are — notably onboarding's
    ///   batch commit, which used to surface the system dialog mid-flow, several
    ///   pages before the reminders page that asks for it.
    func refreshAll(context: ModelContext, requestingAuthorization: Bool = true) async {
        if requestingAuthorization {
            await requestAuthorization()
        } else {
            registerCategories()
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return }

        let descriptor = FetchDescriptor<SubscriptionItem>()
        let items = (try? context.fetch(descriptor)) ?? []

        let moments = computeAllFireMoments(items: items)
            .sorted { $0.fireDate < $1.fireDate }
        let capped = Array(moments.prefix(Self.scheduleCap))

        // Remove every currently-pending app request (don't reconstruct old identifiers —
        // they may differ from what's about to be scheduled).
        let pending = await center.pendingNotificationRequests()
        let staleIDs = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        if !staleIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleIDs)
        }

        for moment in capped {
            let content = UNMutableNotificationContent()
            content.title = notificationTitle(name: moment.itemName, itemType: moment.itemType, baseDate: moment.occurrenceDate)
            content.body = notificationBody(name: moment.itemName, itemType: moment.itemType, baseDate: moment.occurrenceDate)
            content.categoryIdentifier = "EXPIRY_REMINDER"
            content.userInfo = ["itemID": moment.itemID.uuidString]
            content.badge = 1
            content.sound = .default
            content.interruptionLevel = moment.isCritical ? .timeSensitive : .active

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: moment.fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: moment.id,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    // MARK: - Pure compute

    /// Every future fire moment across all items — no side effects, so the preview UI can
    /// call this without touching `UNUserNotificationCenter`.
    func computeAllFireMoments(items: [SubscriptionItem], referenceDate: Date = Date()) -> [FireMoment] {
        let calendar = Calendar.current
        let quietEnabled = NotificationTimeSettings.quietHoursEnabled
        let quietStart = NotificationTimeSettings.quietStartMinutes
        let quietEnd = NotificationTimeSettings.quietEndMinutes
        let globalHour = NotificationTimeSettings.globalHour
        let globalMinute = NotificationTimeSettings.globalMinute

        var results: [FireMoment] = []

        for item in items {
            guard !item.isArchived else { continue }
            if case .expired = item.status { continue }

            let occurrences = item.upcomingRenewalOccurrences(referenceDate: referenceDate, calendar: calendar)
            let rules = item.notificationsList

            for rule in rules {
                // exactDate rules are absolute — one fire moment regardless of occurrence expansion.
                let occurrenceList: [(index: Int, date: Date)]
                if rule.offsetType == .exactDate {
                    occurrenceList = [(0, item.nextRelevantDate)]
                } else {
                    occurrenceList = occurrences.enumerated().map { ($0.offset, $0.element) }
                }

                for (occIndex, occDate) in occurrenceList {
                    guard let rawFire = fireDate(baseDate: occDate, rule: rule) else { continue }

                    // Time cascade: rule → item → global.
                    let hour: Int
                    let minute: Int
                    if let rh = rule.fireHour, let rm = rule.fireMinute {
                        hour = rh; minute = rm
                    } else if let ih = item.reminderHour, let im = item.reminderMinute {
                        hour = ih; minute = im
                    } else {
                        hour = globalHour; minute = globalMinute
                    }

                    guard var fire = calendar.date(
                        bySettingHour: hour, minute: minute, second: 0, of: rawFire
                    ) else { continue }

                    // Quiet hours — non-critical only.
                    if quietEnabled && !rule.isCritical {
                        fire = Self.applyQuietHours(
                            to: fire, startMinutes: quietStart, endMinutes: quietEnd, calendar: calendar
                        )
                    }

                    guard fire > referenceDate else { continue }

                    let id = identifier(itemID: item.id, ruleID: rule.id, occurrenceIndex: occIndex)
                    results.append(FireMoment(
                        id: id,
                        itemID: item.id,
                        itemName: item.name,
                        itemType: item.itemType,
                        ruleID: rule.id,
                        occurrenceDate: occDate,
                        fireDate: fire,
                        isCritical: rule.isCritical
                    ))
                }
            }
        }

        return results
    }

    // MARK: - Quiet hours

    /// Shifts a non-critical fire date out of the quiet window to the window's end.
    /// The window may wrap midnight (default 22:00–08:00). A time is inside the window when
    /// `start <= t < end` (non-wrapping) or `t >= start || t < end` (wrapping). Inside the
    /// window, the date is moved to the next occurrence of `endMinutes` after `fireDate`.
    static func applyQuietHours(to fireDate: Date, startMinutes: Int, endMinutes: Int, calendar: Calendar) -> Date {
        guard startMinutes != endMinutes else { return fireDate }
        let comps = calendar.dateComponents([.hour, .minute], from: fireDate)
        let t = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        let wraps = startMinutes > endMinutes
        let inside: Bool
        if wraps {
            inside = t >= startMinutes || t < endMinutes
        } else {
            inside = t >= startMinutes && t < endMinutes
        }
        guard inside else { return fireDate }

        let endHour = endMinutes / 60
        let endMinute = endMinutes % 60

        // Same-day end applies when the current time is before the end (e.g. 02:00 in a
        // 22:00–08:00 window → 08:00 today). Otherwise the end is tomorrow (23:00 → 08:00 next day).
        if t < endMinutes {
            return calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: fireDate) ?? fireDate
        } else {
            let sameDayEnd = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: fireDate) ?? fireDate
            return calendar.date(byAdding: .day, value: 1, to: sameDayEnd) ?? sameDayEnd
        }
    }

    // MARK: - Fire date calculation

    private func fireDate(baseDate: Date, rule: NotificationRule) -> Date? {
        Self.staticFireDate(baseDate: baseDate, offsetType: rule.offsetType, value: rule.value, customDate: rule.customDate)
    }

    private static func staticFireDate(baseDate: Date, offsetType: NotificationOffsetType, value: Int, customDate: Date?) -> Date? {
        switch offsetType {
        case .daysBefore:
            return Calendar.current.date(byAdding: .day, value: -value, to: baseDate)
        case .onDay:
            return baseDate
        case .daysAfter:
            return Calendar.current.date(byAdding: .day, value: value, to: baseDate)
        case .weeksBefore:
            return Calendar.current.date(byAdding: .day, value: -(value * 7), to: baseDate)
        case .weeksAfter:
            return Calendar.current.date(byAdding: .day, value: value * 7, to: baseDate)
        case .monthsBefore:
            return Calendar.current.date(byAdding: .month, value: -value, to: baseDate)
        case .monthsAfter:
            return Calendar.current.date(byAdding: .month, value: value, to: baseDate)
        case .exactDate:
            return customDate ?? baseDate
        }
    }

    // MARK: - Notification copy

    private func notificationTitle(name: String, itemType: ItemType, baseDate: Date) -> String {
        let relativeDate = relativeDayPhrase(to: baseDate)
        switch itemType {
        case .document:
            return "\(name) expires \(relativeDate)"
        case .subscription:
            return "\(name) renewal \(relativeDate)"
        }
    }

    private func notificationBody(name: String, itemType: ItemType, baseDate: Date) -> String {
        let dateStr = baseDate.formatted(.dateTime.month(.abbreviated).day())
        switch itemType {
        case .document:
            return "Expires: \(dateStr)"
        case .subscription:
            return "Renews: \(dateStr)"
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

    private func identifier(itemID: UUID, ruleID: UUID, occurrenceIndex: Int) -> String {
        "\(Self.identifierPrefix)\(itemID.uuidString).\(ruleID.uuidString).\(occurrenceIndex)"
    }

    // MARK: - Delegate registration

    /// Call once at app launch, before any notification could be tapped to launch
    /// the app cold. Without a delegate, tapping a notification just foregrounds
    /// the app with no way to know which item it was about.
    func registerDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Notification tapped (or its "View" action chosen) — route to the subscription.
    /// "Dismiss" and swipe-to-clear both report `UNNotificationDismissActionIdentifier`
    /// and should not navigate anywhere.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              response.actionIdentifier != "DISMISS" else { return }
        guard let idString = response.notification.request.content.userInfo["itemID"] as? String,
              let itemID = UUID(uuidString: idString) else { return }
        Task { @MainActor in
            SubscriptionNavigationRouter.shared.openSubscription(itemID)
        }
    }

    /// Lets a reminder that fires while the app is already open still show as a banner —
    /// otherwise it would be silently swallowed and there'd be nothing to tap.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
