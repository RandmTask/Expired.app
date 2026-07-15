# Expired — Implementation Log

## 2026-07-15 — R2 Phase 2: AI website lookup ("Read Page with AI")

Scoped via a locked 10-question round (see `ROADMAP.md`'s R2 Phase 2 entry for the
full decision list) before writing any code, since this was a genuinely new
sub-feature (new proxy capability, prompt design, an SSRF-relevant server change) —
not a case where the shared instructions' "ask before building" bar could be skipped.

- **`supabase/functions/_shared/pageFetch.ts`** (new): SSRF-guarded server-side
  webpage fetch + text extraction. Three defense layers: (1) reject IP-literal
  hosts and known-internal hostnames (`localhost`, `*.local`, `*.internal`)
  outright — a real subscription site is never a bare IP; (2) `redirect: "manual"`
  with every hop re-validated against the same checks, capped at 3 — `fetch()`'s
  default automatic redirect-following would silently bypass the initial host
  check on a redirect to an internal address; (3) best-effort `Deno.resolveDns`
  check for DNS-rebinding, feature-detected and skipped (not failed open or
  closed) where the edge runtime doesn't support it. Explicitly documented in the
  file header that DNS-rebinding isn't fully closed without guaranteed DNS
  resolution support — an honest caveat rather than an overclaimed guarantee.
  HTML is reduced to `<title>` + meta description + visible text (scripts/styles/
  comments stripped), truncated to ~6000 chars, capped at 500KB read and an 8s
  timeout.
