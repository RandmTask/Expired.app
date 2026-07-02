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


---

## 2026-06-30 — Supabase + RevenueCat: build unblock + Tasks #5/#4/#6

**Build unblockers (3 errors):**
- **100 duplicate `RC*` symbols / linker failure.** Cause: the target linked
  `RevenueCat_CustomEntitlementComputation` *in addition to* `RevenueCat` + `RevenueCatUI`.
  That product is a standalone alternative build of RevenueCat carrying the same ObjC classes —
  never combine them. Removed it from the pbxproj (build file, Frameworks phase, package product
  dependency, XCSwiftPackageProductDependency). Decision: edit the pbxproj directly (4 discrete,
  well-contained references) rather than the Xcode GUI, since it's deterministic and verifiable.
- `BackupService.writeAutomaticBackup` chain called from `Task.detached` → marked the whole
  off-main chain (`writeAutomaticBackup`/`backupsDirectory`/`pruneAutomaticBackups`/`modDate`)
  `nonisolated` (touches only FileManager/UserDefaults). The *whole* chain must be marked, not
  just the entry point.
- `AddEditSubscriptionView` `.map(NotificationRuleDraft.init(rule:))` — a point-free reference to
  a main-actor-isolated initializer can't satisfy `map`'s non-isolated function type. Replaced with
  an explicit closure `{ NotificationRuleDraft(rule: $0) }`, which defers the call into the
  main-actor context.

**Task #5 — launch wiring.** `ExpiredApp` ContentView gets a non-blocking `.task`:
`SupabaseService.ensureSession()` then `PurchaseManager.configure(appUserID:)`, and
`.environment(PurchaseManager.shared)` for gates. Chose a `.task` over `init()` work so it's tied to
view lifecycle and never blocks launch.

**Task #4 — proxy reroute.** Added `ScreenshotAIProvider.proxyID`. New `proxyForData(provider:model:body:)`
posts `{provider, model, body}` to `ai-proxy` via `authorizedFunctionRequest`; the four provider
functions now build the same body dicts (Gemini omits `model` — proxy puts it in the URL) and reuse the
existing response parsers untouched. `listModels` routes through the `models` fn (kept its `apiKey`
param, now ignored, to avoid touching call sites this batch). On-device key reads removed from the
analyzer; `ScreenshotAISettings.apiKey` kept (migration still needs Keychain).

**Task #6 — paywall + gates.** New `UI/Paywall.swift`: `expiredPaywallSheet` (RevenueCatUI `PaywallView`,
works on macOS), `expiredCustomerCenterSheet` (`CustomerCenterView` is iOS-only → macOS fallback
`MacManageSubscriptionSheet` with Restore + guidance), `ProLockBadge`. Gates (lock badge + paywall on
tap, per Deon's choice): TimelineView ViewMode (Timeline/Calendar free; `effectiveViewMode` degrades a
Pro selection on lapse without losing the saved preference), InsightsView CostPeriod (Monthly free;
segmented control reverts + paywalls on a Pro tap), HomeView AI import + 5-item cap (active-only count =
`allItems` which is already `!isArchived`), CategoriesView custom-category add, Settings manual Export.
Added an "Expired Pro" section (upgrade / manage / restore) to both Settings bodies. Removed the raw-key
entry UI + RED security warning (key now lives server-side).

**Deferred:** currency-conversion gating (ambiguous — needs a behaviour decision).

## 2026-07-01 — Server-side AI fallback cascade + cost controls

- **Cascade replaces single-provider selection.** New "Automatic" mode (now the default
  `ScreenshotAIProvider` case): tries Apple Intelligence on-device first, and only on
  failure calls `ai-proxy` with `mode: "auto"`, which tries cloud providers from
  `app_config.ai_fallback_order` (seeded `["gemini", "deepseek"]`) in one round trip —
  no client round-trip between provider attempts. `ai-proxy` now builds each provider's
  request body itself (`providers.ts` `buildRequestBody`); the client sends one generic
  `{visionPrompt, textPrompt, image}` payload and gets back `{provider, model, raw}`, then
  picks the matching extractor client-side. Manual/debug single-provider picker still
  works (`mode: "forced"`), now going through the same endpoint. Removed 5 near-duplicate
  per-provider request-builder functions from the Swift client as a result.
