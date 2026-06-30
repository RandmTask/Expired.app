# SwiftUI Code Review Report

Project root: `/Users/deonobrien/Documents/My Apps/Expired`  
Review date: 2026-06-29  
Reviewer stance: senior code review, focused on architecture, state management, and likely runtime bugs.  
Verification: `xcodebuild -project Expired/Expired.xcodeproj -scheme Expired -destination 'platform=macOS' -configuration Debug build` succeeded.

## Executive Summary

The project builds, but several runtime correctness issues should be addressed before relying on the app for real user data. The largest risks are unsaved SwiftData mutations in the primary add/edit/archive/delete flows, transient form state built from live `@Model` objects, CloudKit/local-store fallback behavior that can delete data, and long-running tasks that capture SwiftData model instances.

Architecturally, too much product logic lives inside SwiftUI view files: `Expired/Expired/ContentView.swift` is 3,087 lines and `Expired/Expired/UI/AddEditSubscriptionView.swift` is 2,525 lines. This makes state ownership hard to reason about and is already showing up as duplicated persistence behavior and inconsistent saves.

## Findings

### P1 - Add/edit/delete/archive flows do not explicitly save SwiftData changes

File: `Expired/Expired/UI/AddEditSubscriptionView.swift`

Lines:
- `1490-1568`: `saveAndDismiss()` mutates an existing item or inserts a new item, but never calls `try modelContext.save()`.
- `1571-1577`: `deleteAndDismiss()` deletes the model but never saves.
- `1579-1585`: `archiveAndDismiss()` toggles `isArchived` but never saves.

Why this matters:
Other flows in `HomeView` explicitly call `try? modelContext.save()` after changes, so the app already treats explicit saves as required. The add/edit sheet is the primary data entry path; relying on implicit autosave risks lost edits, delayed CloudKit exports, and notifications being scheduled for data that was never persisted.

Required code changes:
- Add an error state to `AddEditSubscriptionView`, such as `@State private var saveError: String?`.
- In `saveAndDismiss()`, call `try modelContext.save()` after insert/update and before scheduling notifications or dismissing.
- Only call `NotificationManager.shared.reschedule(for:)` after a successful save.
- In `deleteAndDismiss()` and `archiveAndDismiss()`, call `try modelContext.save()` before dismissing.
- Replace silent failures with user-visible error handling.

Suggested shape:

```swift
do {
    try modelContext.save()
    Task { await NotificationManager.shared.reschedule(for: savedItem) }
    dismiss()
} catch {
    saveError = error.localizedDescription
}
```

For deletes:

```swift
do {
    NotificationManager.shared.removeAll(for: item)
    modelContext.delete(item)
    try modelContext.save()
    dismiss()
} catch {
    saveError = error.localizedDescription
}
```

### P1 - Form reminder state uses live SwiftData models as temporary UI state

Files:
- `Expired/Expired/UI/AddEditSubscriptionView.swift`
- `Expired/Expired/UI/RemindersEditorView.swift`

Lines:
- `Expired/Expired/UI/AddEditSubscriptionView.swift:85`: `@State private var notifications: [NotificationRule] = []`
- `Expired/Expired/UI/AddEditSubscriptionView.swift:1480`: edit form copies `item.notificationsList` directly into view state.
- `Expired/Expired/UI/AddEditSubscriptionView.swift:1532` and `1560`: the form writes that array back to the relationship.
- `Expired/Expired/UI/RemindersEditorView.swift:26-31`: rows mutate rules through callbacks.
- `Expired/Expired/UI/RemindersEditorView.swift:303-305`: every row update creates a new `NotificationRule` model object.

Why this matters:
`NotificationRule` is a SwiftData `@Model`, but the editor treats it like a disposable value type. In edit mode the form holds references to managed objects; in update mode it replaces them with newly created model objects. That can cause premature model mutations, relationship churn, orphaned rules, CloudKit identity churn, and surprising saves even when the user cancels.

Required code changes:
- Introduce a pure value type for form state, for example:

