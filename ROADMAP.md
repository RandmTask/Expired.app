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

### R4. Onboarding service picker ("what do you subscribe to?") 🔴 — no schema change

Netflix-style multi-select logo grid during onboarding, so a first-run user leaves with a
populated app instead of an empty one. Two new onboarding pages: a **picker grid** (tap to
toggle, ~32 tiles) and a **quick setup** batch screen (cost + renewal date inline, one
compact row per selection). Replaces the cold-start "here's an empty list, go add
something" moment that currently follows onboarding.

**Decisions locked (2026-07-27):**

- **Free-tier cap is waived for onboarding-seeded items.** `HomeView.freeItemLimit = 5`
  ([`HomeView.swift:17`](Expired/UI/HomeView.swift), enforced in `openAddSheet()` at
  `:1411`) stays as-is for the normal add path, but items created by R4's batch commit
  bypass it. Rationale: the cap exists to convert, and converting 90 seconds into first
  launch — before the app has demonstrated anything — is the worst possible moment to ask.
  A free user who picks 8 keeps 8; adding a 9th via the normal path hits the paywall.
  **Consequence accepted:** the free tier is effectively "5, or up to ~32 via onboarding."
  Grid selection is capped at 10 to bound this.
- **`nextRenewalDate` stays non-optional** — no schema change. Quick Setup asks for
  **day-of-month** ("renews on the 14th") and derives the next future occurrence, rather
  than making the field optional. When billing cycle is `.yearly`, a month picker appears
  alongside the day. Skipping the date entirely falls back to `today + 1 cycle`.
- **No price prefills.** Prices are regional and plan-dependent; a confidently-wrong price
  is worse than an empty field and rots silently. Empty field, currency symbol shown,
  numeric keyboard focused. `cost: Double?` is already optional, so unknown-cost is
  representable — unknown-date is not, hence the point above.
- **Icons: bundle the global core, fetch the region packs.** Only ~6 of 32 tiles are
  region-specific; the rest (Netflix, Spotify, Disney+, Prime, Apple TV+, ChatGPT, Adobe,
  Dropbox, Audible…) are global, as are all 6 non-app tiles. Bundle ~26 core icons as
  assets (~650 KB at 360 px PNG) so the grid is instant and offline-proof; region-pack
  icons resolve at runtime through the existing `itunes.apple.com/lookup` path. Worst case
  offline is 5 placeholder tiles, not 32. Trademark note: this is nominative use for
  identification, same as the App Store search already does at runtime — accepted
  deliberately, not by default.
- **Region packs: AU, UK, US at launch.** Everywhere else gets the global core, which is
  genuinely usable (a Brazilian user sees Netflix/Spotify/Disney+/Prime and misses
  Globoplay, which the "Add your own" tile covers). Adding a pack later is a JSON edit,
  no code change.
- **Region filters the grid, never the catalog.** Other regions' entries stay in
  `AppCatalog.json` and remain reachable via `AppCatalog.search` / "Add your own" — an
  Australian living in London still needs Stan findable.
- **Placed after the reminders page, before the Pro page.** The user has just built a real
  list of their own services and just set their reminder offset; "all 8 of these are now
  armed, keep them all with Pro" is far more concrete than an abstract feature list.
  Placing it right after `welcomePage` was rejected — the user doesn't yet know what the
  app does, so the grid has no context.
- **Selecting a service auto-creates its reminder** using the default offset configured on
  the preceding reminders page. This is the payoff of the ordering above.
- **Empty state gets a non-persisted sample card, not a seeded row.** See "Empty state"
  below — this is a deliberate carve-out from the demo-seeding ban, documented in
  [`_shared/cloudkit-swiftdata.md`](../_shared/cloudkit-swiftdata.md).
- **Non-app tiles create document-type items** (`itemTypeRaw`), not subscriptions, so
  Passport / Insurance / Rego land in the right Home section from the start.