- **`supabase/functions/ai-proxy/index.ts`**: added an optional `url` field to the
  request body (mutually exclusive with `visionPrompt`/`textPrompt`/`image`).
  When present, step 4c (after the existing entitlement + daily-cap checks, before
  the provider cascade loop) fetches+extracts the page and builds the text prompt
  server-side, returning 422 on any fetch failure. Deliberately did **not** add a
  new proxy function or a separate rate-limit counter — the existing cascade loop,
  entitlement gate, and usage cap are mode-agnostic already, so `url` mode falls
  through the same machinery `visionPrompt`/`textPrompt` calls already use.
  `buildRequestBody`'s existing `useVision = VISION_CAPABLE.has(provider) &&
  !!args.image` naturally resolves to the text-only branch for every provider
  since url-lookup calls never set `image` — no change needed there.
- **Rejected: separate app_config rate-limit key for URL lookups** — the locked
  decision was to share the cap with screenshot import; a dedicated key would
  need a migration for a distinction the proxy doesn't otherwise make.
- **`Expired/Services/URLLookupAnalyzer.swift`** (new): client call + per-provider
  response parsing. Deliberately **duplicates** (rather than shares)
  `ScreenshotImportAnalyzer`'s private `openAIContent`/`claudeContent`/
  `geminiContent` extractors — same call made in R2 Phase 1 for the iTunes search
  duplication: touching a proven, heavily-tested file for a shared-helper
  extraction isn't worth it for ~20 lines. On any failure (network, non-2xx,
  JSON that doesn't parse to a usable `name`/`price`), throws — no internal
  fallback here, since the *caller* (`AddItemHubView`) owns the fallback-to-
  Phase-1 decision, keeping this file a pure "try AI, throw on failure" unit.
- **`AddEditSubscriptionView.swift`**: `AddEditPrefill` gained `cost: Double?`,
  `currency: String?`, `billingCycle: BillingCycle?` (all populated only by this
  route — Search/URL-without-AI never set them). `applyPrefill()` applies
  `currency` before `cost` so `CurrencyInfo.formatForEntry` formats with the
  prefilled currency, not whatever was already in the field.
- **`AddItemHubView.swift`**: new `aiURLRow` alongside the existing `urlRow`,
  gated on `purchaseManager.isPremium` (lock icon + `onRequirePaywall()` callback
  when not Pro — new closure param, wired in `HomeView` to
  `showingAddHub = false; showPaywall = true`, mirroring how the Screenshot route
  already reaches the paywall through `HomeView`). `resolveURLPrefillWithAI()`
  calls the analyzer; on success, backfills a missing AI-guessed name with the
  same host-based guess Phase 1 uses (`guessName(fromHost:)`) rather than leaving
  it blank; on failure, calls the existing `resolveURLPrefill()` directly (self-
  contained — it re-sets its own `resolvingID` and calls `onSelectPrefill` itself,
  so no refactor was needed to reuse it as the fallback path).

**Build:** iOS Simulator + macOS both `BUILD SUCCEEDED` (`DEVELOPER_DIR=Xcode-beta`).
`deno check` clean on both new/changed `.ts` files (no Deno project config in this
repo, so this is the type-check, not a full Supabase local-serve run).

**How to test:** **Not deployed yet** — `supabase functions deploy ai-proxy` needs
to be run before any of this is live (added to `TEST.md`; this is a state-changing
action against shared infra, wasn't run without Deon's go-ahead). Once deployed: (1)
`+` → Search → paste a real subscription page URL with a visible price → "Read Page
with AI" → confirm name/price/currency/cycle prefilled. (2) A page with no visible
price or heavy client-side rendering → confirm silent fallback to the favicon+name-
only Phase 1 result, no error shown. (3) Downgrade/test a non-Pro account → tapping
"Read Page with AI" should show the paywall immediately, no network call (check
console/Charles for zero `ai-proxy` traffic). (4) `curl` the deployed function
directly with `"url": "http://169.254.169.254/"` and confirm a 422, not a 200 —
this is the one check that can't wait for the app UI, since a passing server-side
SSRF guard test is what actually validates the security claim above.

## 2026-07-12 — R2: Best-in-class import flow, Phase 1 (Add Item hub)

Roadmap item R2 (composition of existing pieces into one guided "Add Item" hub with
Search / Screenshot / Manual routes, all converging on `AddEditSubscriptionView`'s
review step). Built after R3 this session — see R3's entry below for why the order
flipped from the locked R1→R2→R3 build order.

- **`UI/AddItemHubView.swift`** (new): the hub sheet. A `List` with a unified search
  field at top and Screenshot/Manual rows below. Chose **not** to nest
  `AddEditSubscriptionView` inside the hub's own sheet — instead the hub takes three
  closures (`onSelectManual`, `onSelectScreenshot`, `onSelectPrefill`) and reports the
  user's choice back to `HomeView`, which dismisses the hub and then presents the real
  next sheet. Sidesteps sheet-over-sheet dismissal bugs entirely (the easy failure mode
  there: save succeeds but the user is stranded on the hub because only the inner sheet
  tore down).
- **Rejected approach:** extracting a shared `AppStoreSearchService` so the hub and
  `AddEditSubscriptionView`'s existing "Search App Store" sheet could share one iTunes
  client. Looked like the "don't duplicate" move, but it meant rewiring
  `AddEditSubscriptionView`'s already-working App Store search (which AC1 depends on)
  for zero functional gain. The hub owns its own ~15-line iTunes `search?term=` call
  instead — small, working duplication beats touching a proven flow.
- **`Services/AppCatalog.swift`**: added `search(_:limit:)` — a fuzzy multi-result
  lookup returning `SearchMatch` (name, appStoreId, category, optional bundled icon).
  Unlike the existing `localIconMatch(for:)` (exact match, requires a bundled icon —
  in practice only fires for the one catalog entry that has one, iCloud), `search`
  matches on substring containment across `lookupNames` and doesn't require an icon;
  results without a bundled icon get their artwork fetched lazily via iTunes lookup
  only when the user taps the row, keeping the live-typing list fast.
- **`UI/AddEditSubscriptionView.swift`**: added `AddEditPrefill` (name, url, iconData,
  iconSource, categoryRaw — deliberately **no** "AI-guessed" flag field; every Phase-1
  route landing on this form is catalog/iTunes/URL-detection, not AI, and the
  screenshot route has its own separate batch review sheet that never reaches this
  form) and an optional `prefill:` init param, defaulted `nil` so both existing call
  sites (`AddEditSubscriptionView(item: nil)`, `AddEditSubscriptionView(item: $0)`)
  needed no changes. `applyPrefill()` runs in `onAppear` after `populateFromItem()`,
  is a no-op when editing an existing item, sets `suppressNextFaviconFetch` before
  writing `url` (the existing `.onChange(of: url)` debounced-fetch guard, reused as-is)
  so the prefilled icon isn't immediately overwritten, and mirrors the existing
  `applyAppStoreResult`/`applyLocalCatalogIconIfAvailable` pattern of not bothering to
  suppress `isApplyingCatalogMatch` — if the prefilled name happens to also match a
  catalog entry, `handleNameChange` may re-apply that catalog's own icon on top, which
  is pre-existing behavior for the App Store search path too, not a new risk. The
  250ms auto-focus-name-field-on-appear (existing, for `!isEditing`) now also checks
  the prefill has no name, so a prefilled form doesn't pop the "Search App Store"
  prompt over an already-filled name field.
- **`UI/HomeView.swift`**: `openAddSheet()` (unchanged free-item-limit Pro gate) now
  sets `showingAddHub = true` instead of opening `AddEditSubscriptionView` directly.
  Added `showingAddHub` / `addHubPrefill` state and three sheets: the hub itself, the
  existing Manual `AddEditSubscriptionView(item: nil)` sheet (now reached via the hub's
  Manual row), and a new prefill-driven sheet gated on `addHubPrefill != nil`.
  `triggerScreenshotImport()` (existing, Pro-gated) is unchanged — the hub's Screenshot
  route just calls it after dismissing itself.

**How to test:** Build succeeded on iOS Simulator + macOS this session
(`xcodebuild ... -destination 'generic/platform=iOS Simulator'` and
`-destination 'platform=macOS'`, both `DEVELOPER_DIR=Xcode-beta`). No interactive
Simulator walkthrough yet — Deon declined booting the Simulator this session. Manual
test plan for next session against the roadmap's 4 ACs: (1) tap `+` → Search → type
"Netflix" → tap the iTunes result → confirm icon/name/category prefilled, ≤3
interactions to Add. (2) tap `+` → Screenshot → multi-subscription screenshot → existing
batch review still works unchanged. (3) tap `+` → Search → type a bare domain
("hulu.com") → tap the "Use…" row → confirm name/icon/category-guess prefilled and no
`ai-proxy` call fires (console/Charles). (4) tap `+` → Manual → confirm it reaches the
current Add form in one tap.

## 2026-07-12 — R3: Renewal forecast engine + UI (built out of locked R1→R2→R3 order)

Roadmap item R3 (forward cost forecast). Built before R2 this session: R2's remaining
scope (hub sheet, fuzzy `AppCatalog` search, URL-route detection, an
`AddEditSubscriptionView` prefill init, rewiring `HomeView`'s `+`) turned out to need
surgery across two ~2000–3800-line files and deserved its own session; R3 was small,
self-contained, and had a fully verifiable pure-function core, so it went first. No
schema change either way.

- **`Services/ForecastEngine.swift`** (new): pure `enum`, Foundation-only, generic over
  a new `ForecastContributing` protocol (`id`, `name`, `itemType`, `isCancelled`,
  `billingCycle`, `cost`, `currency`, `upcomingRenewalOccurrences(monthsAhead:reference
  Date:calendar:)`). `SubscriptionItem` conforms via a one-line `extension` — zero
  behavior change to the model, and the Xcode build compiling that conformance is the
  proof the protocol surface actually matches. Currency conversion is injected as a
  closure (`convert: (Double, String, String) -> Double`, real caller passes
  `CurrencyInfo.convert`) rather than calling `CurrencyInfo` directly, keeping the engine
  decoupled from every other file so it can be exercised standalone.
- **Contribution rules (locked 2026-07-05):** only `itemType == .subscription`,
  `!isCancelled`, `billingCycle != .oneOff` items with a non-nil `cost` contribute.
  Active trials fall out of the *existing* `upcomingRenewalOccurrences` for free (an
  active trial's guard clause already returns `[trialEndDate]` as a single occurrence at
  full cost) — no new trial-handling code needed in the engine itself. Documents
  (`itemType == .document`) are excluded by the same `itemType` guard, not a separate
  check.
- **`contributions(for:horizonDays:...)`** expands each item's occurrences up to
  `horizonDays` (padded one month past the exact horizon so month-granular expansion
  never truncates the last occurrence early), filters to `[referenceDate, horizonEnd]`,
  converts each occurrence's raw per-cycle `cost` (not a monthly-normalized figure — a
  yearly $120 sub contributes $120 once at its renewal date, not $10×12) to the target
  currency. `total`, `monthlyBuckets` (12 always-present calendar-month buckets, zero-
  filled where nothing lands, for a continuous bar chart), and `biggestUpcoming` (top-N
  by amount) all compose on top of `contributions`.
- **Verification — no XCTest target exists in this project** (adding one needs the
  Xcode GUI per the standing "new-target creation is GUI-only" rule; not done this
  session). Instead: a standalone script
  (`/private/tmp/.../scratchpad/ForecastEngineVerify.swift`, not checked in) mirrors
  `ForecastEngine`'s actual algorithm byte-for-byte (only `ItemType`/`BillingCycle` and
  the `SubscriptionItem` extension are swapped for local mirrors) against a `MockItem`
  and ran via `swift <script>` — all 4 roadmap ACs plus currency-conversion and
  bucketing checks passed. **Caveat:** `MockItem` reimplements a simplified
  `upcomingRenewalOccurrences` for the mock, so the *real* `SubscriptionItem` occurrence
  expansion is only compile-verified (via the protocol conformance), not exercised by
  this script. A real XCTest target would let the same test bodies run directly against
  `SubscriptionItem`.
- **UI** — new `forecastSection` in `InsightsView` (`ContentView.swift`), placed above
  the existing stats grid per the locked "Forecast at top of Insights" decision:
  30/90/365 segmented control (`ForecastHorizon` enum, same Pro-gate-and-revert pattern
  as the existing `CostPeriod` picker — reverts to 30-day + shows the paywall if a free
  user picks 90/365), headline total, new `ForecastMonthlyChart` (Swift Charts
  `BarMark`, first use of `import Charts` in this project) gated behind
  `purchaseManager.isPremium` with an inline unlock button when not, and a "Biggest
  upcoming hits" list (top 5 by amount). `import Charts` added to `ContentView.swift`.
- **Verified:** `xcodebuild` Debug **macOS** and **iOS Simulator** — both BUILD
  SUCCEEDED. **Not verified:** interactive Simulator/device walkthrough (chart
  rendering, Pro-revert animation, layout at real widths) — Simulator wasn't launched
  this session per the "ask first" rule. Status kept at 🟠, not flipped to 🟢, until a
  visual pass happens.
- **No `@Model`/CloudKit schema change** — no Dev→Prod redeploy needed.

This file is the source of truth for what has been built in Expired. It should stay specific to this app and should be updated whenever a meaningful user-facing or architectural change lands.

## Current State Summary

**Project:** Expired — subscription and document expiry tracker.
**Current phase:** Active product polish and stability cleanup.
**Stack today:** SwiftUI + SwiftData + CloudKit with local settings state and diagnostics.
**Platforms:** iOS and macOS in a single multiplatform target.
**Primary focus:** clean subscription cards, accurate expiry/status handling, reliable sync, and calm settings UX.

## 2026-07-05 — R1: Bulletproof reminder orchestration

Rebuilt the notification core from a per-item/single-time scheduler into an idempotent,
occurrence-aware orchestrator. Roadmap item R1; all product decisions were locked 2026-07-05.

- **Schema (additive, CloudKit-safe).** `NotificationRule` gains `fireHour: Int?`/`fireMinute:
  Int?` (per-rule time override, nil = inherit). `SubscriptionItem` gains `reminderHour:
  Int?`/`reminderMinute: Int?` (per-item default, nil = inherit global). All optional with nil
  defaults per the no-`@Attribute(.unique)`, defaults-on-every-field CloudKit rules. **⚠️ Dev→Prod
  schema redeploy required before the next TestFlight build.**
- **`isCritical` was dead** — stored on the model but hardcoded `false` in four places
  (`NotificationRuleDraft.init(rule:)`, `makeRule()`, `ReminderRuleRow.propagate()`,
  `AddEditSubscriptionView.reconcileNotifications`). Now wired end-to-end. Decision: critical =
  `.timeSensitive` interruption level, non-critical = `.active`; **not** pursuing Apple's Critical
  Alerts entitlement, so `.timeSensitive` is the strongest tier we ship.
- **Occurrence expansion.** New `SubscriptionItem.upcomingRenewalOccurrences(monthsAhead:)` reuses
  the existing private `renewalComponent`/`renewalStep` stepping (didn't duplicate it). Only true
  auto-renewing recurring subs expand across 12 months; documents, trials, cancelled-but-active,
  one-off/custom billing, and manual-renew return `[nextRelevantDate]` (single occurrence). This
  is *why* AC1 (renewal rollover) holds without waiting months: the whole schedule is recomputed
  from `Date()` on every trigger, so reopening the app after a renewal date simply recomputes the
  next cycle's occurrences.
- **Identifier scheme changed** from one-per-(item,rule) to
  `expired.<itemID>.<ruleID>.<occurrenceIndex>` so multiple future occurrences of the same rule can
  coexist. `exactDate` rules stay single (absolute, not multiplied across occurrences). All cleanup
  matches on the `"expired."` prefix and removes whatever's actually pending — never reconstructs
  the old identifier set (they may differ from what's about to be scheduled).
- **`refreshAll(context:)` is now the single entry point** — idempotent full rebuild: fetch every
  item fresh from the passed `ModelContext` (not a caller array — every old call site had a
  different `@Query` filter, exactly the inconsistent-source-of-truth bug class this codebase has
  been burned by), compute all fire moments, sort ascending, cap to the soonest 62 (headroom under
  iOS's 64 limit), clear all app-prefixed pending, reschedule. Pure `computeAllFireMoments` split
  out so the preview UI computes without scheduling. Removed the now-dead
  `reschedule(for:)`/`rescheduleAll(_:)`/`removeAll(for:)`.
- **Every call site converted to `refreshAll`.** This *fixed a latent bug for free*: archiving
  (in `HomeView.archiveItem`, `AddEditSubscriptionView.archiveAndDismiss`) and the HomeView undo
  closures (`restore`/`restoreCancellation`/`restoreArchive`) previously touched notifications not
  at all, so archived items kept firing. Now archived/expired/cancelled-past items simply don't
  appear in the recomputed set, so their pending requests clear on the next refresh. Triggered from
  `ExpiredApp` at launch, `scenePhase == .active`, and the existing CloudKit import-succeeded
  `.onReceive`.
- **Settings-time staleness audit fixed.** Global reminder time was read straight from
  `UserDefaults` while the KV↔UserDefaults sync only ran while `SettingsView` was on screen — a
  launch/import-triggered refresh before Settings ever appeared saw stale data. New
  `NotificationTimeSettings` accessor reads `NSUbiquitousKeyValueStore` first (with
  `synchronize()`), falls back to `UserDefaults`, then a hardcoded default; writes go to both
  stores. Same accessor holds the three new quiet-hours keys.
- **Quiet hours** (Settings → Notifications, default off; minutes-from-midnight ints in iCloud KV).
  Pure `applyQuietHours(to:startMinutes:endMinutes:calendar:)` handles the midnight-wrapping window:
  a non-critical time inside [start,end) shifts forward to the window end (23:00 → 08:00 next
  morning; 02:00 → 08:00 same day). Unit-checked against AC3 offline before wiring. Critical rules
  bypass entirely.
- **Time cascade** rule → item → global, applied in both the scheduler and the editor's live
  caption via one shared `NotificationManager.resolvedFireMoment(...)` helper so the preview and the
  real schedule can't silently drift.
- **15-minute snap picker.** New `QuarterHourTimePicker` — `UIViewRepresentable` wrapping
  `UIDatePicker(.time, minuteInterval: 15)` on iOS; on macOS keeps the native `.field` SwiftUI
  picker and snaps the value to the nearest quarter-hour in the setter (deliberate platform
  limitation — `UIViewRepresentable` doesn't apply, documented inline). Used for the per-item
  default time, per-rule override, quiet-hours start/end, and retrofitted onto the global Settings
  reminder-time picker.
- **UI.** `RemindersEditorView` rows gain a critical toggle (bell / bell.badge), a per-rule time
  override (clock affordance + inline picker), and a live "→ Mon 3 Aug, 9:00 am" resolved-fire
  caption. `AddEditSubscriptionView` gains a per-item default-time row. New free
  `ScheduledNotificationsView` (Settings → Notifications) lists computed upcoming notifications
  grouped by day with a validation row comparing the computed count to the actual
  `UNUserNotificationCenter` pending count (mismatch = visible warning) — doubles as the reliability
  debugger.
- **Verification.** Builds clean on iOS Simulator + macOS. Quiet-hours math unit-verified offline.
  App launches and runs (23-item dataset, no crash) so `refreshAll` at launch exercises the >64-cap
  path against real data. **Not** verified: interactive Simulator walkthrough (computer-use access
  to the Simulator was declined this session), on-device run (Deon's iPhone was offline), and AC5
  two-device sync (needs two devices).

## 2026-07-03 (cont.) — Debug Menu expansion, Home title/search, compact Insights

- **Debug Menu** (`DebugAIFailureSimulatorView` → retitled "Debug Menu"): the hidden
  long-press on the Settings "Analyzer" row now opens a multi-section developer sheet, not
  just the AI-failure toggles. Added: **Replay Onboarding** (iOS-only `fullScreenCover`
  presenting `OnboardingView` — presents the pager without touching
  `hasCompletedOnboarding`, so it's a preview, not a state reset), **Mascot Gallery**
  (`NavigationLink` → private `MascotGalleryView` showing all four `BearExpression`s at hero
  120pt + glyph 44pt), **Reset Subscriptions** (destructive, alert-confirmed), and a
  **CloudKit Debug** mirror (account/user-record/store text + Copy Log, reading
  `CloudKitDebugStore.shared`). Existing Force-Failure + Identity-Repair sections retained.
- **Reset Subscriptions data-safety:** deletes *all* `SubscriptionItem` rows (subscriptions
  + documents + archived) via `modelContext.fetch` → `NotificationManager.removeAll(for:)` +
  `modelContext.delete` (relying on the model's existing `.cascade` rule to drop child
  `NotificationRule`s — mirrors `HomeView.deleteItem`), then one `save()`. The confirmation
  alert explicitly warns it syncs to iCloud and removes items from **all** signed-in devices
  and cannot be undone. This is an *explicit* delete-all command, not derived from any UI
  array (respects the "never delete from array absence" rule).
- **Home title → "Expired"** (`HomeView` nav title; was "Subscriptions"). Personalization
  kept minimal this pass per Deon's call — static title only.
- **Search hidden until pull-down (iOS):** moved `.searchable(.navigationBarDrawer(.automatic))`
  off the outer `ZStack` (which wraps the `List` + floating undo/analyzing overlays) and onto
  the `List` itself, so iOS can bind `hidesSearchBarWhenScrolling` to that scroll view. The bar
  was staying pinned because the search field couldn't unambiguously associate with a scroll
  view through the ZStack. **Needs on-device/simulator visual verification** — hide-on-scroll
  can't be confirmed by a compile build.
- **Insights compacted (AutoSleep-style):** replaced `GlassInsightCard` (tall left-aligned
  glass card) with `CompactInsightTile` (tinted icon chip in a circle, big rounded value,
  small label, subtle color-tinted rounded background). The separate full-width cost hero +
  2-column counts grid collapsed into a single dense **3-column** grid holding all six metrics
  (Cost, Active, Auto-Renewing, Free Trials, Manual, Cancelled) — Deon chose "compact hero too".
  `costCard`/`countsRow` computed props replaced by one `compactStatsGrid`.
- **Verified:** `xcodebuild` Debug **macOS** and **iOS Simulator** — both BUILD SUCCEEDED.
- **No `@Model`/CloudKit schema change** — no Dev→Prod redeploy needed.

## 2026-07-03 — Mascot, onboarding pager, first-launch splash (iOS)

- **`ExpiredBear` mascot** (`UI/Mascot/ExpiredBear.swift`, new): pure-SwiftUI vector bear,
  no image assets — every dimension proportional to a `size` parameter so it scales from a
  44pt all-caught-up glyph to a 160pt onboarding hero. Four expressions: `.happy`, `.sleepy`,
  `.expired` (comic X-eyes + slight head tilt — a wink at the app's theme, not a scary face),
  `.celebrating`. Animations (breathe, randomized blink, spring bounce-in) are gated on
  `animated && !accessibilityReduceMotion`; blink runs via `.task(id:)` (auto-cancels on
  expression change/disappear, no manual `Timer`) and is skipped entirely for `.expired`
  (X eyes don't blink). Anonymous — no user-facing name, per Deon's call.
- **Onboarding pager** (`UI/Onboarding/OnboardingView.swift`, new, iOS-only): 5 pages
  (welcome, subscriptions+documents, Screenshot Import tease with `ProChip`, reminders +
  notification pre-prompt, soft Pro pitch). Notification permission is requested from page 4
  via the existing `NotificationManager.requestAuthorization()` — Continue is never blocked
  by permission state (denied/undetermined both render a non-blocking status line). Pro page
  reads `purchaseManager.offerings?.current?.annual?.storeProduct.introductoryDiscount` and
  only renders a trial line when `paymentMode == .freeTrial` is actually configured in
  RevenueCat — never claims a trial that isn't there; hides the line entirely if offerings
  haven't loaded (offline-safe). "Continue with Free" is always present and equal-weight to
  "Start Free Trial".
- **Gating** (`OnboardingGate` view modifier, applied to `ContentView` iOS-only): flag is
  `@AppStorage("hasCompletedOnboarding")` — **local UserDefaults, deliberately not synced via
  iCloud KV** (syncing it would race a CloudKit import setting the flag differently per
  device). Before showing anything, does a cheap `fetchCount` on `SubscriptionItem`; a
  nonzero count (reinstall, or CloudKit import already landed) sets the flag silently and
  skips onboarding entirely — self-heals the classic CloudKit-import-race edge case.
  Onboarding itself performs zero writes to the SwiftData store (no demo seeding, no other
  migration-style flags) and never consults CloudKit account status, so a mid-onboarding
  import on a fresh install is harmless — the user just finishes the pager normally.
- **First-launch splash**: folded into the same gate (no second flag) — `OnboardingSplashOverlay`
  shows a ~1.2s bear-blink + wordmark moment (0.4s under Reduce Motion) immediately before the
  pager on the very first launch only; every later launch skips straight past it.
- **Mascot wired into**: `EmptyStateView` (`.happy`, replacing the old circle+icon glyph),
  a new `AllCaughtUpCard` (`.celebrating`, shown under the hero card when items exist but
  nothing is due/trialing/urgent in the next 14 days, only with no active filter/search),
  and a new `ImportFailureSheet` (`.expired`) replacing the plain `.alert` for screenshot-import
  failures (no subscriptions detected, analyzer error, Photos permission denial).
- **Verified**: full `xcodebuild` (Debug, iOS Simulator, both arm64+x86_64 slices) —
  BUILD SUCCEEDED, zero errors.
- **Not done yet (Phase D, next up)**: `ai-proxy`'s RevenueCat entitlement check still
  unconditionally sends `X-Is-Sandbox: true` (its own code comment already flags this as a
  pre-launch blocker — production purchasers would 402); the `app_config` select also
  silently swallows its DB error instead of failing closed. Provider $ spend caps
  (OpenAI/Google/DeepSeek dashboards) and the RevenueCat/ASC 7-day yearly trial config are
  unverified from code — dashboard checks, offered separately.

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

## 2026-07-02 (cont.) — AI import 402 FULLY resolved: it was FIVE stacked bugs, not one

The identity-caching fix below was necessary but not sufficient — the 402 persisted through ~21
attempts because four more independent bugs sat behind it, each masking the next. Full list, in the
order they were peeled back (all now fixed; all generalized into `_shared/supabase-revenuecat.md`
gotchas #20, #25, #26, #27 + its debugging decision tree):

1. **RC identity caching** (#20) — `configure(appUserID:)` ignored on relaunch; fixed with explicit
   `logIn` when cached ≠ resolved. (Detailed entry below.)
2. **Webhook never configured** — `REVENUECAT_WEBHOOK_SECRET` existed in Supabase since 2026-06-30 but
   no webhook was ever created in the RC dashboard, so the `entitlements` mirror was never written by
   events. Created it (URL + Bearer secret, all events, both environments), verified with Send Test
   Event → 200 `{"ok":true,"skipped":"ignored type TEST"}`.
3. **`service_role` missing DML grants** (#26) — the *biggest* hidden one. `service_role` had only
   REFERENCES/TRIGGER/TRUNCATE on every `public` table since migration 0001, no SELECT/INSERT/UPDATE/
   DELETE. So every `ai-proxy` `app_config` read silently fell through to hardcoded defaults, and every
   `entitlements` mirror upsert failed — invisibly, because the code discarded the error. Surfaced only
   after enriching the 402 payload to report `mirror upsert failed: permission denied for table
   entitlements`. Fixed in migration `0005_grant_service_role.sql` (+ default privileges for future
   tables). Root misconception: "service_role bypasses RLS" ≠ "service_role has a table grant."
4. **REST lookup was production-only** (#27) — `GET /subscribers` returns only production purchases
   unless `X-Is-Sandbox: true` is sent; all purchases here are RC Test Store (no real App Store app
   exists yet), so the server saw `availableEntitlements=none`. Added the header (with a TODO to gate
   it before release). Confirmed via dashboard: toggling "Sandbox data" off showed the customer as
   "No current entitlements / USD 0".
5. **UUID case mismatch** (#25) — the final wall. `SupabaseService.currentUserID` returned
   `UUID.uuidString` (UPPERCASE), handed to RevenueCat; but the JWT `sub` the server checks is
   lowercase, and RC `app_user_id` is case-sensitive. Client attached purchases to the UPPERCASE
   customer; server checked the empty LOWERCASE one. The copy-log's `appUserID=8C0B…` vs
   `serverUserId=8c0b…` (differing only in case) was the smoking gun. Fixed with `.lowercased()` at
   the single source — client identity now == JWT sub == Postgres id.

**Debug tooling that made this tractable (kept in the app):** the import-failure banner now shows a
short friendly message, with a copy button that copies a *separate* rich debug log (server entitlement
check, local RC `appUserID` + `isPremium`, app version, timestamp, failure streak) — Deon's idea, and
the turning point. The server 402 was also enriched to report `checkedUserId`, `availableEntitlements`,
and any mirror-write error. Combined, these turned "paste your Xcode console" into a one-tap paste that
exposed bugs #3 and #5 directly.

**Process lesson (also added to `My Apps/CLAUDE.md` Process Playbook):** several of these were already
documented in `_shared/supabase-revenuecat.md` before this session started; reading that playbook's
gotcha list first would have short-circuited at least #20 and the Test Store confusion. Instrument the
failure and read the existing playbook before theorizing.

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
