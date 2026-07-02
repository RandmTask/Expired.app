-- Expired — service_role was missing baseline DML grants (SELECT/INSERT/UPDATE/DELETE)
-- on every public-schema table since 0001; it only had REFERENCES/TRIGGER/TRUNCATE.
-- RLS's BYPASSRLS attribute on service_role skips row-level *policies*, but a role
-- still needs the base SQL GRANT to touch a table at all — this project's service_role
-- never got one. Every ai-proxy service-role read/write (app_config, entitlements,
-- usage, provider_health) has been silently failing since day one: the code discards
-- the error and falls through to hardcoded defaults, so nothing looked broken.
grant select, insert, update, delete on all tables in schema public to service_role;

-- Also cover tables created by future migrations, so this can't silently regress.
alter default privileges in schema public
    grant select, insert, update, delete on tables to service_role;
