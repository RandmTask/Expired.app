// ai-proxy — authenticated, entitlement-gated, rate-limited forwarder for AI calls.
//
// Contract (POST):
//   { "provider": "openai"|"claude"|"gemini"|"deepseek",
//     "model":    "<model id>",          // used for the Gemini URL + usage notes
//     "body":     { ...provider request body WITHOUT the key... } }
//
// The server holds the provider key; the client never sees it. Order of checks:
//   1. valid Supabase JWT (anon sessions count)         -> 401
//   2. global kill-switch (app_config.ai_enabled)       -> 503
//   3. premium entitlement active                       -> 402
//   4. per-user daily request cap                        -> 429
//   5. forward to provider, pass response through; bump usage only on 2xx.

import { corsHeaders, json } from "../_shared/cors.ts";
import { serviceClient, userIdFromRequest } from "../_shared/auth.ts";
import { chatTarget, ProviderID } from "../_shared/providers.ts";

const ALLOWED: ProviderID[] = ["openai", "claude", "gemini", "deepseek"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: { message: "Method not allowed" } }, 405);

  // 1. Identity
  const userId = await userIdFromRequest(req);
  if (!userId) return json({ error: { message: "Not authenticated" } }, 401);

  // Parse early so a bad body fails before any DB work.
  let provider: ProviderID, model: string, body: unknown;
  try {
    const parsed = await req.json();
    provider = parsed.provider;
    model = parsed.model ?? "";
    body = parsed.body;
    if (!ALLOWED.includes(provider) || !body) throw new Error("bad request");
  } catch {
    return json({ error: { message: "Invalid request body" } }, 400);
  }

  const db = serviceClient();

  // 2. Kill-switch
  const { data: cfg } = await db
    .from("app_config")
    .select("key,value")
    .in("key", ["ai_enabled", "daily_request_cap"]);
  const config = Object.fromEntries((cfg ?? []).map((r) => [r.key, r.value]));
  if (config.ai_enabled === false) {
    return json({ error: { message: "AI is temporarily disabled." } }, 503);
  }
  const dailyCap = Number(config.daily_request_cap ?? 50);

  // 3. Premium entitlement (AI import is a Premium feature)
  const { data: ent } = await db
    .from("entitlements")
    .select("premium_active, expires_at")
    .eq("user_id", userId)
    .maybeSingle();
  const active = ent?.premium_active === true &&
    (!ent.expires_at || new Date(ent.expires_at).getTime() > Date.now());
  if (!active) {
    return json({ error: { message: "Premium required" } }, 402);
  }

  // 4. Daily cap (check before spending; increment only after success)
  const today = new Date().toISOString().slice(0, 10);
  const { data: usage } = await db
    .from("usage")
    .select("request_count")
    .eq("user_id", userId)
    .eq("day", today)
    .maybeSingle();
  if ((usage?.request_count ?? 0) >= dailyCap) {
    return json({ error: { message: "Daily limit reached. Try again tomorrow." } }, 429);
  }

  // 5. Forward
  const target = chatTarget(provider, model);
  if (!target) return json({ error: { message: "Provider not configured" } }, 502);

  let upstream: Response;
  try {
    upstream = await fetch(target.url, {
      method: "POST",
      headers: target.headers,
      body: JSON.stringify(body),
    });
  } catch (e) {
    return json({ error: { message: `Upstream request failed: ${e}` } }, 502);
  }

  const payload = await upstream.text();
  if (upstream.ok) {
    // Charge only successful calls. Fire-and-forget; a metering miss is acceptable.
    db.rpc("increment_usage", { p_user: userId }).then(() => {});
  }
  return new Response(payload, {
    status: upstream.status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
