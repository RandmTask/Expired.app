# Expired — Supabase + RevenueCat backend setup

This folder is the server side of the Supabase + RevenueCat integration. It holds
the AI proxy (so no provider key ships on-device), per-user rate limiting + a
global kill-switch, and the RevenueCat entitlement mirror the proxy checks.

> **Identity model:** the app signs in **anonymously** at launch
> (`supabase.auth.signInAnonymously()`) and passes that UUID to RevenueCat as the
> `appUserID`. So Supabase, RevenueCat, and the proxy all share one identity with
> zero user friction. Subscription **data stays in CloudKit** — these tables hold
> only metering + entitlement state.

## Layout

```
supabase/
├── config.toml                       # per-function verify_jwt settings
├── migrations/0001_init.sql          # usage, entitlements, app_config, increment_usage()
└── functions/
    ├── _shared/{cors,auth,providers}.ts
    ├── ai-proxy/index.ts             # gated, rate-limited AI forwarder
    ├── models/index.ts               # live model-list proxy
    └── revenuecat-webhook/index.ts   # entitlement mirror
```

## One-time setup

### 1. Link the project & push the schema
```bash
cd "supabase"
supabase login
supabase link --project-ref <YOUR_PROJECT_REF>
supabase db push                      # applies migrations/0001_init.sql
```

### 2. Set function secrets
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected
automatically. Add the rest:
```bash
supabase secrets set OPENAI_API_KEY=sk-...
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
supabase secrets set GEMINI_API_KEY=...
supabase secrets set DEEPSEEK_API_KEY=...
supabase secrets set REVENUECAT_SECRET_API_KEY=sk_...
supabase secrets set REVENUECAT_WEBHOOK_SECRET=$(openssl rand -hex 24)
```
You only need keys for the providers you actually want to offer. A provider with
no key returns 502 "Provider not configured".
`REVENUECAT_SECRET_API_KEY` lets `ai-proxy` verify and repair Premium entitlement
state directly when the webhook mirror is stale. If your RevenueCat entitlement
identifier differs from `Expired Pro` or `premium`, also set
`REVENUECAT_ENTITLEMENT_IDS` to a comma-separated list.

### 3. Deploy the functions
```bash
supabase functions deploy ai-proxy
supabase functions deploy models
supabase functions deploy revenuecat-webhook   # verify_jwt=false comes from config.toml
```

### 4. RevenueCat dashboard
1. Create a project + app; create an entitlement with identifier **`premium`**.
2. Create your subscription product(s) in App Store Connect and attach them to an
   Offering.
3. **Integrations → Webhooks:** URL `https://<ref>.functions.supabase.co/revenuecat-webhook`,
   Authorization header value `Bearer <REVENUECAT_WEBHOOK_SECRET>` (the value from step 2).
4. Copy the **public SDK key** (used by the app, not here).

### 5. App-side config (handled in the Swift client, not this folder)
- Supabase URL + **anon key** (public by design) and the RevenueCat **public SDK key**
  go in the client. The service-role key and provider keys **never leave Supabase**.

## Tuning the caps / kill-switch
All live in `public.app_config` — change without redeploying:
```sql
update public.app_config set value = 'false' where key = 'ai_enabled';        -- kill-switch ON
update public.app_config set value = '100'   where key = 'daily_request_cap';  -- per-user/day
```

## Quick verification
```bash
# Should be 401 (no JWT)
curl -i -X POST https://<ref>.functions.supabase.co/ai-proxy -d '{}'

# With a real anon access token but no premium entitlement → 402 Premium required
curl -i -X POST https://<ref>.functions.supabase.co/ai-proxy \
  -H "Authorization: Bearer <ANON_ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"provider":"openai","model":"gpt-4.1-mini","body":{"model":"gpt-4.1-mini","messages":[]}}'
```