- **No search field on the grid.** The grid's job is *recall* ("oh right, I pay for
  Audible"), not lookup — a search field turns it into `AddItemHubView`, which already
  exists. The "Add your own" tile at the end covers the miss case.

**Catalog changes — `Resources/AppCatalog.json` (20 → 32 + 6 non-app):**

Add an optional `"regions": ["AU"]` field; **absent means global**. Existing 20 entries all
stay global. Also add an optional `"onboarding": true` flag marking which entries appear in
the picker grid (the catalog is also used by search, which should keep showing everything).

| Add (12) | Category | Regions |
|---|---|---|
| Audible | Streaming | global |
| Apple TV+ | Streaming | global |
| Paramount+ | Streaming | global |
| Amazon Prime *(distinct from Prime Video)* | Personal & Lifestyle | global |
| ChatGPT Plus | Work & Productivity | global |
| Canva | Work & Productivity | global |
| Strava | Health & Fitness | global |
| PlayStation Plus | Personal & Lifestyle | global |
| Xbox Game Pass | Personal & Lifestyle | global |
| Stan | Streaming | `["AU"]` |
| Binge | Streaming | `["AU"]` |
| Kayo Sports | Streaming | `["AU"]` |

UK pack (add alongside, same shape): NOW, Sky, BritBox, DAZN — `["GB"]`.

**CA and NZ packs added 2026-07-27** (region coverage widened from AU/UK/US at Deon's
discretion — natural fits given the AU/NZ/UK/CA Commonwealth-streaming overlap):

| Add | Category | Regions |
|---|---|---|
| Crave | Streaming | `["CA"]` |
| CBC Gem | Streaming | `["CA"]` |
| TSN+ | Streaming | `["CA"]` |
| Neon | Streaming | `["NZ"]` |
| ThreeNow | Streaming | `["NZ"]` |
| Sky Sport Now | Streaming | `["NZ"]` |

Five region packs total at launch: AU, GB, CA, NZ, and US (US entries are simply the
global-core tiles — the catalog has no US-only additions, since the global core already
skews US streaming). Same "region filters the grid, never the catalog" rule applies to
all five.

**Non-app tiles (6)** — no `appStoreId`, no icon fetch, an SF Symbol instead. These carry
`"itemType": "document"` where noted so the batch commit routes them correctly:

`Gym` (figure.run) · `Insurance` (shield.lefthalf.filled, document) · `Rent / Mortgage`
(house.fill) · `Car registration` (car.fill, document) · `Passport`
(person.text.rectangle.fill, document) · `Utilities` (bolt.fill)

**Files:**

- `Expired/Services/AppCatalog.swift` — add `regions`/`onboarding`/`itemType`/`symbolName`
  to `Entry`; add `static func onboardingTiles(region:) -> [OnboardingTile]` returning
  global + region-matched entries, region-matched sorted first within each category. Lift
  the `regionCode` computation out of [`AddItemHubView.swift:38`](Expired/UI/AddItemHubView.swift)
  into `AppCatalog` so both read one source. Do **not** change `search(_:limit:)` — it must
  keep returning every region's entries.
- `Expired/UI/Onboarding/ServicePickerPage.swift` (new) — the grid.
- `Expired/UI/Onboarding/QuickSetupPage.swift` (new) — the batch screen + commit.
- `Expired/UI/Onboarding/OnboardingView.swift` — insert the two pages as tags 4 and 5 in
  the existing `TabView` ([`:80`](Expired/UI/Onboarding/OnboardingView.swift)), pushing
  `proPage` to tag 6; both new pages need the Skip affordance the existing pages have.
- `Expired/UI/HomeView.swift` — `EmptyStateView` gains the sample card + "Add your
  services" entry point (see below).
- `Assets.xcassets/OnboardingIcons/` — ~26 bundled core icons. See "Icon sourcing
  pipeline" below — **do not** hand-source these one at a time.

**Icon sourcing pipeline — cleanup, then generate, don't hand-source:**

