# Expired — Implementation Log

This file is the source of truth for what has been built in Expired. It should stay specific to this app and should be updated whenever a meaningful user-facing or architectural change lands.

## Current State Summary

**Project:** Expired — subscription and document expiry tracker.
**Current phase:** Active product polish and stability cleanup.
**Stack today:** SwiftUI + SwiftData + CloudKit with local settings state and diagnostics.
**Platforms:** iOS and macOS in a single multiplatform target.
**Primary focus:** clean subscription cards, accurate expiry/status handling, reliable sync, and calm settings UX.

## 2026-06-30 — Add/Edit polish + Critical Alerts entitlement request

- **Add/Edit sheet polish** (`AddEditSubscriptionView`): `.padding(.top, 10)` on the name+icon
  row for breathing room under the card top; restyled the "Search the App Store" suggestion row
  (blue accent, medium 13pt, single-line truncated, curly quotes) so it reads as a calm secondary
  action instead of heavy bold primary text.
- **Notes keyboard avoidance:** wrapped the form `ScrollView` in a `ScrollViewReader`, tagged
  `notesSection` with `.id("notesSection")`, added `@FocusState notesFieldFocused`, and on focus
  scroll the section to `.bottom` so the Notes field rises above the keyboard instead of sitting
  behind it. SwiftUI's automatic keyboard avoidance wasn't lifting it because Notes is the last
  real content before a `Spacer`.
- **Pre-existing build break fixed:** `.fileImporter` in `ContentView` was calling the single-URL
  overload while `handleImport(_: Result<[URL], Error>)` expects the array variant (it calls
  `.first`). Added `allowsMultipleSelection: false` to select the array-returning overload. This
  was blocking the whole build, not just the task at hand.
