-- Expired — app-wide AI request ceiling, on top of the existing per-user cap.
-- A per-user daily_request_cap alone can't catch a viral spike, a retry storm from
-- a client bug, or one compromised account spread across many days — this bounds
-- the whole app's AI spend regardless of how usage is distributed across users.
insert into public.app_config (key, value) values
    ('global_daily_request_cap', '500'::jsonb)
on conflict (key) do nothing;
