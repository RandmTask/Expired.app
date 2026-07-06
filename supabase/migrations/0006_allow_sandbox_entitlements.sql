-- Expired — gate the RevenueCat sandbox-entitlement fallback behind a config flag.
--
-- Background: ai-proxy used to send `X-Is-Sandbox: true` unconditionally on its
-- RevenueCat lookup. That was necessary for pre-launch StoreKit-testing / Test Store
-- purchases to resolve, but it would 402 EVERY real App Store customer after launch —
-- production purchases are invisible under the sandbox header. The proxy now checks
-- production first and only falls back to sandbox when this flag is true.
--
-- Seeded true to preserve the CURRENT test flow (sandbox/Test Store purchases).
-- >>> Flip to false at (or just before) App Store launch <<< so real customers are
-- only ever verified against production:
--     update public.app_config set value = 'false'::jsonb
--     where key = 'allow_sandbox_entitlements';
insert into public.app_config (key, value) values
    ('allow_sandbox_entitlements', 'true'::jsonb)
on conflict (key) do nothing;
