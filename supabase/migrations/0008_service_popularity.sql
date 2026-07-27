-- Anonymous, per-device service-popularity counter. Feeds AppCatalog curation
-- (which services to surface first in onboarding/search) without ever touching
-- personal data: only a canonical AppCatalog service name is ever sent, never a
-- user identifier, cost, date, or free-text field. A device reports a given name
-- at most once (enforced client-side), so this measures "how many devices use
-- this service" rather than "how many times was it added."
--
-- No direct table access for anon/authenticated — RLS is enabled with no policies,
-- so all reads/writes must go through increment_service_popularity() below, which
-- runs as security definer and only ever increments a counter by name.

create table if not exists public.service_popularity (
    name         text primary key,
    device_count integer     not null default 0,
    updated_at   timestamptz not null default now()
);

alter table public.service_popularity enable row level security;

create or replace function public.increment_service_popularity(p_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.service_popularity (name, device_count)
    values (p_name, 1)
    on conflict (name) do update
        set device_count = service_popularity.device_count + 1,
            updated_at = now();
end;
$$;

grant execute on function public.increment_service_popularity(text) to anon, authenticated;
