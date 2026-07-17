# Expired — Outstanding Manual Test / Action Items

Things Claude can't finish alone: needs Deon's connected iPhone, a browser dashboard
decision, or an interactive Simulator session he hasn't greenlit yet. Check items off
as they're done; delete a whole entry once verified (its detail lives in
`ROADMAP.md`/`IMPLEMENTATION_LOG.md` already — this file is just the punch list).

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
