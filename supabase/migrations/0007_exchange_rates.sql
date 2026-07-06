-- Exchange rates table. Updated daily by the `update-exchange-rates` Edge Function.
-- Rates are USD-based (1 USD = N units of each currency), matching CurrencyInfo.ratesFromUSD.
-- Public RLS: anyone with an anon session can SELECT; only the service role can write.

create table if not exists public.exchange_rates (
    currency_code text        primary key,
    rate_vs_usd   numeric     not null,
    updated_at    timestamptz not null default now()
);

alter table public.exchange_rates enable row level security;

create policy "public read exchange_rates"
    on public.exchange_rates
    for select
    using (true);

-- No INSERT/UPDATE policy: the edge function runs with the service role key, which
-- bypasses RLS entirely, so no explicit write policy is needed.

-- ── Scheduling ────────────────────────────────────────────────────────────────────
-- After deploying the `update-exchange-rates` function, schedule it in the Supabase
-- dashboard: Functions → update-exchange-rates → Schedule → "0 5 * * *" (05:00 UTC).
-- That is 5 minutes after the ECB publishes new rates each weekday.
--
-- To do the first seed manually (before the schedule fires):
--   supabase functions invoke update-exchange-rates --project-ref ehibtlaoshmqpbnexehy
