# RevenueCat integration playbook

Reusable checklist for wiring an iOS app to RevenueCat with App Store Connect, a
RevenueCat paywall, and an optional Supabase entitlement mirror.

This file is both a template and a runbook. Record the actual dashboard labels,
URLs, identifiers, and unexpected UI differences for each project. Never record
secret API keys, webhook secrets, private keys, or customer data here.

## 0. Integration intake — answer these first

Complete this section before touching App Store Connect or RevenueCat. It is
intentionally written as a short interview so the same questions can be reused
for the next app.

### App identity

- App name: `TODO`
- Apple App Store app ID: `TODO`
- iOS bundle ID / base product ID: `TODO` (example: `com.swiftstudio.expired`)
- RevenueCat project: `TODO`
- Supabase project ref: `TODO` (if Supabase is used)
- Canonical entitlement identifier: `TODO` (suggestion: `Expired Pro` or
  `<AppName> Pro`; choose one spelling and use it everywhere)

### Suggested catalog decision

For a utility app with recurring value, a sensible starting point is:

1. Monthly Pro — `$1.99` — no trial
2. Yearly Pro — `$19.99` — 7-day free trial — **default/highlighted plan**
3. Lifetime Pro — `$49.99` — one-time purchase

These are suggestions, not defaults to apply silently. Confirm or replace the
prices, trial, and default plan before creating the catalog. Also confirm:

- Is lifetime a non-consumable one-time purchase?
- Should monthly or yearly have an introductory offer?
- Which plan should be highlighted in the paywall?
- Are family sharing, promotional offers, or regional availability needed?
- Is the first release using sandbox/Test Store, App Store sandbox, or both?
- Should Supabase mirror entitlements through a RevenueCat webhook?

### Product ID proposal

Ask for the project's base identifier first, then propose stable IDs rather than
inventing them during dashboard setup. For base ID `com.swiftstudio.expired`,
the suggested products are:

| Business plan | Suggested product ID |
| --- | --- |
| Monthly Pro | `com.swiftstudio.expired.pro.monthly` |
| Yearly Pro | `com.swiftstudio.expired.pro.yearly` |
| Lifetime Pro | `com.swiftstudio.expired.pro.lifetime` |

Apple product IDs cannot generally be recreated after deletion. If a typo has
already been used, record the actual replacement ID and carry it consistently
through ASC, RevenueCat, the app, tests, and this file.

### Current project answers

- App: Expired
- Bundle ID: `com.swiftstudio.Expired`
- Product IDs: monthly `com.swiftstudio.expired.pro.monthly2`, yearly
  `com.swiftstudio.expired.pro.yearly`, lifetime
  `com.swiftstudio.expired.pro.lifetime`
- Entitlement: `Expired Pro`
- Yearly is intended to be the default/highlighted plan with a 7-day trial.
- Lifetime is a non-consumable one-time purchase.
- Confirmed prices: monthly `$1.99`, yearly `$19.99`, lifetime `$49.99`.

## 1. Decide the contract first

For this project the intended catalog is:

| Business plan | Store product type | RevenueCat package | Suggested product ID |
| --- | --- | --- | --- |
| Monthly | Auto-renewable subscription | `$rc_monthly` | `com.swiftstudio.expired.pro.monthly2` |
| Yearly | Auto-renewable subscription | `$rc_annual` | `com.swiftstudio.expired.pro.yearly` |
| Lifetime | Non-consumable / one-time purchase | `$rc_lifetime` | `com.swiftstudio.expired.pro.lifetime` |

Choose the entitlement identifier before creating products. It is the stable
access flag the app checks; package and product names are presentation/catalog
details. Expired currently checks `Expired Pro`.

## 1. Terminology

- **Store product**: the Apple product created in App Store Connect. It owns
  price, availability, billing period, and introductory offers.
- **Entitlement**: the access right, such as `Expired Pro`. The app checks this.
- **Offering**: a remotely configurable set of products shown for a use case.
  The app's default offering is normally the starting point.
- **Package**: a product's position inside an offering, commonly monthly,
  annual, or lifetime.
- **Paywall**: the visual purchase UI attached to an offering. A paywall does
  not create products or prices.
- **Public SDK key**: safe to ship in the client, but it must match the app and
  environment. **Secret API key** and **webhook secret** stay server-side.
- **Sandbox/Test Store**: test transactions. They do not prove production
  App Store Connect wiring.

## 2. App Store Connect

1. Open the app → Monetization → Subscriptions.
2. Create a subscription group, then monthly and yearly auto-renewable
   subscriptions. Use stable IDs and document them in this file.
