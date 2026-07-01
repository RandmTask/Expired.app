-- Expired — per-provider health, derived from real cascade traffic.
-- Deliberately NOT a scheduled synthetic ping: pinging providers on a timer just to
-- check health would itself spend real tokens. Recording success/failure as a
-- byproduct of real ai-proxy calls is free and a more accurate signal anyway.
create table if not exists public.provider_health (
    provider              text primary key,
    consecutive_failures  integer     not null default 0,
    last_success_at       timestamptz,
    last_failure_at       timestamptz,
    last_failure_status   text
);

alter table public.provider_health enable row level security;
-- No policies: only the service role (ai-proxy) may read/write.

create or replace function public.record_provider_health(p_provider text, p_success boolean, p_status text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.provider_health (provider, consecutive_failures, last_success_at, last_failure_at, last_failure_status)
    values (
        p_provider,
        case when p_success then 0 else 1 end,
        case when p_success then now() else null end,
        case when p_success then null else now() end,
        case when p_success then null else p_status end
    )
    on conflict (provider) do update
        set consecutive_failures = case when p_success then 0 else public.provider_health.consecutive_failures + 1 end,
            last_success_at      = case when p_success then now() else public.provider_health.last_success_at end,
            last_failure_at      = case when p_success then public.provider_health.last_failure_at else now() end,
            last_failure_status  = case when p_success then public.provider_health.last_failure_status else p_status end;
end;
$$;
