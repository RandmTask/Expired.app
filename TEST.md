# Expired — Outstanding Manual Test / Action Items

Things Claude can't finish alone: needs Deon's connected iPhone, a browser dashboard
decision, or an interactive Simulator session he hasn't greenlit yet. Check items off
as they're done; delete a whole entry once verified (its detail lives in
`ROADMAP.md`/`IMPLEMENTATION_LOG.md` already — this file is just the punch list).

## R4 — Onboarding service picker (added 2026-07-27)

Both platforms build clean (`xcodebuild` generic iOS Simulator + generic macOS). Needs a
real device/Simulator pass — grid layout, tile tap targets, and the quick-setup menus
haven't been visually verified.

- [ ] **1.** Fresh install (delete app first), free user, pick 8 services on the grid →
      all 8 exist on Home after Quick Setup, no paywall shown during onboarding. y/n
- [ ] **2.** From Home, add a 9th item the normal way → paywall *does* show (free-tier
      cap still applies outside onboarding). y/n
- [ ] **3.** Airplane mode, fresh install → grid is usable; tiles with a bundled icon
      show it, others show a placeholder/initial — no blank tiles, no crash. y/n
- [ ] **4.** Region set to AU (Settings → App Store Region) → Stan/Binge/Kayo appear in
      the Streaming group. Region set to US → they're absent from the grid but still
      findable by typing "Stan" in the Add Item search. y/n
- [ ] **5.** Pick Netflix → Quick Setup → set billing to Monthly, day to 14, and today is
      the 20th → after commit, edit the item → renewal date is the 14th of *next*
      month. y/n
- [ ] **6.** Same row, switch billing to Yearly → a month picker appears next to the day
      picker. y/n
- [ ] **7.** Skip both pages (grid "Skip for now") → Home shows the dimmed sample Netflix
      card with a SAMPLE chip; Debug → Diagnostics shows item count 0. y/n
- [ ] **8.** Tap the sample Netflix card → add flow opens prefilled with "Netflix". y/n
- [ ] **9.** Tap "Add your services" below the sample card → the picker grid reopens as
      its own sheet (not the full onboarding pager). y/n
- [ ] **10.** Passport tile → after Quick Setup, the created item appears in the
      Documents section, not as a subscription. y/n
- [ ] **11.** Replay Onboarding (Settings → 4s long-press on version footer → Replay),
      with Netflix already tracked → the Netflix tile shows pre-checked and disabled;
      completing the flow does not create a duplicate. y/n
- [ ] **12.** On the reminders onboarding page, set "Remind me" to 5 days before, then
      pick 2–3 services → each created item's editor shows a single "5 days before"
      reminder rule. y/n
- [ ] Screenshot the grid and the Quick Setup rows if spacing/alignment looks off on
      either iOS or macOS (macOS reaches this only via "Add your services" from Home —
      onboarding itself is iOS-only, unchanged from before R4).

**Known gap (not blocking, flagged for a future pass):** most of the 16 newly-added
catalog entries (Audible, Apple TV+, Paramount+, ChatGPT Plus, Canva, Strava, PlayStation
Plus, Xbox Game Pass, Stan, Binge, Kayo Sports, NOW, Sky, BritBox, DAZN, Amazon Prime)
don't have a bundled icon yet — they'll show an initial-letter placeholder until real
logo assets are added to Assets.xcassets keyed by `appStoreId` (same convention as the
existing Netflix/YouTube/Spotify/Apple Music sets `AppCatalog.swift` now also checks).
App Store IDs for the new entries in `Resources/AppCatalog.json` are best-effort and
worth spot-checking — a wrong ID only degrades to a placeholder icon/failed lookup, never
a crash, but should be verified before relying on the "Read Page with AI"/App Store
search paths for these specific services.

## Launch screen / splash (added 2026-07-27)

**Delete the app from the device first** — iOS caches the rendered launch screen, and a
plain white/black launch after an update is almost always this, not a broken asset.

- [ ] **1.** Cold launch → the very first frame is a dark plate (no white flash). y/n
- [ ] **2.** There is **no visible seam or jump** between the system launch screen and the
      animated one — it reads as one continuous screen. y/n