3. Configure the yearly introductory offer in App Store Connect: open the
   yearly subscription, find **Introductory Offers**, add a **7-day free trial**,
   and confirm it is attached to the yearly product rather than the group
   generally. RevenueCat displays the offer returned by Apple; it does not
   create the Apple introductory offer itself.
4. Open Monetization → In-App Purchases and create/verify the lifetime
   non-consumable at `$49.99`.
5. Set pricing, availability, localization, review metadata, and availability
   for every product. Save each product and check its status.
6. Record the exact product IDs and status here:

| Product | ID | Type/period | Intro offer | ASC status |
| --- | --- | --- | --- | --- |
| Monthly | `com.swiftstudio.expired.pro.monthly2` | subscription / 1 month | none | `$1.99` confirmed in ASC; metadata status needs separate verification |
| Yearly | `com.swiftstudio.expired.pro.yearly` | subscription / 1 year | 7-day trial; verify offer separately | `$19.99` confirmed in ASC; metadata status needs separate verification |
| Lifetime | `com.swiftstudio.expired.pro.lifetime` | non-consumable | n/a | `$49.99` and product record confirmed in ASC |

## 3. RevenueCat app configuration

1. In the RevenueCat project, open **Apps** and add the real App Store
   configuration. Select App Store, not Test Store.
2. Complete the App Store Connect connection using RevenueCat's requested
   credentials. Do not put those credentials in source control.
3. Copy the resulting **public** App Store SDK key into the app's release
   configuration. Keep the Test Store key only for a clearly isolated test
   configuration.
4. Confirm the app configuration is the one selected when viewing products.
5. In Product catalog, import or create the three products using the exact ASC
   product IDs. Do this only after the ASC records, prices, availability, and
   yearly introductory offer are configured. A product ID mismatch is the most
   common reason offerings are empty.
6. Create/confirm entitlement `Expired Pro`, then attach all three products to
   that entitlement.

## 4. Offering and paywall

1. Confirm the ASC products are available first; RevenueCat product rows may
   remain `No product` until Apple metadata/sync is complete. Then open
   **Product catalog → Offerings** and use the `default` offering (or make
   the intended offering current).
2. Add monthly, yearly, and lifetime packages and map each to the correct store
   product.
3. Open **Paywalls → New paywall → Use a template**. A simple native template is
   a good first integration.
4. Attach the paywall to the intended offering.
5. Set yearly as the highlighted/default package if the editor exposes that
   control. If it does not, use the editor's package ordering or “Most Popular”
   control and verify the rendered preview; do not assume ordering alone changes
   selection.
6. Save and **Publish**. A draft is not the live configuration.
7. Confirm the offering now shows the paywall instead of “Add Paywall”.

## 5. Supabase webhook mirror (optional)

1. Deploy the webhook function with JWT verification disabled and a server-only
   shared secret.
2. In RevenueCat → Integrations → Webhooks, use the deployed function URL and
   `Authorization: Bearer <webhook-secret>`.
3. Configure the server's RevenueCat secret API key separately. Never ship it in
   the app.
4. Test a sandbox purchase and verify the webhook updates the entitlement mirror.
5. Before launch, verify production-first entitlement lookup and disable any
   sandbox fallback deliberately.

## 6. Client verification

- Configure RevenueCat once, after the app's stable user identity is available.
- Use the same canonical identity in Supabase, RevenueCat, and the webhook.
- Load offerings and confirm all three packages are present.
- Confirm `Expired Pro` becomes active after a sandbox purchase and after restore.
- Confirm a fresh test user is not premium.
- Confirm purchase, restore, expiration, and identity resynchronization paths.
- Test the published paywall, not only RevenueCatUI's generic fallback.
- Replace the Test Store key with the real App Store public SDK key for release.

## 7. Troubleshooting map

| Symptom | Likely cause | Check |
| --- | --- | --- |
| Offerings are empty | Wrong app configuration, product ID mismatch, or ASC product not ready | RevenueCat app/environment and exact IDs |
| Generic paywall appears | No paywall is attached/published | Offering's Paywall field |
| Yearly is not highlighted | Paywall default/featured setting is unset | Published editor configuration and preview |
| Purchase succeeds but app is not premium | Entitlement not attached or identifier mismatch | Product → entitlement and client constant |
| Supabase says not premium | Webhook failed or app user IDs differ | Webhook logs, `app_user_id`, JWT subject |
| Sandbox works but production fails | Test Store key or sandbox-only lookup remains enabled | Release key and server production-first logic |

## 8. Project record: Expired (2026-07-11)

### Verified current state