- **Critical Alerts (FLAGGED, request pending):** the notification code was already wired for
  critical alerts (`requestAuthorization` includes `.criticalAlert`; rules set
  `interruptionLevel = .critical` + `.defaultCritical` sound) but did nothing because the gating
  entitlement was absent. Added `com.apple.developer.usernotifications.critical-alerts` to
  `Expired.entitlements`, verified the **simulator** builds, then **commented it back out** because
  with automatic signing it breaks **device/TestFlight** provisioning until Apple grants the
  capability on App ID `com.swiftstudio.Expired`.
  - **Decision:** keep it commented (clearly marked) so device builds keep working; re-enable only
    after Apple approves. No second per-destination entitlements file — not worth it for a request
    Apple may decline (their bar is health/safety/public-safety; a general expiry tracker is
    borderline).
  - **Dependency / next action:** submit the web request at
    developer.apple.com/contact/request/notifications-critical-alerts-entitlement using the
    insurance/passport/professional-license legal-consequence justification. Submission needs no
    TestFlight and no released build — just an active Developer Program membership and the existing
    App ID. On approval: uncomment the key, clean build (fresh profile), verify on a physical
    device (simulator can't test DND-bypass).
  - **Fallback if declined:** Time Sensitive interruption level (already used for non-critical
    reminders) breaks through opted-in Focus modes without this entitlement.

## 2026-06-29 — Automatic iCloud Drive backup

- **Auto-backup engine** (`BackupService.runAutomaticBackupIfNeeded` + helpers): on scene
  `.inactive`/`.background` (in `ExpiredApp`, right after the pending-changes save), writes a
  once-per-day JSON snapshot. Fetch + encode run on the main actor; the iCloud-container lookup
  (`url(forUbiquityContainerIdentifier:)`, which can block on first access) and the atomic file
  write are pushed to a detached utility Task. Throttle via `@AppStorage("lastAutoBackupAt")`
  (skips if already backed up today); `lastAutoBackupAt` is only stamped on a *successful* write
  so failures retry next time. Keeps the 5 most recent dated files (`Expired-Backup-YYYY-MM-DD.json`),
  prunes older.
- **Destination:** iCloud Drive ubiquity container `Documents/` when available, else local
  Application Support `Expired/AutoBackups/`. Graceful fallback means the code is safe even before
  the capability is provisioned.
- **Settings:** "Automatic iCloud Backup" toggle (`@AppStorage("autoBackupEnabled")`, default on,
  green switch) with a "Last backup …/No automatic backup yet" subtitle, in both iOS Backup section
  and macOS Data section.
- **Entitlement (FLAGGED):** added `CloudDocuments` to `com.apple.developer.icloud-services` in
  `Expired.entitlements`. **The iCloud Documents capability must be enabled** in the target's
  Signing & Capabilities (and provisioning profile) for the iCloud path to activate — until then it
  silently falls back to local storage. To surface the backups in the Files app under "Expired",
  also add an `NSUbiquitousContainers` dict to Info.plist (deferred; not required for the backup to
  function). No `@Model`/CloudKit-schema change.
- **Decision:** trigger on background rather than a timer/BGTaskScheduler — simplest reliable hook,
  no background-execution entitlement, and the data is freshest at that moment. Rolling 5-file
  retention (not single-overwrite) so a corrupt write can't clobber the only good copy.

## 2026-06-29 — Home toolbar consolidation, header A/B styles, backup export/import

- **Home toolbar:** collapsed scan-import, filter, and sort into a single `•••` overflow
  menu (`overflowMenu` in `HomeView`), keeping only `+` as a standalone toolbar button.
  Screenshot import moved into the menu; iOS now triggers it via `.photosPicker(isPresented:)`
  (state `showingPhotoImporter`) instead of an inline `PhotosPicker` toolbar item. Removed the
  now-orphaned `sortMenu`/`filterMenu` computed properties.
- **Section-header bleed-through:** added a switchable `SectionHeaderStyle` enum
  (`pillTranslucent` / `pillSolid` / `rowSolid` / `rowMaterial`), stored in
  `@AppStorage("homeSectionHeaderStyle")`, selectable from a "Header Style" submenu in the
  overflow menu. Default `rowSolid` (full-width solid `groupedBackground` behind the pinned
  header row) is the real fix; the others — including the more-opaque `pillSolid` — are there to
  A/B against. Only the iOS plain-`List` pinned header was the problem; macOS `GlassSectionView`
  left untouched. Decision: ship multiple styles behind a menu rather than commit to one, because
  the bleed only reproduces against real scrolled content.
- **"Hiding Expired" chip removed** from `activeFilterChips`; chip strip now shows only the
  active filter chip.
- **Show/Hide Expired menu item** now uses a checkmark (shown when expired ARE visible) and the
  label "Show Expired", matching the Sort/Filter checkmark idiom — no more eye glyph.
- **Search hidden until pull-down:** restored a large nav title ("Subscriptions") so the
  `navigationBarDrawer(.automatic)` search collapses natively on scroll instead of staying pinned
  (it was pinned because the title was empty `""`).
- **Backup export/import** (`Services/BackupService.swift`): plain JSON snapshot of every item +
  notification rules (icons excluded — re-fetchable). Export via `.fileExporter` (BackupDocument,
  `.json`) behind an unencrypted-data warning alert; import via `.fileImporter`, merging by `id`
  (update existing, insert new, never delete) — so a partial/older backup can't lose data.
  Surfaced in both iOS and macOS Settings → Data. No `@Model`/schema change; reschedules
  notifications after import. Decision: manual export/import only this batch; CloudKit already
  syncs live, so this is the off-CloudKit disaster-recovery copy. Auto/scheduled iCloud-Drive
  backup deferred.

## Product Decisions Locked In

- Track both subscriptions and documents in one app.
- Keep the interface calm, minimal, and card-based rather than busy or dashboard-heavy.
- Use SwiftData models with CloudKit-safe storage patterns.
- Keep enum-backed model values stored as raw `String` for CloudKit compatibility.
- Support both iOS and macOS, but do not force identical layouts when platform behavior diverges.
- Keep settings readable and predictable; avoid chrome-heavy controls where a simpler control works.
- Use approximate location or other low-friction settings only when a setting truly needs them.
- Keep AI / screenshot import provider choices user-visible and editable, but do not expose unnecessary implementation detail.

## Roadmap

### Phase 1 - Core Experience
- [x] Subscription and document data model.
- [x] Card-based list and detail editing flow.
- [x] Settings screen with currency, appearance, analyzer, notification, sync, and debug controls.
- [x] iCloud/CloudKit diagnostics surface for troubleshooting sync.
- [x] Menu and picker stability pass for macOS settings.
- [ ] Visual QA sweep across iPhone, iPad, and Mac.

### Phase 2 - Reliability
- [ ] Tighten CloudKit sync status reporting.
- [ ] Reduce any remaining platform-specific layout drift.
- [ ] Verify edge cases around archived items, categories, and notification timing.

### Phase 3 - Expansion
- [ ] Add any future AI-assisted import or analysis improvements.
- [ ] Add additional import/export helpers only if they stay lightweight and user-controlled.

## Changelog

### 2026-06-29 - Screenshot import: live model picker
- **Category:** Feature
- **Severity:** Major
- **Difficulty:** Moderate
- **Verification:** macOS Debug build succeeded (`xcodebuild ... -destination 'platform=macOS'`).
- **Learning:** Hardcoded model IDs rot every few months; a release-gated string guarantees breakage windows. Per `_shared/ai-providers.md`, resolution must funnel through one accessor with a live picker on top, not a protocol rewrite for a single-feature app.

Implemented layers 1–2 of the model-staleness pattern (layer 3, server-side default, stays roadmap with the proxy):
1. **Single accessor** — `ScreenshotAIProvider.selectedModelID` returns the user's UserDefaults override (`screenshotAI.model.<provider>`) or the `defaultModelID` fallback; `setSelectedModelID` writes it (clears the key when the choice equals the default). `ScreenshotAISettings.current` now carries `modelID`, and every analyzer HTTP call resolves the model through `settings.modelID` (no call site reads `defaultModelID` directly anymore).
2. **`ScreenshotAIModelService`** (new) — `listModels(provider:apiKey:)` hits each provider's models endpoint (OpenAI/DeepSeek/Anthropic `data[].id`; Gemini `models[]` filtered to `generateContent`, `models/` stripped; OpenAI filtered to `gpt`/`o`). Shared `httpGET` throws on non-2xx with the body.
3. **Settings UI** — Model row (Menu picker) + Refresh button on both macOS and iOS, under the API-key row. Options = `Set(fetched) ∪ {current} ∪ {default}` so a tag always matches the selection; the default is labelled "(default)". Auto-loads on appear, on provider change, and after a key paste; guards against a stale fetch landing after a provider switch. A secondary note states models load live and that server-side selection is planned (the existing RED security warning already carries the proxy/server-side direction, so the model note is kept secondary to avoid red fatigue — a deliberate deviation from the playbook's "red notice").

No `@Model` schema change. **Still roadmap:** the backend proxy + server-side model/provider default and fallback chain.

### 2026-06-29 - Screenshot import: API keys → Keychain + failure surfacing
- **Category:** Security, Feature
- **Severity:** Major
- **Difficulty:** Moderate
- **Verification:** macOS Debug build succeeded (`xcodebuild ... -destination 'platform=macOS'`).
- **Learning:** Provider API keys were in `UserDefaults` via `@AppStorage` — plaintext and at risk of riding preference sync. Keychain items must use `...ThisDeviceOnly` accessibility so a secret never syncs or rides a backup transfer. UserDefaults can't be a `Binding` source for a Keychain-backed value, so the settings UI now mirrors keys in `@State` (source of truth = Keychain) and writes through on edit.

Completed the deferred pre-release security batch:
1. **`KeychainStore`** (new) — minimal generic-password wrapper; `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (per-device, never synced).
2. **Keys moved to Keychain** — `ScreenshotAISettings.current` reads keys from Keychain; `ScreenshotAIProvider.keychainAccount` is the account name. `migrateAPIKeysToKeychainIfNeeded()` runs once at launch (`ExpiredApp.init`), copies any legacy UserDefaults keys into the Keychain, then deletes the plaintext copies.
3. **Settings UI** — replaced the four `@AppStorage` key vars with a Keychain-backed `@State` mirror (`loadScreenshotAIKeys`/`setScreenshotAIKey`); paste writes to Keychain.
4. **RED pre-release warning** — `apiKeySecurityWarning` shown under the API-key field on both macOS and iOS whenever a keyed provider is selected, stating AI calls must route through a backend proxy (rate limits + monthly cap) before any TestFlight/App Store release.
5. **AI-failure surfacing** — `analyze` now returns `Result(drafts, warning:)`. The chosen provider path throws on failure (no silent internal fallback); the orchestrator degrades to the on-device heuristic but attaches a warning. The review sheet shows an orange banner; an empty result surfaces the warning as the error message. No more silent "AI ran" when it didn't.

No `@Model` schema change. **Still roadmap (not started):** backend proxy itself (the warning is the placeholder), and the live model picker per `_shared/ai-providers.md`.

### 2026-06-29 - Screenshot import: real Apple Intelligence + structural prompt
- **Category:** Feature, Bug fix
- **Severity:** Major
- **Difficulty:** Moderate
- **Verification:** macOS Debug build succeeded (`xcodebuild ... -destination 'platform=macOS'`).
- **Learning:** The "Apple Intelligence" analyzer was a *misnomer* — its code path returned `"[]"` and silently fell back to a regex/OCR heuristic. The garbage in the import review (plan lines like "Student"/"Clipboard AI Pro Yearly" becoming their own subscriptions, one Zynotes → three rows, uniform "78% confidence") was the heuristic's hard-coded confidence values (0.92/0.78/0.64/0.4), not a bad prompt. Fixed-value confidence in LLM output is the tell that no model ran. Also: FoundationModels' on-device model is text-only in iOS 26, so Apple Intelligence runs over OCR text; only the keyed cloud providers get the image.

Reworked `ScreenshotImportAnalyzer`:
1. **Apple Intelligence now real** — `.appleIntelligence` calls `SystemLanguageModel`/`LanguageModelSession` with a `@Generable` structured output (`AIDetectionResult`). Checks `model.availability`; falls back to the regex heuristic only if unavailable/errors.
2. **Structural prompt** — `analysisInstructions(referenceDate:)` describes the Apple Subscriptions screen as name→plan→status→price blocks, with hard rules: a plan/tier line is never its own subscription, ignore UI chrome/OCR fragments, merge near-duplicates, calibrate confidence (no constant). Shared by every LLM path.
3. **Vision for cloud providers** — OpenAI/Claude/Gemini now receive the screenshot image (base64) instead of OCR text; DeepSeek (text-only) still gets OCR lines. Visual grouping is what disambiguates plan-vs-service.
4. **Model IDs centralised** — `ScreenshotAIProvider.defaultModelID` is the single source of truth (TODO: live model picker next batch, per `_shared/ai-providers.md`).
5. **Noise/safety guards** — drop drafts with neither date nor price; reject bare tier-word names ("Student"); low-confidence (<0.5) unmatched drafts default to *Skip* not *Add*; removed the hard-coded app-specific `canonicalName` swap table (now generic stop-word normalisation).

Confirmed the Apply flow already satisfies the data-safety rules: *Skip* is a no-op (no deletes from list absence), and *Update* only touches date/cost/status on the matched row. No `@Model` schema change.

**Deferred to next batch (per scoping Q12):** move provider API keys out of `UserDefaults` into Keychain + RED pre-release warning; surface AI failures to the user instead of silent fallback; live model picker UI.

### 2026-06-29 - Code-review stability pass (persistence + data safety)
- **Category:** Bug fix, data safety
- **Severity:** Major
- **Difficulty:** Moderate
- **Verification:** macOS Debug build succeeded (`xcodebuild ... -destination 'platform=macOS'`).
- **Learning:** SwiftData autosave + the scene-background save already prevent outright data loss, so the review's "no explicit save" findings were consistency/determinism issues, not silent data loss. The genuinely dangerous finding was the launch-time store *deletion* on open failure.

Actioned `codex_review.md`. Implemented the must-fix subset:
1. `NotificationManager.requestAuthorization()` now calls `registerCategories()` every launch (was skipped for already-authorized users, dropping the View/Dismiss actions).
2. `AddEditSubscriptionView` save/delete/archive now call `try? modelContext.save()` (save before scheduling notifications), matching HomeView's existing style.
3. `ArchiveView` delete now removes pending notifications and saves; restore saves.
4. **Data safety:** `ExpiredApp` no longer deletes the SQLite store on open failure — it moves the `.store/-shm/-wal` triple into a timestamped `Backups/<stamp>/` folder (`backupSQLiteFiles` replaces `deleteSQLiteFiles`). User data stays recoverable.
5. `refreshAllFavicons()` now persists icon changes and skips rows deleted mid-refresh.

Deferred with rationale (not data-loss/runtime risks): reminder value-type drafts (churn-only refactor), API-keys→Keychain (separable pre-release security task), AI-error surfacing (graceful-degradation product call), store-URL split (risky migration), query-sort normalization (HomeView already re-sorts in memory), custom-category orphan cleanup, and the ContentView/AddEdit file-size refactor.

**Follow-up (same day) — cleared most of the deferred list** at Deon's request (verified on both macOS and iOS Debug builds):
6. **Reminder value-type drafts** — new `NotificationRuleDraft` (pure value type) now backs `RemindersEditorView`/`ReminderRuleRow` and `AddEditSubscriptionView.notifications`. On save, `reconcileNotifications(into:)` updates managed `NotificationRule`s in place by `id`, inserts new drafts, and deletes removed ones — eliminating the relationship/CloudKit churn (and any chance of cancel mutating managed objects). New items map drafts via `makeRule()`.
7. **Custom-category orphan cleanup** — `CategoriesView` gained `@Environment(\.modelContext)` + `reassignItems(named:to:)` (fetches by predicate so archived/document items are covered too). Deleting a custom category clears `categoryRaw` on its items; renaming a custom category rewrites `categoryRaw` to the new name. Wired into iOS swipe-delete, the shared row ✕ button, and both edit-save closures.
8. **AI HTTP-status validation** — added `sendForData` + `providerErrorMessage`; all four provider HTTP calls now throw `AnalyzerError.httpError` on non-2xx (surfacing the provider's `error.message`) instead of parsing an error body into empty drafts. This makes the existing `analyze` warning path actually fire on bad keys/quota. (The `Result(drafts, warning:)` surfacing and Keychain move were already done in the entries above.)

Still deferred (correctly): store-URL split (no observed bug; risky migration with no payoff), query-sort normalization (already correct — classic timeline + HomeView both re-sort in memory), and the file-size/architecture refactor (broad, no correctness benefit). No `@Model` schema change in any of this.

### 2026-06-15 - macOS settings menu stability pass
- **Category:** Bug fix, UX polish
- **Severity:** Major
- **Difficulty:** Moderate
- **Verification:** Pending build and UI check.
- **Learning:** macOS `Menu` rows inside a scrolling settings surface need stable geometry. If the selected-row checkmark or label width changes while the underlying page scrolls, the menu appears to jitter and the popover can feel like it is drifting.

Adjusted the macOS settings picker rows so the selected checkmark now uses a fixed-width slot and the menu labels use a stable value layout. This should stop the Light/Dark, App Store, and Apple Intelligence analyzer pickers from reflowing awkwardly while the settings page scrolls.

### 2026-06-15 - Expired guidance refresh
- **Category:** Docs
- **Severity:** Minor
- **Difficulty:** Easy
- **Verification:** N/A
- **Learning:** Copied project guidance from another app should be replaced before it starts steering future changes.

Replaced the borrowed HomeHub-facing `AGENTS.md` with an Expired-specific compatibility pointer and reset the implementation log to the Expired product direction.

### 2026-06-14 - SwiftData/CloudKit foundation and settings diagnostics
- **Category:** Architecture, Feature, UX polish
- **Severity:** Major
- **Difficulty:** Moderate
- **Verification:** App build and simulator validation in progress in the working branch.
- **Learning:** CloudKit needs deliberate diagnostics and clear user-facing settings, especially when the app depends on sync for cross-device continuity.

Built the current Expired foundation around SwiftData + CloudKit, added persistent settings for currency, appearance, notification time, iCloud sync, and AI screenshot import provider selection, and exposed CloudKit debug information so sync behavior can be inspected without guessing.

