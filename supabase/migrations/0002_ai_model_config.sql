-- Expired — server-driven AI model + fallback config.
-- Lets a provider renaming/retiring a model be fixed by editing a row here
-- (Supabase Table Editor), no app release. Read by ai-proxy on every call.

-- ai_fallback_order: cloud providers only, tried in this order by ai-proxy
-- when mode = "auto". Apple Intelligence is always tried first, on-device,
-- before the client ever calls the proxy — it never appears in this list.
-- Removing a provider from the array disables it for the cascade.
insert into public.app_config (key, value) values
    ('ai_fallback_order', '["gemini", "deepseek"]'::jsonb)
on conflict (key) do nothing;

-- ai_model_<provider>: the model ID ai-proxy uses for that provider when
-- running the cascade. Seeded with the same defaults already hardcoded in
-- ScreenshotAIProvider.swift — update the value here (not the Swift code)
-- when a provider renames/retires a model.
insert into public.app_config (key, value) values
    ('ai_model_gemini',   '"gemini-2.5-flash"'::jsonb),
    ('ai_model_deepseek', '"deepseek-chat"'::jsonb)
on conflict (key) do nothing;