```swift
struct NotificationRuleDraft: Identifiable, Equatable {
    var id: UUID
    var offsetType: NotificationOffsetType
    var value: Int
    var isCritical: Bool
    var customDate: Date?
}
```

- Make `RemindersEditorView` bind to `[NotificationRuleDraft]`, not `[NotificationRule]`.
- Convert existing `NotificationRule` models to drafts in `populateFromItem()`.
- On save, reconcile drafts into model instances in one place:
  - update existing rules by `id`,
  - create new `NotificationRule` objects for new drafts,
  - remove rules no longer present.
- Do not mutate managed `NotificationRule` instances until the user taps Save.

### P2 - Archive screen mutates/deletes models without saving, and delete does not remove pending notifications

File: `Expired/Expired/ContentView.swift`

Lines:
- `1455-1537`: `ArchiveView`
- `1503-1505`: archived item deletion calls `modelContext.delete(item)` without removing pending notifications or saving.
- `1510-1514`: restore toggles `isArchived` and `updatedAt` without saving.

Why this matters:
Deleting from the archive can leave stale local notifications behind. Restore/delete changes can also fail to persist promptly or sync via CloudKit.

Required code changes:
- Mirror the safer `HomeView` behavior:
  - call `NotificationManager.shared.removeAll(for: item)` before delete,
  - call `try modelContext.save()` after delete/restore,
  - surface any save failure.
- Prefer extracting shared item actions into an `ItemActions`/`SubscriptionRepository` service so Home and Archive cannot drift.

### P2 - CloudKit/local fallback can delete the user’s local store

File: `Expired/Expired/ExpiredApp.swift`

Lines:
- `270-336`: `makeContainer(iCloudSync:)`
- `317-324`: on local store open failure, the app deletes the SQLite store files and retries.
- `349-356`: `deleteSQLiteFiles(at:)` removes the store, WAL, and SHM files.

Why this matters:
A schema mismatch, migration bug, CloudKit configuration issue, or transient open failure can destroy the user’s on-device data. This is especially risky because the fallback can happen during launch, before the user has any chance to export or confirm.

Required code changes:
- Do not delete the persistent store automatically.
- Add a SwiftData migration plan for schema evolution.
- If destructive recovery is truly necessary, first move the store files to a timestamped backup location and present an explicit recovery/export path.
- Log the backup path and error.

Required replacement behavior:

```swift
// Instead of deleteSQLiteFiles(at:)
// 1. Move default.store, default.store-shm, default.store-wal to Backups/<timestamp>/
// 2. Present recovery UI or continue with a separate empty fallback store.
```

### P2 - iCloud sync toggle uses the same store URL for CloudKit and local-only modes

File: `Expired/Expired/ExpiredApp.swift`

Lines:
- `273-276`: one `default.store` path is used.
- `291-312`: the same URL is opened with CloudKit mirroring or local-only configuration depending on `iCloudSyncEnabled`.
- `86-107`: the toggle is read at app initialization and requires restart.

Why this matters:
Switching a store between CloudKit-backed and local-only configurations at the same file URL is fragile. Metadata and mirroring state can remain in the store, and fallback to local-only after CloudKit open failure can mask sync failures while continuing to use the same file.

Required code changes:
- Use distinct store files for local-only and CloudKit-backed modes, for example `cloud.store` and `local.store`.
- Provide an explicit migration/copy flow when the user switches modes.
- If CloudKit fails to open, surface the failure prominently instead of silently falling back to local-only.

### P2 - API keys are stored in UserDefaults

Files:
- `Expired/Expired/ContentView.swift`
- `Expired/Expired/Services/ScreenshotImportAnalyzer.swift`

Lines:
- `Expired/Expired/ContentView.swift:2202-2206`: API keys are stored via `@AppStorage`.
- `Expired/Expired/ContentView.swift:3046-3059`: pasted API key is written into that storage.
- `Expired/Expired/Services/ScreenshotImportAnalyzer.swift:34-41`: analyzer reads API keys from `UserDefaults`.

Why this matters:
`UserDefaults` is not appropriate for secrets. API keys can appear in device backups, diagnostics, or synced preference data depending on platform behavior.