- **Config-driven models, not hardcoded.** `app_config.ai_model_<provider>` rows resolve
  the cascade's model IDs — changing a provider's model is a Table Editor row edit, no
  release. Swift/`providers.ts` hardcoded defaults are last-resort fallbacks only, used
  if the config row is missing.
- **Gemini default corrected mid-session:** seeded `gemini-2.5-flash`, then corrected to
  `gemini-3.1-flash-lite` after checking Google's actual pricing page (Deon caught this) —
  cheaper ($0.25/$1.50 vs $0.30/$2.50 per 1M tokens) and explicitly positioned by Google
  for "simple data processing" tasks, a closer fit than the general-purpose 2.5 Flash tier.
- **Cost controls, added after realizing the shipped cascade had none:**
  - App-wide `global_daily_request_cap` (500/day default) on top of the existing per-user
    `daily_request_cap` (50/day) — a per-user cap alone doesn't catch a viral spike or a
    client retry-storm bug spread thin across many accounts.
  - `usage.token_estimate` was dead code (always 0, `increment_usage` never got a token
    count). Now extracts each provider's real usage field
    (`usage.total_tokens` / Claude's input+output / Gemini's `usageMetadata.totalTokenCount`)
    and records it per successful call.
  - Screenshots are downscaled to a 1024px long edge + re-encoded JPEG (quality 0.8)
    before upload to any vision provider — only the network copy; on-device Vision-framework
    OCR (used for local heuristics/repair and Apple Intelligence) still runs against the
    original full-resolution image.
  - **Decision, not yet built:** cropping to the OCR-recognized content bounding box before
    downscaling would get much closer to genuinely cheap "UI crop" pricing (vs. a naive
    full-frame downscale) without the legibility risk of just shrinking further (e.g. to
    512px) — screenshots are dense with small price/date text, and misreading a digit is a
    data-integrity problem, not just a cost one. **Deferred until real usage data shows the
    AI bill is actually worth optimizing further** — at pre-launch scale (no App Store users
    yet) the whole monthly bill is a few dollars regardless, so the accuracy trade isn't
    worth it yet.
  - True dollar-based spend caps live in each provider's own dashboard (OpenAI billing
    limits, Google Cloud budget alerts, DeepSeek's prepaid balance is self-limiting by
    design) — the app's own caps are insurance on top of that, not a replacement for it.
- **Debug/testing tooling (Phase 2):** hidden long-press on the Settings "Analyzer" row
  opens a debug sheet with a per-provider "force fail" toggle, so the cascade's skip-on-
  failure path can be exercised without a real outage (`ai-proxy` already supported
  `simulateFailures` from the Phase 1 design — no server change needed). Client tracks
  consecutive fallback-to-heuristic events in UserDefaults and appends a note to the
  existing import-warning banner once it crosses a threshold, rather than adding new UI.
  `provider_health` table + `record_provider_health()` fn track consecutive
  failures/last-success per provider as a byproduct of **real cascade traffic** — chose
  this over a separately scheduled synthetic health-check ping (the original plan) because
  pinging providers on a timer to check health would itself spend real tokens; deriving it
  from real calls is free and a more accurate signal anyway. A real alert channel
  (Slack/email on sustained failure) is still a genuine follow-up, not built this batch.
- **No CloudKit/SwiftData schema change.** Everything above is Supabase config
  (`app_config` rows, new `provider_health` table) + Swift `UserDefaults`.

**No schema changes.** SwiftData/CloudKit model untouched.

## 2026-07-02 — RevenueCat identity bug: root-caused and fixed (AI import 402 blocker)