- RevenueCat project: `Expired`; project ID `79ab2961`.
- A real App Store app configuration was created during this integration with
  bundle ID `com.swiftstudio.Expired`. RevenueCat offered an existing App Store
  Connect in-app purchase key already used by another team app; selecting that
  existing team key was the correct path, and the key value is intentionally not
  recorded here.
- The existing `default` offering contained Test Store packages. The real app
  rows were initially `New Product`. RevenueCat products were then created for
  all three exact IDs, and all three real App Store products were mapped into
  the `default` offering.
- The existing `Expired Pro` entitlement already contained the three Test Store
  products. The three real App Store products were additionally attached, so
  the entitlement now contains both test and real platform products.
- A paywall draft was created from a RevenueCat template and attached to the
  `default` offering. The editor currently reports two validation issues and
  has not yet been published.
- RevenueCat currently offers Paywalls in the main left navigation. The New
  paywall menu exposes “Use a template”.
- App Store Connect app: Expired; app ID `6780233938`.
- The app already uses `RevenueCatUI.PaywallView()` and loads the default offering.
- Client entitlement constant: `Expired Pro`.
- Planned products: monthly, yearly, lifetime; yearly should carry the trial.

### What differed from the old prompt

- The old prompt assumed the real App Store configuration was already present;
  it was not, so creating the real app configuration was required before
  product mapping.
- The current RevenueCat sidebar exposes **Paywalls** as a first-class item and
  the creation flow explicitly offers **Use a template**.
- App Store Connect exposes products under **Monetization**, split between
  **Subscriptions** and **In-App Purchases**.
- The old backend setup said to create entitlement `premium`; the app actually
  checks `Expired Pro`. Keep one canonical identifier per project.

### Still to complete

- Configure and verify the yearly 7-day introductory offer in ASC.
- Resolve the two paywall-editor validation issues ("Add a URL to the button" —
  Terms/Privacy links on the draft template) and publish the paywall with yearly
  featured. Currently an unpublished draft using a generic "MellowMind"
  meditation-app template with placeholder pricing — cosmetically unrelated to
  Expired, needs real copy/branding before publishing. Not a functional blocker:
  RevenueCatUI shows its own default paywall UI when no custom one is published,
  it doesn't crash or block purchases.
- Configure/test the Supabase webhook and production secret path.
- ~~Replace the test SDK key in the release configuration~~ — **done 2026-07-27.**
  See `IMPLEMENTATION_LOG.md`'s 2026-07-27 entry: this was the actual TestFlight
  crash cause (RevenueCat's SDK hard-crashes on a Test Store key in a Release
  build, by design). `BackendConfig.swift` now uses the real `Expired (App Store)`
  SDK key. Still TODO: flip off any sandbox-only fallback (the `X-Is-Sandbox: true`
  header in the AI proxy's entitlement check, per `monetization-stack-decisions`
  memory gotcha #4) before actual App Store release — not urgent while
  TestFlight-only.

## 9. Evidence log template

For each integration, append dated entries like:

`YYYY-MM-DD — Surface — Expected: ... Actual: ... — Result/action: ...`

### Expired evidence

- `2026-07-11 — ASC — Expected product setup to be grouped in one catalog — Actual: subscriptions are under Monetization → Subscriptions, while lifetime belongs under Monetization → In-App Purchases.`
- `2026-07-11 — RevenueCat — Expected the real app to already exist — Actual: the project initially exposed only Test Store; real App Store setup was under Apps → add app configuration.`
- `2026-07-11 — RevenueCat — Expected a product picker to immediately contain ASC IDs — Actual: each offering package had a per-platform row labelled New Product; after the ASC app configuration, monthly could be added by entering the exact ID, while yearly/lifetime remained unavailable until their ASC catalog records are ready.`
- `2026-07-11 — RevenueCat — Expected API keys to be needed before app creation — Actual: the App Store setup requested an App Store Connect in-app purchase key during app configuration and allowed selecting an existing team key.`
- `2026-07-11 — ASC — Expected the existing subscription rows to be purchase-ready — Actual: yearly showed localized copy and availability but still reported Missing Metadata; the page also exposed Add Pricing, so RevenueCat product selection cannot be treated as proof that Apple-side pricing/review metadata is complete.`
- `2026-07-11 — ASC — Pricing decision — Actual: monthly $1.99, yearly $19.99, lifetime $49.99 are set in ASC; the lifetime product record and exact ID are present. The yearly 7-day offer still needs an explicit Introductory Offers check.`

This keeps dashboard drift and terminology changes discoverable for the next
project without storing credentials.