Required code changes:
- Move API keys to Keychain.
- Store only non-secret provider selection in `@AppStorage`.
- Add a small `APIKeyStore` abstraction with `get/set/delete` methods.
- Avoid showing key length through a full bullet mask if that matters for privacy; use a fixed mask such as `•••• saved`.

### P2 - Long-running tasks capture SwiftData model instances

Files:
- `Expired/Expired/ContentView.swift`
- `Expired/Expired/UI/AddEditSubscriptionView.swift`

Lines:
- `Expired/Expired/ContentView.swift:3007-3030`: `refreshAllFavicons()` captures `itemsWithURL` models and mutates them later.
- `Expired/Expired/UI/AddEditSubscriptionView.swift:1567`: notification rescheduling captures `savedItem` after form save.
- `Expired/Expired/UI/AddEditSubscriptionView.swift:1380-1388`: App Store artwork task mutates view state after an async fetch without tying the result to the current selected URL/result.

Why this matters:
SwiftData model instances are context-bound. Capturing them across asynchronous work can produce stale writes, writes to deleted objects, or updates that apply after the user has moved on. The favicon refresh also never saves after mutating `iconData`/`iconSource`.

Required code changes:
- Snapshot IDs and immutable inputs before starting async work.
- Fetch remote data off the main actor using the snapshot.
- Return to the main actor, re-fetch the model by ID from `modelContext`, verify it still matches the intended URL/source, then mutate and save.
- For notification scheduling, pass an immutable `NotificationScheduleSnapshot` to `NotificationManager` instead of a live `SubscriptionItem`.

Example direction:

```swift
let jobs = allItems.map { (id: $0.id, url: $0.url) }
Task {
    for job in jobs {
        guard let data = await FaviconFetcher.fetch(from: job.url) else { continue }
        await MainActor.run {
            guard let item = allItems.first(where: { $0.id == job.id && $0.url == job.url }) else { return }
            item.iconData = data
            item.iconSource = .favicon
            try? modelContext.save()
        }
    }
}
```

### P2 - Notification categories are only registered on first permission prompt

File: `Expired/Expired/Services/NotificationManager.swift`

Lines:
- `11-18`: `requestAuthorization()` returns early when authorization is not `.notDetermined`, so `registerCategories()` is skipped for already-authorized users.
- `22-40`: notification categories are only registered from that path.

Why this matters:
If the user already granted permission on a previous launch, the app may not register the `EXPIRY_REMINDER` category during this launch. Notification actions like "View" can be missing.

Required code changes:
- Call `registerCategories()` every launch before the authorization-status guard.

Suggested shape:

```swift
func requestAuthorization() async {
    registerCategories()
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .notDetermined else { return }
    // request permission...
}
```

### P2 - Remote screenshot AI errors are swallowed and HTTP failures are parsed as success

File: `Expired/Expired/Services/ScreenshotImportAnalyzer.swift`

Lines:
- `83-85`: remote AI parsing failures are discarded via `try?`, falling back to local parsing with no user-visible indication.
- `153-157`, `173-176`, `189-194`: remote API responses are parsed without checking HTTP status codes or provider error payloads.

Why this matters:
An invalid key, quota failure, model error, or malformed response silently degrades to local OCR heuristics. Users will think the selected AI provider worked when it did not.

Required code changes:
- Check `HTTPURLResponse.statusCode` for all remote providers.
- Decode provider error payloads when status is not 2xx.
- Return a structured result from `analyze`, such as `(drafts, providerUsed, warning)`, or throw a provider-specific error that `HomeView.analyzeScreenshot(_:)` can show.
- Do not use `try?` for provider calls unless the fallback warning is surfaced.

### P3 - Query sort order does not match displayed renewal date

Files:
- `Expired/Expired/UI/HomeView.swift`
- `Expired/Expired/ContentView.swift`