*Cleanup first (required — this is real committed cruft, not hypothetical):*
`Expired/Assets.xcassets/App​Catalog​Icons​/` is a **dead, already-committed** asset
catalog folder from an earlier abandoned attempt — 4 imagesets keyed by app-store ID
(Netflix, YouTube, Spotify, Apple Music) plus a stray `YouTube Music` entry that matches
no catalog entry, **and every path segment has `U+200B` zero-width-space characters
baked into the name** (confirmed via `git ls-tree`, visible as `\342\200\213` in the raw
path bytes — this is why it's easy to miss in a normal `ls`). Nothing in Swift
references it (`grep -rn "AppCatalogIcons\|UIImage(named" Expired` finds no hits). There's
also a second, equally-dead duplicate nested inside
`Expired/Assets.xcassets/AppIcon.appiconset/App​Catalog​Icons​/` — an old
drag-into-the-wrong-target mistake. Remove both with `git rm -r` (they're tracked) before
adding the new folder — don't let three similarly-named asset folders coexist.

*Generation — `bin/fetch-onboarding-icons.py` (already written, tested, executable):*
Reads `Resources/AppCatalog.json`, fetches `artworkUrl512` from the iTunes Lookup API for
every entry with an `appStoreId` that's either global (no `regions` field) or matches a
`--region` flag, resizes to 180×180 with macOS's built-in `sips` (no PyPI dependencies —
`curl`/`sips`/stdlib only), and writes each into
`Assets.xcassets/OnboardingIcons/<appStoreId>.imageset/` as a **Single Scale** imageset
(one `icon.png`, no separate 1x/2x/3x files — SwiftUI downsamples for smaller contexts and
never upsamples, so a single 180px/@3x-resolution source stays sharp everywhere a 60pt
tile is used). Idempotent — re-running skips imagesets that already have `icon.png`, so
it's safe to run again after adding a new catalog entry rather than re-fetching all 26.

```bash
# Core global icons (run once the 32-entry catalog lands):
python3 bin/fetch-onboarding-icons.py

# Add a region pack's icons on top:
python3 bin/fetch-onboarding-icons.py --region AU --region GB --region CA --region NZ

# Re-fetch everything (e.g. after a catalog entry's appStoreId changes):
python3 bin/fetch-onboarding-icons.py --force
```

Measured, not estimated: a real Netflix fetch through this exact script produced an
8.5 KB PNG at the correct 180×180 dimensions (verified with `sips -g pixelWidth -g
pixelHeight` during blueprint-writing). 26 icons × ~8–15 KB ≈ **200–300 KB total** —
tighter than the ~650 KB figure floated earlier in this doc's decision log; that estimate
assumed a heavier per-scale asset and can be treated as a safe upper bound, not the actual
number.

Failures (an app removed from the Store, a wrong ID) print a "fetch these manually or fix
the ID" list and the script exits non-zero — treat that as a real failure to resolve, not
noise to ignore; don't ship a tile with a missing icon.

**Flow:**

```
splash → welcome → subs&docs → screenshot import → reminders
                                                       ↓
                                            ★ PICK YOUR SERVICES (grid)
                                                       ↓
                                            ★ QUICK SETUP (batch rows)
                                                       ↓
                                                   pro page → paywall
```

**Page A — grid.** 3 columns on iPhone, category-grouped with sticky pill headers matching
`GlassSectionView`. Tile = 60 pt icon + name, `.glassEffect(in: .rect(cornerRadius: 20))`
per the design system; selected = tinted border + checkmark badge. Sticky footer CTA reads
`Continue with 4 selected`, or `Skip for now` at zero. Selection capped at 10 (tile 11 gets
a `.warning` haptic + inline note, not a paywall). Final tile is **"Add your own"** →
dismisses onboarding into `AddItemHubView`.

**Page B — quick setup.** One compact row per selection:
`[icon] Netflix · [$ cost] · [monthly ▾] · [renews on 14th ▾]`. Inline editing only — **never
push N sequential `AddEditSubscriptionView` sheets**, which is unbearable at 8 items. Row
order matches selection order. A per-row `×` removes it from the batch. Commit button reads
`Add 4 items`.

**Commit:** one `modelContext` insert loop + a single `save()`, then
`NotificationManager.shared.refreshAll(context:)` once at the end — not per item. Dedupe
against existing items on `AppCatalog.canonicalName` before inserting.

**Empty state (`EmptyStateView`, used at [`HomeView.swift:522`](Expired/UI/HomeView.swift)
and `:577`):**

Render a **dimmed sample Netflix card with a `SAMPLE` chip** — a `SubscriptionItem`
constructed in memory and **never inserted into `modelContext`**. `PreviewData.swift`
already builds exactly these throwaway items for its `isStoredInMemoryOnly` container;
reuse that construction rather than writing a parallel one. Tapping it opens the add flow
**prefilled with Netflix** (a functional shortcut, not decoration). It disappears the moment
`allItems` is non-empty — no delete, no sync, no residue. Below it, an **"Add your
services"** button reopens the R4 picker grid, giving the grid a permanent home instead of
being a one-shot onboarding page.

**Replay (per [`_shared/onboarding-conventions.md`](../_shared/onboarding-conventions.md)):**
both new pages *do* appear on replay — services already tracked render pre-checked and
disabled rather than being skipped. Dedupe on `AppCatalog.canonicalName`, not raw string
equality. Note that `OnboardingGate.checkOnboardingState()`
([`:39`](Expired/UI/Onboarding/OnboardingView.swift)) marks onboarding complete whenever
item count > 0 — that's the *launch gate* and is correct; replay must bypass it via the
transient trigger the conventions doc describes, not by touching `hasCompletedOnboarding`.

**Acceptance criteria:**
1. Fresh install, free user, pick 8 services → all 8 exist on Home, no paywall shown during
   onboarding. Adding a 9th from Home *does* show the paywall.
2. Airplane mode, fresh install → all core tiles render their bundled icons; only
   region-pack tiles show placeholders. Grid is fully usable.
3. Region set to AU → Stan/Binge/Kayo appear at the top of Streaming. Region set to US →
   they're absent from the grid but still findable by typing "Stan" in `AddItemHubView`.
4. Pick Netflix + set "renews on the 14th" on the 20th of the month → `nextRenewalDate` is
   the 14th of *next* month. Yearly cycle exposes a month picker; skipping the date gives
   `today + 1 cycle`.
5. Skip both pages → Home shows the sample Netflix card with a `SAMPLE` chip; the item count
   is 0 (verify in Debug → Diagnostics, not just visually) and nothing syncs to CloudKit.
6. Passport tile → creates a *document*-type item in the documents section, not a
   subscription.
7. Replay from Settings with Netflix already tracked → Netflix tile is pre-checked and
   disabled; completing the flow creates no duplicate.
8. Reminder offset set to 5 days on the reminders page → all 8 seeded items have a 5-day
   rule, verified in the item editor.

---

**Build order: R1 → R2 → R3 → R4** (R1–R3 locked 2026-07-05 — reminders are the app's core
job; R4 appended 2026-07-27, it depends on R1's reminder defaults being settled).

## Post-v1.0

### R2. Import flow — Phase 2: AI website lookup 🟠 — no schema change

> **Status (2026-07-17):** Deployed to production (via Codex, offloaded per Deon's
> request) and the SSRF guard verified live: a cloud-metadata IP and an explicit
> HTTPS IP-literal target both correctly returned `422` (`scheme_not_allowed` /
> `ip_literal_not_allowed`), while `https://example.com` cleared the guard normally
> with `200`. **Outstanding:** no live test against a real subscription page's
> full extraction (name/price/currency/cycle) yet, and no in-app walkthrough of the
> non-Pro paywall path — see `TEST.md`.

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
