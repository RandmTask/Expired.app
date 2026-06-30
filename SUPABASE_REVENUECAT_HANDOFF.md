# Supabase + RevenueCat Integration — Handoff Guide

Working doc for the Expired monetization + AI-proxy integration. Pick up here in a
fresh chat. Approved plan: `~/.claude/plans/ok-lets-integrate-this-elegant-falcon.md`.

---

## Why

Expired ships an AI screenshot-import feature (`Services/ScreenshotImportAnalyzer.swift`)
that today calls providers **directly with a raw API key on-device** — release-blocking.
Supabase is the proxy that holds the key server-side (rate-limited, spend-capped,
kill-switchable). RevenueCat is the paywall. AI import is Premium-gated, enforced
server-side so a hacked client can't bypass it.

**No CloudKit/SwiftData schema change.** App data stays in CloudKit; Supabase holds
only identity + usage metering + entitlement mirror.

---

## ✅ DONE

### Backend (`Expired/supabase/`) — deployed
- `migrations/0001_init.sql` — `usage`, `entitlements`, `app_config` tables + RLS
  (`auth.uid() = user_id`) + `increment_usage()` rpc. **Pushed to remote.**
- `functions/ai-proxy/` — JWT-validated, premium-gated, rate-limited thin forwarder.
  Client sends `{provider, model, body}`; proxy injects server key, forwards, passes
  response through. **Deployed.**
- `functions/models/` — proxies each provider's `/models` list (no key on device). **Deployed.**
- `functions/revenuecat-webhook/` — mirrors entitlement state into `entitlements`
  (verify_jwt=false, shared-secret auth). **Deployed.**
- Secrets set: `DEEPSEEK_API_KEY`, `GEMINI_API_KEY`, `REVENUECAT_WEBHOOK_SECRET`.
  (No OpenAI/Anthropic key yet — those providers return 502 until added; DeepSeek +
  Gemini are the active providers.)
- Caps live in `app_config`: `ai_enabled` (kill-switch), `daily_request_cap` (50).
- Setup reference: `Expired/supabase/SETUP.md`.

### Supabase dashboard
- Anonymous sign-ins **enabled**.

### RevenueCat dashboard
- Entitlement **`Expired Pro`** (identifier literally `"Expired Pro"`).
- Products attached: Monthly Pro (`monthly`), Yearly Pro (`yearly`), Lifetime Pro (`lifetime`).
- Offering **`default`** packages all three. Paywall: **"Add Paywall"** on the default
  offering still pending in dashboard (build a paywall template before testing the UI).

### App Store Connect
- Subscription group "Expired Pro" with products. **Note the real product IDs are
  `…pro.monthly2` / `…pro.yearly` / `…pro.lifetime`** (monthly got a `2` suffix because
  App Store Connect permanently reserves deleted IDs). RevenueCat maps these via its own
  product objects, so the app code never references these strings.

### Client foundation (written, builds once SPM packages added)
- `Services/BackendConfig.swift` — Supabase URL + publishable key, RevenueCat key,
  `proEntitlementID = "Expired Pro"`, function names. **All values real, already wired.**
- `Services/SupabaseService.swift` — `@MainActor` singleton; `ensureSession()`
  (anonymous), `currentUserID`, `authorizedFunctionRequest(_:)`, stubbed `linkWithApple`.
- `Services/PurchaseManager.swift` — `@MainActor @Observable`; `configure(appUserID:)`,
  `isPremium`, `offerings`, `restore()`, `PurchasesDelegate`.

### Xcode (manual, done by Deon)
- SPM packages added: `purchases-ios-spm` (RevenueCat + RevenueCatUI), `supabase-swift`
  (Supabase umbrella library).

---

## Config values (public-by-design, already in BackendConfig.swift)
- Supabase URL: `https://ehibtlaoshmqpbnexehy.supabase.co`
- Supabase publishable key: `sb_publishable_ovK9myqBXql1v1B_a52gJQ_xkLLO-GN`
- RevenueCat public SDK key: `test_aTQLDKzrPfEdvwGfOFVEChZPtAI` (sandbox)
- Entitlement identifier: `Expired Pro`

---

## Finalized freemium split

| Free | Pro (`Expired Pro`) |
|---|---|
| 5 active subscriptions/documents | Unlimited |
| Manual add/edit | Screenshot / AI-assisted import |
| 1 basic renewal reminder per item | Advanced + Critical reminders, multiple rules per item |
| Built-in categories | Custom categories |
| Monthly/yearly total | Insights, archive/history, export |
| iCloud sync (automatic — stays free) | iCloud **Backup** (manual file export via `BackupService`) |
| | Currency conversion |
| 7-day free trial on Pro (configure in RevenueCat) |

**Free item cap = 5** (was 10 in the original plan; reduced here).
**iCloud automatic sync stays FREE** — only manual export/backup is Pro. (Auto CloudKit
sync can't be gated without an architecture change, and we don't want to.)

---

## ✅ SWIFT WORK DONE (2026-06-30, builds green iOS + macOS)

- **Build unblockers:** removed the stray `RevenueCat_CustomEntitlementComputation` SPM product
  from the target (it duplicates every `RC*` symbol → 100 duplicate-symbol linker errors).
  Fixed two Swift-6 isolation errors (`BackupService` off-main write chain → `nonisolated`;
  `AddEditSubscriptionView` point-free `NotificationRuleDraft.init(rule:)` → explicit closure).