Lines:
- `Expired/Expired/UI/HomeView.swift:8-10`: query sorts by stored `nextRenewalDate`.
- `Expired/Expired/UI/HomeView.swift:49-62`: in-memory sort uses `nextRelevantDate` in some paths.
- `Expired/Expired/ContentView.swift:54-56`: Timeline query sorts by stored `nextRenewalDate`.
- `Expired/Expired/Models/SubscriptionItem.swift:390-400`: displayed/behavioral date can be `nextLiveRenewalDate()`, trial end, active-until, or expiry date.

Why this matters:
For auto-renewing subscriptions with stale stored dates, the UI displays a normalized future `nextRelevantDate` but the initial query order is based on the stale `nextRenewalDate`. This can make timeline/list ordering look wrong.

Required code changes:
- Treat SwiftData query sorting as a coarse fetch only.
- In every user-facing list/timeline, sort in memory by `nextRelevantDate` after filtering.
- For large datasets, persist a normalized `nextOccurrenceDate` and update it when relevant fields change.

### P3 - Custom category deletion leaves subscriptions pointing at missing categories

File: `Expired/Expired/ContentView.swift`

Lines:
- `1665-1674`: iOS category deletion removes custom categories from the store.
- `2025-2031`: macOS custom category delete removes the category from `unifiedCategories`.
- `1574-1576`: counts show whether subscriptions reference a category, but deletion is still allowed.

Why this matters:
Deleting a custom category does not clear or reassign `SubscriptionItem.categoryRaw`. Items can remain attached to a category that no longer appears in the picker or category settings.

Required code changes:
- If `count(rawName:) > 0`, block deletion and ask the user to reassign or clear affected subscriptions.
- Alternatively, on delete, set `categoryRaw = nil` for matching subscriptions and save `modelContext`.
- This requires injecting `modelContext` into `CategoriesView`.

### P3 - Architecture: core app logic is embedded in oversized SwiftUI view files

Files:
- `Expired/Expired/ContentView.swift`
- `Expired/Expired/UI/AddEditSubscriptionView.swift`

Lines:
- `Expired/Expired/ContentView.swift:1-3087`
- `Expired/Expired/UI/AddEditSubscriptionView.swift:1-2525`

Why this matters:
The view layer currently owns app-wide settings, category stores, currency conversion, archive behavior, CloudKit debug UI, screenshot import review, and multiple analytics/timeline views. This makes state ownership unclear and increases the chance of inconsistent persistence paths like the save issues above.

Required code changes:
- Split `ContentView.swift` into feature files: timeline, insights, archive, categories, settings, currency picker, shared UI helpers.
- Move non-view logic into services:
  - `CurrencyInfo` into `Services/CurrencyService.swift` or `Models/CurrencyInfo.swift`.
  - `UserCategoryStore` and `BuiltInCategoryStore` into a category preferences service.
  - CloudKit diagnostics out of `ExpiredApp.swift` into `Services/CloudKitDiagnostics.swift`.
- Add a repository/action layer for common item mutations: save, delete, archive, restore, cancel/reinstate, refresh icon, schedule notifications.

## State Management Recommendations

- Use value-type draft models for all edit screens. A SwiftUI form should not hold live SwiftData models for fields the user can cancel.
- Centralize persistence in a small set of save APIs. Every mutation path should either save or intentionally remain draft-only.
- Avoid `try?` around persistence and notification scheduling. At minimum, log errors with context; for user actions, show an alert.
- Snapshot data before async work and re-resolve SwiftData models on the main actor before mutation.
- Keep `@AppStorage` for harmless preferences only. Use Keychain for secrets and SwiftData/CloudKit for user data that should sync predictably.

## Suggested Follow-up Test Coverage

- Add/edit subscription persists after app relaunch.
- Delete/archive/restore from both Home and Archive persists after relaunch.
- Cancel from add/edit does not mutate existing notification rules.
- Editing reminders updates existing rules without duplicating CloudKit records.
- Notification categories are registered when permission was already granted.
- Favicon refresh saves icon data and survives relaunch.
- CloudKit-open failure does not delete existing local data.
- Custom category deletion either blocks when in use or clears/reassigns affected subscriptions.

## Build Notes

The macOS Debug build succeeded. Build output included only non-blocking warnings from Xcode/app intents metadata processing, not Swift compile errors.
