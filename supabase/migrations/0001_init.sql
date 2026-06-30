-- Expired — Supabase backend schema
-- Identity + usage metering + RevenueCat entitlement mirror.
-- NOTE: subscription DATA stays in CloudKit/SwiftData. These tables hold ONLY
-- identity-scoped metering and entitlement state used to gate the AI proxy.

-- ---------------------------------------------------------------------------
-- app_config: server-controlled switches (kill-switch, caps). Service-role only.
-- ---------------------------------------------------------------------------
create table if not exists public.app_config (
    key   text primary key,
    value jsonb not null
);

insert into public.app_config (key, value) values
    ('ai_enabled',        'true'::jsonb),   -- global kill-switch for all AI calls
    ('daily_request_cap', '50'::jsonb)      -- per-user AI requests per UTC day
on conflict (key) do nothing;

alter table public.app_config enable row level security;
-- No policies: only the service role (which bypasses RLS) may read/write.

-- ---------------------------------------------------------------------------
-- usage: per-user / per-day AI request metering (spend-cap input).
-- ---------------------------------------------------------------------------
create table if not exists public.usage (
    user_id        uuid    not null references auth.users (id) on delete cascade,
    day            date    not null default (now() at time zone 'utc')::date,
    request_count  integer not null default 0,
    token_estimate bigint  not null default 0,
    primary key (user_id, day)
);

alter table public.usage enable row level security;

-- A user may read their own usage; writes happen via SECURITY DEFINER rpc / service role.
create policy "usage_select_own" on public.usage
    for select using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- entitlements: RevenueCat-mirrored premium state (source of truth for the proxy).
-- Written only by the revenuecat-webhook function (service role).
-- ---------------------------------------------------------------------------
create table if not exists public.entitlements (
    user_id        uuid primary key references auth.users (id) on delete cascade,
    premium_active boolean     not null default false,
    expires_at     timestamptz,
    updated_at     timestamptz not null default now()
);

alter table public.entitlements enable row level security;

create policy "entitlements_select_own" on public.entitlements
    for select using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- increment_usage: atomic per-day counter bump. Called by ai-proxy AFTER a
-- successful provider call so blocked/failed requests are not charged.
-- ---------------------------------------------------------------------------
create or replace function public.increment_usage(p_user uuid, p_tokens bigint default 0)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    new_count integer;
begin
    insert into public.usage (user_id, day, request_count, token_estimate)
    values (p_user, (now() at time zone 'utc')::date, 1, p_tokens)
    on conflict (user_id, day) do update
        set request_count  = public.usage.request_count + 1,
            token_estimate = public.usage.token_estimate + p_tokens
    returning request_count into new_count;
    return new_count;
end;
$$;