- **Task #5 done** — `ExpiredApp` launches a non-blocking `.task`: `ensureSession()` →
  `PurchaseManager.configure(appUserID:)`; `PurchaseManager.shared` injected into the environment.
- **Task #4 done** — `ScreenshotImportAnalyzer` + `ScreenshotAIModelService` route through the
  proxy (`proxyForData` envelope `{provider, model, body}`; `listModels` → `models` fn). Added
  `ScreenshotAIProvider.proxyID`. On-device key reads removed from the analyzer.
- **Task #6 done** — `UI/Paywall.swift` (PaywallView sheet + lock badge + Customer Center w/
  macOS fallback). Gates: AI import + 5-item cap (active-only) in HomeView; ViewMode + CostPeriod
  lock badges; custom categories; manual export. "Expired Pro" section (upgrade / manage / restore)
  added to both Settings bodies. Raw-key entry UI + RED warning removed.

### ⚠️ Deferred / still open
- **Currency conversion gating** — NOT implemented (ambiguous: gate changing display currency, or
  the per-item conversion in totals?). Decide the exact behaviour before wiring.
- `ScreenshotAISettings.apiKey` (Keychain-backed) is now unused by the analyzer but kept so the
  one-time Keychain migration + struct stay intact. Remove when convenient.
- macOS Customer Center uses a lightweight Restore + guidance sheet (RevenueCat's `CustomerCenterView`
  is iOS-only). Verify it reads acceptably.

## ⏳ ORIGINAL TASK NOTES (for reference)

### Task #5 — `ExpiredApp.swift` launch wiring
On launch: `try await SupabaseService.shared.ensureSession()` → then
`PurchaseManager.shared.configure(appUserID: SupabaseService.shared.currentUserID)`.
Non-blocking for UI. Inject `PurchaseManager.shared` into the SwiftUI environment so
gates can read `isPremium`. Also keep the existing `migrateAPIKeysToKeychainIfNeeded()`
call — but the on-device key path is being removed (see #4).

### Task #4 — Reroute `ScreenshotImportAnalyzer.swift` through the proxy
- Add a stable `proxyID` to `ScreenshotAIProvider` (`openai/claude/gemini/deepseek`).
- Replace the per-provider direct calls (`chatCompletionsTextResponse`,
  `openAIVisionResponse`, `claudeVisionResponse`, `geminiVisionResponse`) so they build
  the **same body dict** but POST it to `ai-proxy` via
  `SupabaseService.shared.authorizedFunctionRequest("ai-proxy")` with envelope
  `{provider, model, body}`. **Keep all response parsing unchanged** (`openAIContent`,
  the claude/gemini content extraction) — the proxy passes the provider response
  straight through, so existing parsers still work.
- Point `ScreenshotAIModelService.listModels` at the `models` route.
- Remove on-device key reads (`settings.apiKey`, `KeychainStore` for API keys). Apple
  Intelligence on-device path stays unchanged and free.

### Task #6 — Paywall + gates (uses RevenueCatUI, NOT a custom paywall)
Present RevenueCat's hosted paywall via
`.presentPaywallIfNeeded(requiredEntitlementIdentifier: BackendConfig.proEntitlementID)`
from RevenueCatUI. Add Customer Center to Settings. Gates:
1. **AI import** — `UI/HomeView.swift` analyze entry → require `isPremium`.
2. **5-item cap** — `UI/HomeView.swift:~208` `+` button: if `allItems.count >= 5 && !isPremium` → paywall.
3. **Advanced views/insights** — `ContentView.swift` `ViewMode` (gate
   heatmap/swimLane/spendSpike/strip; keep timeline+calendar) + `CostPeriod` (gate
   annual/ytd/lifetime; keep monthly). Also custom categories + currency conversion.
4. **Export/backup** — gate manual export (`BackupService`) in `ContentView.swift`.
Remove the raw-key entry UI + RED warning from `ContentView.swift` (~2239–2714).

---

## Testing notes
- AI is now Premium-gated **server-side**. To test the AI path before a sandbox purchase:
  Supabase → SQL Editor →
  `update public.entitlements set premium_active = true where user_id = '<your-uuid>';`
  (find your UUID via the Customers tab in RevenueCat, or log `SupabaseService.currentUserID`).
- Sandbox purchase: StoreKit sandbox tester → buy → `isPremium` flips → all 4 gates unlock.
- Kill-switch test: `update public.app_config set value='false' where key='ai_enabled';` → AI calls 503.
- Build iOS + macOS after each task; parity-check new Settings rows (RevenueCat paywall
  is iOS-first — verify macOS rendering or gate behind `#if os(iOS)` where needed).

---

## Open items / watch-outs
- **RevenueCat paywall on macOS**: RevenueCatUI paywall support is strongest on iOS.
  Confirm macOS behavior; may need a fallback present for macOS.
- **Provider keys**: only DeepSeek + Gemini configured server-side. The provider picker
  should reflect available providers (OpenAI/Claude will 502 until keys added).
- **7-day trial**: configure as an introductory offer in App Store Connect + RevenueCat.
- **Before public release**: swap RevenueCat `test_` key for production key in BackendConfig.
