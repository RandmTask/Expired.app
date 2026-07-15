# Expired — Roadmap

Structure per [`_shared/roadmap-conventions.md`](../_shared/roadmap-conventions.md).
Blueprints live on the item itself. `IMPLEMENTATION_LOG.md` is the changelog — never
scope a batch from a log entry.

**Status legend:** 🟢 Shipped · 🟠 In progress · 🔴 Not started (even if fully blueprinted)

---

## Launch gate (blocks TestFlight/App Store, not the roadmap items below)

Found while deploying the sandbox-entitlement fix (2026-07-05). Items below in Pre/Post-v1.0
are safe to build regardless of gate status.

- 🟠 **No real App Store Connect app in RevenueCat** — only the synthetic Test Store exists
  (Monthly/Yearly/Lifetime Pro). No ASC app means no real subscription to put a trial on.
- 🔴 **7-day free trial on the yearly plan** — an ASC Introductory Offer, set once the item
  above is done. Currently unconfigured.
- 🟠 **`allow_sandbox_entitlements` flip to `false`** — migration 0006 shipped + deployed,
  `ai-proxy` now checks production-first, config row seeded `true` to preserve the current
  Test Store flow. Must flip to `false` at/just before launch (one SQL statement, see the
  migration's header comment) or real purchasers get 402'd.
- 🔴 **Critical Alerts entitlement** — request submitted 2026-06-30, pending Apple approval.
- 🔴 **OpenAI spend limit** — not verified this session (not logged into the OpenAI platform
  in the browser used to check the others). DeepSeek confirmed fine (prepaid, balance alert
  on).
- 🔴 **Google Cloud (Gemini) budget alert** — blocked: the Google account has pending MFA
  enforcement, locking the whole Cloud Console including billing until 2SV is enabled.
- 🔴 **`update-exchange-rates` cron schedule** — migration 0007 documents scheduling the
  function at `0 5 * * *` UTC in the dashboard; not confirmed done. Without it, currency
  conversion silently falls back to `CurrencyInfo`'s hardcoded snapshot.

## Pre-v1.0

### R1. Bulletproof reminder orchestration 🟠 — ⚠️ CloudKit schema change

> **Status (2026-07-05):** Built and building on iOS + macOS. AC1–AC4 verified by
> construction + logic (quiet-hours math unit-checked; occurrence expansion + cap idempotent
> from `Date()`). **Outstanding:** AC5 (two-device sync) untestable with one device this
> session; on-device re-verification pending (Deon's iPhone was offline — ran on iPhone 17 Pro
> Simulator only); interactive Simulator UI walkthrough not completed (computer-use access to
> the Simulator was declined). ⚠️ **CloudKit Dev→Prod schema redeploy required before next
> TestFlight** (new fields below).
>
> **Follow-up same day:** `main` (`ccd841d`) didn't actually compile — `NotificationManager
> .removeAll(for:)` was called from 4 files (including already-committed ones) but had been
> dropped from `NotificationManager.swift` at some point in history unnoticed. Restored it
> (identifier-prefix sweep via `getPendingNotificationRequests`, matching `refreshAll`'s
> approach rather than the old per-rule-identifier reconstruction). `ContentView.swift` also
> called a `rescheduleAll(_ items:)` that no longer exists; its 3 call sites now call
> `refreshAll(context: modelContext)` instead. Both platforms build clean after the fix.
> Also cleared stray leftover `xcodebuild` processes that were holding the DerivedData build
> lock (`database is locked` failures) — see CLAUDE.md's "stray xcodebuild" note.

Make notifications the most trustworthy part of the app: per-item and per-rule fire
times, quiet hours, critical vs non-critical handling, durable rescheduling, and a
"what will fire when" preview.

**Already exists (don't rebuild):** `NotificationRule` @Model (multiple rules per item,
offset types, cascade delete, CloudKit-safe raw strings), draft-based
`RemindersEditorView`, `NotificationManager` with per-rule scheduling at a single global
time. `isCritical` is stored but wired to nothing (editor hardcodes `false`).

**Decisions locked (2026-07-05):**
- Time granularity: per-item default time **plus** optional per-rule override.
  Resolution cascade: rule time → item time → global setting (default 9:00).
- Quiet hours: one global setting (Settings → Notifications), default off.
  Non-critical reminders landing inside the window shift **forward** to window end
  (next morning). Critical reminders bypass quiet hours.
- Critical = `.timeSensitive` interruption level; non-critical = `.active`.
  **Not** pursuing Apple's Critical Alerts entitlement.
- All time pickers snap to 15-minute intervals (needs `UIViewRepresentable` wrapper
  around `UIDatePicker` — SwiftUI doesn't expose `minuteInterval`).
- Preview on both surfaces: inline resolved date+time per rule row, plus a global
  "Scheduled Notifications" screen (free, doubles as the reliability debugger).

**Schema (additive, CloudKit-safe, ⚠️ Dev→Prod redeploy before next TestFlight):**
- `NotificationRule`: `fireHour: Int? = nil`, `fireMinute: Int? = nil` (nil = inherit item)
- `SubscriptionItem`: `reminderHour: Int? = nil`, `reminderMinute: Int? = nil` (nil = global)

**Orchestrator (core of the item):** extend `NotificationManager` with a full-rebuild
entry point (`refreshAll`) — idempotent: remove all app-prefixed pending requests,
recompute, re-add. Triggered on app launch, `scenePhase == .active`, CloudKit remote
change (via `CloudKitSyncMonitor`), and item save/archive/delete.
- **Occurrence expansion:** for recurring auto-renew items, expand occurrences up to
  12 months ahead (reuse `nextLiveRenewalDate()` stepping) and apply every rule to every
  occurrence — so reminders keep firing even if the app isn't opened for months.
- **64-cap handling:** globally sort all computed fire dates ascending, schedule the
  nearest ~62 (headroom), refill on every refresh trigger.
- Skip archived/expired/cancelled-past items; never schedule past fire dates.
- Wire `isCritical` through `NotificationRuleDraft` and `RemindersEditorView`
  (currently dropped in `init(rule:)` and `propagate()`).
- Audit: global notification time is read from `UserDefaults`
  (`NotificationManager.swift:82`) but docs claim `NSUbiquitousKeyValueStore` sync —
  unify to iCloud KV with UserDefaults fallback. Quiet-hours setting also lives in
  iCloud KV (minutes-from-midnight Ints).

**Preview UI:**
- Each rule row shows its resolved fire moment ("→ Mon 3 Aug, 9:00 am") as a caption.
- Settings → Notifications → **Scheduled Notifications**: computed upcoming
  notifications grouped by date, with a validation row comparing computed count vs
  actual `UNUserNotificationCenter` pending count (mismatch = visible warning).

**Acceptance criteria:**
1. With the app untouched across a renewal date, reopening it schedules the next
   cycle's reminders (verify in Scheduled Notifications).
2. >64 computed notifications → nearest ~62 scheduled, refill works on foreground.
3. Quiet hours 22:00–08:00: non-critical rule resolving to 23:00 fires 08:00 next
   morning; critical rule fires at 23:00.
4. Per-rule time overrides per-item time overrides global time.
5. Two-device: editing rules on device A reschedules correctly on device B after sync.

---

### R2. Best-in-class import flow (Phase 1) 🟢 — no schema change

> **Status (2026-07-12):** Built and compiling clean on iOS + macOS. `AddItemHubView`
> (new) replaces the bare `+` action; `openAddSheet()` now opens the hub instead of
> going straight to `AddEditSubscriptionView`, preserving the existing free-item-limit
> gate. Screenshot route calls back into `HomeView`'s existing `triggerScreenshotImport()`
> (Pro gate untouched); Manual and Search routes report their choice back to `HomeView`
> via callbacks rather than nesting a sheet inside the hub's sheet — avoids sheet-over-
> sheet entirely. `AddEditSubscriptionView` gained an `AddEditPrefill` struct + optional
> `prefill:` init param (defaulted `nil`, so both existing call sites are untouched);
> applying a prefill sets `suppressNextFaviconFetch` so the debounced favicon fetch
> doesn't clobber a prefilled icon, and skips the 250ms name auto-focus when the prefill
> already has a name (avoids popping the redundant "Search App Store" prompt on an
> already-filled form). `AppCatalog` gained `search(_:limit:)` — a fuzzy multi-result
> lookup (unlike `localIconMatch`, doesn't require a bundled icon to match). The unified
> search list merges local catalog matches + a debounced iTunes text search + URL/domain
> detection, all inline in the hub (no separate search sheet). **Outstanding:** no
> interactive Simulator walkthrough this session (declined — same iOS + macOS build-clean
> bar as R1/R3; ask before booting the Simulator next session to walk the 4 ACs).

One guided "Add Item" capture hub replacing the bare + action, with three routes that
all converge on a single review step. Composition of existing pieces — the new build is
the hub, the unified search, and the review UX.

**Already exists (don't rebuild):** AI screenshot import (`ScreenshotImportAnalyzer` via
Supabase `ai-proxy` cascade), App Store search sheet inside `AddEditSubscriptionView`,
`AppCatalog` suggestions, `FaviconFetcher`.

**Decisions locked (2026-07-05):**
- Hub sheet with three routes: **Search** / **Screenshot** / **Manual**.
- Unified search: one field querying `AppCatalog` matches + App Store results + URL
  detection. Typed domain/URL → favicon + name + category-guess prefill (catalog match,
  **no AI** in Phase 1 — AI page reading is R2 Phase 2, Post-v1.0).
- All routes land on a prefilled Add/Edit review step; AI-guessed fields are visually
  flagged for checking.
- Multi-item screenshot results go through a batch review list (per-row include toggle
  + inline edit) before anything is saved.

**Acceptance criteria:**
1. Adding Netflix via search = type, tap result, confirm (≤3 interactions), with icon,
   name, and category prefilled.
2. Screenshot containing 5 subscriptions → deselect 2 in review → exactly 3 saved.
3. Entering a URL prefills name, icon, and category guess without any AI call.
4. Manual route reaches the current Add/Edit form in one tap.

---

### R3. Renewal timeline + forward cost forecast 🟠 — no schema change

> **Status (2026-07-12):** `ForecastEngine` built and algorithm-verified (all 4 ACs pass
> against the real expansion/filter/bucket logic via a standalone script — see log).
> Forecast UI (segmented 30/90/365 control, headline total, 12-month Swift Charts bar
> chart, biggest-upcoming-hits list) added to `InsightsView`, builds clean on iOS +
> macOS. **Outstanding:** no visual/interactive verification (Simulator access wasn't
> used this session — ask before booting it), no XCTest target exists in the project to
> house AC5's tests in-tree (`ForecastEngine`'s protocol-based design makes adding one
> trivial whenever Deon creates the target via Xcode GUI).

Turn Insights into a forward-looking spend forecast: what will I pay in the next
30/90/365 days, and how does that land month by month.

**Already exists (don't rebuild):** `InsightsView` Monthly/Annual/YTD/Lifetime totals
with currency conversion; `TimelineView` with 6 view modes; `CurrencyRateService`
(live rates); `nextLiveRenewalDate()` occurrence stepping on the model.

**Decisions locked (2026-07-05):**
- Placement: new **Forecast** section at the top of Insights. Timeline stays
  event-centric (no new Timeline mode).
- Gating: 30-day forecast free; 90/365 horizons + monthly chart are Pro (consistent
  with existing Monthly-free/rest-Pro pattern).
- Contents: active trials count from trial-end at full cost; cancelled-but-active
  excluded; one-offs excluded; documents excluded (no cost).
- Conversion via `CurrencyRateService` into `preferredCurrency`.

**Build:**
- `ForecastEngine` — pure, unit-testable struct: expands each contributing item's
  occurrences over the horizon (reuse the `nextLiveRenewalDate` stepping logic),
  converts currency, returns dated amounts + monthly buckets.
- UI: 30/90/365 segmented control, headline total, 12-month bar chart (Swift Charts),
  "biggest upcoming hits" list (top items by amount within the horizon).

**Acceptance criteria:**
1. Monthly $10 sub → ≈$10 / $30 / $120 across 30/90/365 (cycle-alignment tolerance).
2. Yearly sub renewing in 40 days appears in 90/365 but not 30.
3. Trial converting in 10 days contributes from its trial-end date.
4. Cancelled-but-active and one-off items contribute nothing.
5. `ForecastEngine` covered by unit tests for all four rules above.

---

**Build order: R1 → R2 → R3** (locked 2026-07-05 — reminders are the app's core job).

## Post-v1.0

### R2. Import flow — Phase 2: AI website lookup 🟠 — no schema change

> **Status (2026-07-15):** Built and compiling clean on iOS + macOS. **Not yet
> deployed** — `supabase functions deploy ai-proxy` hasn't been run; the new `url`
> mode is dead code in production until that happens (state-changing infra action,
> needs Deon's go-ahead, see `TEST.md`). No live test against a real site yet either
> (needs the deploy first).

Extends the unified search's URL route with AI-assisted page reading via the
`ai-proxy` (name, price, currency, billing cycle extracted from the subscription's
website), as a second, explicit, Pro-gated option alongside Phase 1's instant no-AI
"Use…" row — not a replacement for it.

**Decisions locked (2026-07-13):**
- Extends the existing `ai-proxy` function (`mode: "auto"|"forced"` unchanged, new
  optional `url` field) rather than a separate edge function — reuses its
  auth/entitlement/rate-limit/kill-switch plumbing as-is.
- Server-side fetch: the proxy fetches the target URL itself, not the client
  (client-side fetch of arbitrary sites fails on CORS/bot-blocking for most real
  sites anyway).
- SSRF guardrail: reject IP-literal hosts and known-internal hostnames
  (`localhost`, `*.local`, `*.internal`), https-only, manual redirect handling
  (re-validates every hop, capped at 3), 500KB body cap, 8s timeout. Best-effort
  extra DNS-resolution check layered on where the edge runtime supports it — full
  DNS-rebinding closure isn't guaranteed, documented as a caveat in the code.
- Content sent to the LLM: HTML stripped to visible text + `<title>`/meta
  description only, truncated to ~6000 chars — not raw HTML.
- Extracted fields: `name`, `price`, `currency`, `billingCycle` (restricted to the
  app's actual `BillingCycle` cases — weekly/monthly/yearly, no "quarterly").
- Pro-gated, same as Screenshot Import (in practice free either way — `ai-proxy`
  already requires an active entitlement for every mode, url-lookup included).
- On any failure (fetch blocked, non-2xx, unparseable JSON), the client silently
  falls back to Phase 1's no-AI URL route rather than showing an error.
- Shares the existing per-user/global daily request cap with screenshot import —
  no new `app_config` key, no migration.

**Built:**
- `supabase/functions/_shared/pageFetch.ts` (new) — SSRF-guarded server-side fetch
  + HTML-to-text extraction, reusable by future proxy routes.
- `supabase/functions/ai-proxy/index.ts` — new optional `url` field on the request
  body; when present, fetches+extracts the page (step 4c, after the existing
  entitlement/cap checks) and builds the text prompt from it before entering the
  existing provider cascade loop unchanged.
- `Expired/Services/URLLookupAnalyzer.swift` (new) — client call + per-provider
  response parsing (duplicates, not shares, `ScreenshotImportAnalyzer`'s
  `openAIContent`/`claudeContent`/`geminiContent` — small working duplication over
  touching a proven, heavily-tested file, same call made for R2 Phase 1's iTunes
  search).
- `AddEditPrefill` gained `cost`/`currency`/`billingCycle` fields; `applyPrefill()`
  in `AddEditSubscriptionView` applies them when present.
- `AddItemHubView` gained a "Read Page with AI" row alongside the existing no-AI
  "Use…" row, Pro-gated via a new `onRequirePaywall` closure (mirrors how the
  Screenshot route already reaches `HomeView`'s paywall).

**Acceptance criteria:**
1. A real subscription page with a visible price → name + price + currency +
   billing cycle all prefilled correctly.
2. A page the model can't parse (JS-rendered pricing, no visible price) → falls
   back to Phase 1's favicon + host-guessed name, no error shown to the user.
3. A non-Pro user tapping "Read Page with AI" sees the paywall, not a network call.
4. A URL pointing at a private/internal address (e.g. `http://169.254.169.254/`,
   `https://localhost/`) is rejected server-side before any fetch — verify via the
   422 response, not just client behavior.

## v2

*(empty — nothing gated on an accounts system yet)*