- [ ] **3.** Icon glyph springs in, then "expired." fades up beneath it in the
      teal→violet→magenta gradient, then the whole thing fades into the app. y/n
- [ ] **4.** Total splash time feels right (~1.5s) — not sluggish. y/n
      *(if not: `SplashTiming` in `UI/SplashView.swift`)*
- [ ] **5.** Settings → Appearance → **Light**, then cold launch → the status bar clock and
      icons are **legible** (light-coloured) over the dark plate, not black-on-black. y/n
      *This is the one I couldn't verify statically — the Info.plist style covers the
      system launch screen, but the ~1.5s splash is drawn by the app's own view controller
      and may still take Light appearance. If it's black-on-black, say so and I'll fix it.*
- [ ] **6.** Settings → Accessibility → Motion → **Reduce Motion ON**, cold launch → logo
      and wordmark cross-fade with no scaling or sliding. y/n
- [ ] **7.** **First-launch only** (delete app → reinstall): onboarding appears *after* the
      splash has finished, not sliding up over the middle of it. y/n
- [ ] **8.** Tapping during the splash doesn't get swallowed / cause a mis-tap. y/n
- [ ] Screenshot the splash mid-animation if the logo size or wordmark spacing looks off.

## Device / Simulator

- [ ] **Reconnect iPhone and build to device** — showed offline as of 2026-07-13.
      `CLAUDE.md` default is build-to-device; every recent batch has only been
      verified on iOS Simulator + macOS.
- [ ] **R1 (reminder orchestration) — AC5 two-device sync** — edit rules on device A,
      confirm device B reschedules correctly after CloudKit sync. Needs a second
      device or the iPad.
- [ ] **R1 — interactive Simulator UI walkthrough** — never completed; computer-use
      access to the Simulator was declined in the session that built it.