- **Root cause found and confirmed, not just theorized.** `PurchaseManager.configure(appUserID:)`
  passes the Supabase anonymous UUID to `Purchases.configure(with:)` on every launch
  (`ExpiredApp.swift`'s `.task`). RevenueCat's SDK only honors that `appUserID` param the very
  first time a device ever configures — on every later launch, if RevenueCat already has *any*
  cached identity, `configure()` silently keeps using it and ignores the freshly-passed UUID.
  This device had several cached identities from earlier debug flows (`logOutForTesting()`,
  `resyncIdentityToCurrentSession()`), so a real Lifetime purchase attached to whichever
  identity happened to be cached at purchase time — not the Supabase UUID `ai-proxy` checks.
- **Confirmed concretely via RevenueCat dashboard + Supabase SQL editor** (both already
  authenticated in the connected browser — no credentials entered): Supabase `auth.users` has
  exactly one user ever, `8c0b2c5d-3fe4-421b-9d7f-12a5917de411`. `public.entitlements` (the
  webhook-mirrored table `ai-proxy` reads first) had zero rows for anyone. RevenueCat's
  Sandbox customer list showed that exact UUID as a customer with $649.44 of *expired monthly*
  test-subscription history but zero active entitlements — while the active, unlimited-duration
  Lifetime Pro entitlement ($99.99) sat on a completely different RevenueCat customer ID
  (`9135CED8-B974-4173-8811-CDFA9B0A5E52`), created 16 minutes after the Supabase UUID first
  configured. Never merged/aliased. Exactly the split the theory predicted.
- **Fix:** `PurchaseManager.configure()` now compares `Purchases.shared.appUserID` against the
  resolved Supabase UUID immediately after `Purchases.configure(...)`, and if they differ, calls
  `Purchases.shared.logIn(appUserID)` followed by `restorePurchases()` — the same repair
  `resyncIdentityToCurrentSession()` already did manually, now run automatically on every
  launch instead of requiring the hidden debug button. On the next launch on the *same* device
  that made the Lifetime purchase, this should self-heal: `restorePurchases()` reads the local
  App Store receipt and reattaches the entitlement to the now-correctly-logged-in Supabase
  identity. Verify by relaunching and checking `[PurchaseManager]` console output, then retrying
  an AI screenshot import — the 402 should clear.
- **Learned:** never assume a "purchase not recognized" bug is data/backend-side without first
  diffing the RevenueCat customer *identity* the purchase landed on against the identity the
  server is checking — a same-device, same-session purchase can still land on the wrong
  RevenueCat customer if the SDK's cached identity has drifted from what the app *thinks* it
  configured with. Debug flows that call `logIn()` (test resets, resyncs) leave the SDK's local
  identity cache in a state that silently overrides `configure(appUserID:)` on every future
  launch until explicitly corrected.

**No schema changes.** SwiftData/CloudKit model untouched (this was Swift client + verification
only — no new Supabase migration needed since `entitlements`/webhook plumbing already existed).

- **Follow-up: RevenueCat webhook was never actually configured.** The `entitlements` table had
  zero rows for *any* user, not just the affected one — checking RevenueCat's dashboard
  (Project Settings → Integrations → Webhooks) showed no webhook had ever been created, despite
  `REVENUECAT_WEBHOOK_SECRET` already existing as a Supabase function secret since 2026-06-30.
  Half-finished setup: the secret existed, nothing was ever configured to send events using it.
  Fixed by generating a fresh secret (`openssl rand -hex 32`), setting it via
  `supabase secrets set REVENUECAT_WEBHOOK_SECRET=... --project-ref ehibtlaoshmqpbnexehy`, and
  creating the webhook in RevenueCat (URL `.../functions/v1/revenuecat-webhook`, `Bearer <secret>`
  auth header, Both Production and Sandbox, all events). Verified end-to-end with RevenueCat's
  "Send test event" — 200 response, body `{"ok":true,"skipped":"ignored type TEST"}`, confirming
  the URL, auth header, and function logic all agree. `entitlements` will now self-populate from
  real purchase/renewal/expiration events going forward instead of relying solely on `ai-proxy`'s
  live-fallback API call on every request.
- **Note for next session:** while testing this in the browser, clicking the "show/hide" eye icon
  on the webhook form's Authorization-header field appeared to trigger a conflict with a
  password-manager-style browser extension — the tab briefly became unreachable
  (`Cannot access a chrome-extension:// URL of different extension`) and the form silently reset
  its fields. Avoid that reveal toggle on secret-like fields in this browser profile; re-filling
  and submitting without touching it worked fine.
