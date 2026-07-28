# Expired — Outstanding Manual Test / Action Items

Things Claude can't finish alone: needs Deon's connected iPhone, a browser dashboard
decision, or an interactive Simulator session he hasn't greenlit yet. Check items off
as they're done; delete a whole entry once verified (its detail lives in
`ROADMAP.md`/`IMPLEMENTATION_LOG.md` already — this file is just the punch list).

## R4 — Onboarding service picker (added 2026-07-27, revised 2026-07-28 round 2)

Both platforms build clean. This round: catalog expanded 32 → 57 tiles (50 global +
7 regional) curated by *what people actually pay for*; 56/57 now have real bundled
App Store icons; icons enlarged (60 → 68pt); notification permission no longer fires
early; Quick Setup row relaid out with a styled cost field; menu label truncation
fixed; reminders swipe rewritten (one row at a time, no opposite-side flip); a
debug-only grid-style switcher added.

**Notification permission is one-shot per install** — items 1/4/5 below need a
genuinely fresh install to be meaningful. Deleting the app on a second device won't
work: CloudKit restores the data (and `hasCompletedOnboarding` is local, so the
data-exists check silently marks onboarding complete). To truly retest: delete the
app *and* use Debug → Delete All Data first, or test on a device signed out of
iCloud.

- [ ] **1.** Fresh install → the "Expired would like to send you notifications"
      system prompt does **not** appear until the Reminders page, and appears there
      when you tap Enable Notifications. y/n
- [ ] **2.** Grid shows ~50 tiles, 4 across, bigger icons than before, all real app
      logos (no letter placeholders). y/n
- [ ] **3.** The new entries are there and look right: Peacock, YouTube Music, Claude
      Pro, Google Gemini, WHOOP, Calm, Oura, Peloton, Runna, 1Password, NordVPN,
      Todoist, Hinge, Bumble, LinkedIn Premium, Nintendo Switch Online, Discord
      Nitro, Twitch, NYTimes, WSJ, MasterClass, Substack. y/n
- [ ] **4.** Region AU → Stan/Binge/Kayo appear with real logos. Region GB →
      NOW/Sky/BritBox/DAZN appear with real logos. y/n
- [ ] **5.** Reminders page: the "How far ahead?" control shows four chips
      (1/3/5/7 days) with **no truncated text**, and the selected one is clearly
      highlighted. y/n
- [ ] **6.** Pick 2–3 services → Quick Setup → commit → set 5 days on the Reminders
      page → each created item's editor shows a single "5 days before" rule. y/n
- [ ] **7.** Quick Setup row: cost field is a proper filled box on the left; billing
      cycle and renewal day sit **together on the right**. y/n
- [ ] **8.** Change billing cycle to "One-time" → the label does **not** flash
      clipped/cut-off before settling, and the renewal-day chip disappears. y/n
- [ ] **9.** Item editor reminders: swipe one row open, then swipe a *different* row
      → the first closes automatically; only ever one row open. y/n
- [ ] **10.** Swipe a row open from the right, then swipe back left → it just closes;
      it does **not** flip open the other side's buttons. y/n
- [ ] **11.** At rest, no bell/clock/trash icon ghosts through behind the reminder
      row text. y/n
- [ ] **12.** Settings → reveal Debug (4s long-press version footer / ⌥-click) →
      Debug section stays visible across navigation until "Hide Debug". y/n
- [ ] **13.** With Debug revealed, open the picker grid → a small grid icon appears
      top-left → it offers 8 layout styles (squircle, squircle large, icon-only 5-up,
      icon-only large, circular, circular large, honeycomb, compact). Try each and
      tell me which you want as the shipped default. **← this one needs an answer,
      not just y/n**
- [ ] **14.** Free user: pick 8 → all 8 land on Home, no paywall during onboarding;
      adding a 9th from Home *does* paywall. y/n
- [ ] Screenshot anything that still looks off.

**Deliberate omissions / open questions:**
- **Midjourney** is not included — it has no iOS app, and midjourney.com hard-blocks
  icon scraping behind Cloudflare (403 on every path, with and without a browser
  UA). Say the word if you want it as a letter-placeholder tile anyway.
- **GitHub Copilot** uses the GitHub app's icon (there's no separate Copilot app).
- **iCloud+** is the one tile without a fetched icon — there's no App Store listing
  for it; it falls back to the local `iCloud icon.png` already in the bundle.
- **Pandora / WoW** skipped: Pandora is US-only and declining, WoW has no iOS app.

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