- [ ] **R2 (Add Item hub) — interactive Simulator walkthrough of the 4 ACs**:
      1. `+` → Search → "Netflix" → tap result → confirm icon/name/category
         prefilled in ≤3 interactions.
      2. `+` → Screenshot → multi-subscription screenshot → deselect 2 in review →
         exactly 3 saved (regression check — hub shouldn't have broken this).
      3. `+` → Search → type a bare domain ("hulu.com") → tap the "Use…" row →
         confirm name/icon/category-guess prefilled and **no** `ai-proxy` network
         call fires (check console/Charles).
      4. `+` → Manual → reaches the current Add form in one tap.
- [ ] **R3 (renewal forecast) — visual/interactive verification** — Forecast UI
      (segmented control, chart, biggest-upcoming-hits list) in `InsightsView` builds
      clean but was never opened in a running app.

## Supabase (state-changing infra — needs Deon's go-ahead)

- [x] **Deploy the updated `ai-proxy` function** — deployed 2026-07-17 via Codex
      (offloaded per Deon's request). `url` mode ("Read Page with AI") is now live.
- [x] **SSRF guard verified server-side** (2026-07-17, via Codex):
      `http://169.254.169.254/` → `422 scheme_not_allowed`; an explicit HTTPS
      IP-literal target → `422 ip_literal_not_allowed`; `https://example.com` →
      `200`, cleared the guard normally. All three as expected.
- [ ] **R2 Phase 2 — live test against a real subscription page** now that it's deployed:
      (1) a page with a clear visible price → name/price/currency/cycle all
      prefilled; (2) a page the model can't parse (JS-rendered pricing) → silent
      fallback to Phase 1's favicon+name-only result, no error shown; (3) a non-Pro
      test account → "Read Page with AI" shows the paywall, zero `ai-proxy` calls.

## Xcode project (GUI-only, can't be done by Claude via CLI)

- [ ] **Create an XCTest target** — needed to house R3's AC5 unit tests in-tree.
      `ForecastEngine`'s protocol-based design makes adding the tests trivial once
      the target exists; algorithm was verified via a standalone script in the
      meantime (see `IMPLEMENTATION_LOG.md`, 2026-07-12).

## CloudKit

- [ ] **Dev → Prod schema redeploy before next TestFlight** — R1 added
      `NotificationRule.fireHour/fireMinute` and `SubscriptionItem.reminderHour/
      reminderMinute` (additive, CloudKit-safe). Must be redeployed in CloudKit
      Console before the next TestFlight build or those fields won't sync for
      testers on the old schema.

## Launch crash fix + debug menu relocation (2026-07-27 batch)

- [ ] **TestFlight: fresh install launches without crashing.** CONFIRMED root cause
      (reproduced live under the Xcode debugger running Release-on-device, not just
      inferred from a stripped `.ips`): RevenueCat's own SDK deliberately
      `fatalError`s (`Configuration.swift`'s `checkForSimulatedStoreAPIKeyInRelease`)
      whenever a Test Store (`test_…`) key runs in a Release build — TestFlight is
      always Release. There is no workaround; the only fix is the real key. Fixed by
      swapping `BackendConfig.revenueCatAPIKey` to the real "Expired (App Store)" SDK
      key (`appl_…`, already provisioned in RevenueCat since 2026-07-11, just never
      wired into the app). **Needs a real TestFlight build + reinstall to verify** —
      Debug/Release builds succeeding locally isn't proof, only that it compiles.
      The two earlier guesses this session (a `supabase-swift` force-unwrap bug, and
      a theoretical RevenueCatUI paywall-workflow crash) were both wrong for this
      specific incident — kept as real, harmless improvements (version bump,
      `PaywallGate`) but neither was the actual cause.
- [x] **TestFlight: onboarding → "Start Free Trial" doesn't crash either.** Confirmed
      2026-07-27 — the redesigned, published "Expired Pro Paywall" now shows (blue
      theme, 3 tiers including Lifetime), not RevenueCatUI's generic fallback.
- [ ] **iOS: Settings → 4-second long-press on the version footer opens Debug
      Menu.** No visible affordance beforehand. The old long-press on the
      "Analyzer" row in Screenshot Import no longer does anything.
- [ ] **macOS: Settings → ⌥-click the version footer opens Debug Menu**; a plain
      click copies `Expired 1.0 (n)` to the pasteboard.
- [ ] **Debug Menu → Diagnostics → Copy Diagnostic Report** produces a pasteable
      block with app version/build, device, RevenueCat key mode (should say
      "TEST STORE"), CloudKit summary, and Supabase user ID.
- [ ] **Debug Menu → "Delete All Data"** (renamed from "Reset Subscriptions") reads
      clearly now as "deletes everything," not "resets the Pro purchase." y/n
- [ ] **Debug Menu → "Reset Premium Status"** (renamed from "Reset for Testing")
      clears an active/Lifetime purchase for re-testing without touching subscription
      data. y/n
- [ ] **Settings → Privacy → "Share Subscription Usage" toggle** — add a known service
      (e.g. Netflix) with the toggle on → confirm no error/crash (silent success). Turn
      the toggle off, add a different known service → confirm nothing is sent (check
      the `service_popularity` table in Supabase doesn't grow). Both are silent either
      way, so this needs a Supabase dashboard check to actually confirm — not
      user-visible in the app.

## Launch gate (blocks TestFlight/App Store — see `ROADMAP.md` for full detail)

- [ ] Real App Store Connect app in RevenueCat (only synthetic Test Store exists today).
- [ ] 7-day free trial on the yearly plan (ASC Introductory Offer — blocked on the item above).
- [ ] Flip `allow_sandbox_entitlements` to `false` at/just before launch (one SQL statement).
- [ ] Critical Alerts entitlement — submitted 2026-06-30, awaiting Apple approval.
- [ ] Verify OpenAI spend limit is set (not checked yet — needs OpenAI platform login).
- [ ] Google Cloud (Gemini) budget alert — blocked on enabling 2SV on the Google account.
- [ ] Confirm `update-exchange-rates` cron is scheduled (`0 5 * * *` UTC) in the Supabase
      dashboard — without it, currency conversion silently falls back to `CurrencyInfo`'s
      hardcoded snapshot.
