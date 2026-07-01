// ai-proxy — authenticated, entitlement-gated, rate-limited forwarder for AI calls.
//
// Contract (POST):
//   { "mode":  "auto" | "forced",
//     "provider": "openai"|"claude"|"gemini"|"deepseek",   // required when mode = "forced"
//     "visionPrompt": "<prompt for vision-capable providers>",
//     "textPrompt":   "<prompt with OCR lines, for text-only providers>",
//     "image": { "mime": "image/png", "base64": "..." },   // optional
//     "simulateFailures": ["gemini"] }                     // optional, debug-only cascade testing
//
// "auto" tries providers from app_config.ai_fallback_order in sequence, server-side,
// in one round trip — the client never sees an intermediate failure. "forced" calls
// exactly one named provider (used by the Settings debug picker / manual testing).
// The server holds every provider key; the client never sees it. Order of checks:
//   1. valid Supabase JWT (anon sessions count)         -> 401
//   2. global kill-switch (app_config.ai_enabled)       -> 503
//   3. premium entitlement active                       -> 402
//   4. per-user daily request cap                        -> 429
//   4b. app-wide daily request cap (all users)            -> 503
//   5. try each candidate provider in order; bump usage + real token count only
//      once, on the first 2xx.
//
// This bounds request *count*, not $ spend directly — token cost still varies with
// prompt/image/response size. Set a hard spend cap in each provider's own dashboard
// (OpenAI billing limits, Google Cloud budget alerts, DeepSeek prepaid balance) as
// the real backstop; these caps are the app-level insurance on top of that.

import { corsHeaders, json } from "../_shared/cors.ts";
import { serviceClient, userIdFromRequest } from "../_shared/auth.ts";
import { buildRequestBody, chatTarget, DEFAULT_MODEL, extractTokenCount, ImagePayload, ProviderID } from "../_shared/providers.ts";

const ALLOWED: ProviderID[] = ["openai", "claude", "gemini", "deepseek"];
const REVENUECAT_API_URL = "https://api.revenuecat.com/v1/subscribers";

interface RequestBody {
  mode: "auto" | "forced";
  provider?: ProviderID;
  visionPrompt: string;
  textPrompt: string;
  image?: ImagePayload;
  simulateFailures?: ProviderID[];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: { message: "Method not allowed" } }, 405);

  // 1. Identity
  const userId = await userIdFromRequest(req);
  if (!userId) return json({ error: { message: "Not authenticated" } }, 401);

  // Parse early so a bad body fails before any DB work.
  let parsed: RequestBody;
  try {
    parsed = await req.json();
    if (!parsed.visionPrompt && !parsed.textPrompt) throw new Error("bad request");
    if (parsed.mode === "forced" && !parsed.provider) throw new Error("bad request");
  } catch {
    return json({ error: { message: "Invalid request body" } }, 400);
  }

  const db = serviceClient();

  // 2. Kill-switch + cascade config, in one round trip.
  const { data: cfg } = await db
    .from("app_config")
    .select("key,value")
    .in("key", [
      "ai_enabled",
      "daily_request_cap",
      "global_daily_request_cap",
      "ai_fallback_order",
      "ai_model_gemini",
      "ai_model_deepseek",
      "revenuecat_entitlement_ids",
    ]);
  const config = Object.fromEntries((cfg ?? []).map((r) => [r.key, r.value]));
  if (config.ai_enabled === false) {
    return json({ error: { message: "AI is temporarily disabled." } }, 503);
  }
  const dailyCap = Number(config.daily_request_cap ?? 50);

  // 3. Premium entitlement (AI import is a Premium feature)
  const ids = entitlementIDs(config);
  const check = await hasPremiumEntitlement(db, userId, ids);
  if (!check.active) {
    // checkedEntitlementIDs + revenueCatCheck are diagnostic only (not sensitive) —
    // lets the client's console log show exactly which identifier(s) were checked
    // and why the RevenueCat lookup didn't resolve active, without server access.
    return json({
      error: {
        message: "Expired Pro verification required. Restore purchases and try again.",
        checkedEntitlementIDs: ids,
        revenueCatCheck: check.detail,
      },
    }, 402);
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

  // 4b. App-wide cap — catches a viral spike or retry storm that a per-user cap
  // alone wouldn't, regardless of how usage is spread across accounts.
  const globalCap = Number(config.global_daily_request_cap ?? 500);
  const { data: allUsageToday } = await db
    .from("usage")
    .select("request_count")
    .eq("day", today);
  const totalToday = (allUsageToday ?? []).reduce((sum, row) => sum + (row.request_count ?? 0), 0);
  if (totalToday >= globalCap) {
    return json({ error: { message: "AI import is at capacity for today. Try again tomorrow." } }, 503);
  }

  // 5. Candidate list: one named provider ("forced", used by the debug picker /
  // manual testing) or the configured cascade order ("auto").
  const candidates: ProviderID[] = parsed.mode === "forced"
    ? [parsed.provider!]
    : ((config.ai_fallback_order as ProviderID[] | undefined) ?? ["gemini", "deepseek"])
      .filter((p): p is ProviderID => ALLOWED.includes(p));

  if (!candidates.length) return json({ error: { message: "No provider configured" } }, 502);

  const tried: { provider: ProviderID; status: number | string }[] = [];

  for (const provider of candidates) {
    const model = (config[`ai_model_${provider}`] as string | undefined) ?? DEFAULT_MODEL[provider];
    const target = chatTarget(provider, model);
    if (!target) {
      tried.push({ provider, status: "not_configured" });
      continue; // missing server secret — instant skip, not a real health signal
    }

    // Debug-only: simulate this provider being down, to exercise the cascade
    // without needing a real outage. Never triggered by a normal client call.
    if (parsed.simulateFailures?.includes(provider)) {
      tried.push({ provider, status: "simulated_failure" });
      continue;
    }

    const body = buildRequestBody(provider, model, {
      visionPrompt: parsed.visionPrompt,
      textPrompt: parsed.textPrompt,
      image: parsed.image,
    });

    let upstream: Response;
    try {
      upstream = await fetch(target.url, {
        method: "POST",
        headers: target.headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(15_000),
      });
    } catch (e) {
      tried.push({ provider, status: `network_error: ${e}` });
      db.rpc("record_provider_health", { p_provider: provider, p_success: false, p_status: "network_error" }).then(() => {});
      continue;
    }

    if (!upstream.ok) {
      tried.push({ provider, status: upstream.status });
      db.rpc("record_provider_health", { p_provider: provider, p_success: false, p_status: String(upstream.status) }).then(() => {});
      continue;
    }

    // Success — charge only the winning call, return which provider answered
    // so the client parses with the matching per-provider extractor.
    const raw = await upstream.json();
    const tokenCount = extractTokenCount(provider, raw);
    db.rpc("increment_usage", { p_user: userId, p_tokens: tokenCount }).then(() => {});
    db.rpc("record_provider_health", { p_provider: provider, p_success: true }).then(() => {});
    return json({ provider, model, raw }, 200);
  }

  return json({ error: { message: "All providers unavailable", tried } }, 502);
});

function entitlementIDs(config: Record<string, unknown>): string[] {
  const configured = config.revenuecat_entitlement_ids;
  const envValue = Deno.env.get("REVENUECAT_ENTITLEMENT_IDS") ?? Deno.env.get("REVENUECAT_ENTITLEMENT_ID");
  const raw = Array.isArray(configured)
    ? configured.join(",")
    : typeof configured === "string"
      ? configured
      : envValue ?? "Expired Pro,premium";

  return [...new Set(
    raw.split(",")
      .map((id) => id.trim())
      .filter(Boolean),
  )];
}

interface EntitlementCheck {
  active: boolean;
  /** Diagnostic only (not sensitive) — surfaced in the 402 body so a failure mode
   * (wrong/missing secret key, RevenueCat 401/404, vs. a genuinely inactive
   * customer) is visible from the client's console log without server access. */
  detail: string;
}

async function hasPremiumEntitlement(
  db: ReturnType<typeof serviceClient>,
  userId: string,
  ids: string[],
): Promise<EntitlementCheck> {
  const { data: ent } = await db
    .from("entitlements")
    .select("premium_active, expires_at")
    .eq("user_id", userId)
    .maybeSingle();

  if (entitlementActive(ent?.premium_active, ent?.expires_at)) {
    return { active: true, detail: "local_mirror_active" };
  }

  // Webhooks can be delayed, disabled in sandbox, or missed during setup. When the
  // local mirror says "no", ask RevenueCat directly and repair the mirror.
  return await refreshRevenueCatEntitlement(db, userId, ids);
}

function entitlementActive(active: unknown, expiresAt: unknown): boolean {
  return active === true &&
    (typeof expiresAt !== "string" || !expiresAt || new Date(expiresAt).getTime() > Date.now());
}

async function refreshRevenueCatEntitlement(
  db: ReturnType<typeof serviceClient>,
  userId: string,
  ids: string[],
): Promise<EntitlementCheck> {
  const apiKey = Deno.env.get("REVENUECAT_SECRET_API_KEY") ?? Deno.env.get("REVENUECAT_API_KEY");
  if (!apiKey) return { active: false, detail: "no_secret_key_configured" };

  let response: Response;
  try {
    response = await fetch(`${REVENUECAT_API_URL}/${encodeURIComponent(userId)}`, {
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(8_000),
    });
  } catch (e) {
    return { active: false, detail: `revenuecat_fetch_failed: ${e}` };
  }
  if (!response.ok) {
    // 401/403 -> wrong or expired secret key. 404 -> this userId has never been
    // seen by RevenueCat at all (classic anon-session / appUserID mismatch).
    return { active: false, detail: `revenuecat_http_${response.status}` };
  }

  const body = await response.json();
  const entitlements = body?.subscriber?.entitlements ?? {};
  const matched = ids
    .map((id) => entitlements[id])
    .find((entitlement) => entitlement != null);

  const expiresAt = typeof matched?.expires_date === "string" ? matched.expires_date : null;
  const active = matched != null && (!expiresAt || new Date(expiresAt).getTime() > Date.now());

  await db
    .from("entitlements")
    .upsert(
      {
        user_id: userId,
        premium_active: active,
        expires_at: expiresAt,
        updated_at: new Date().toISOString(),
      },
      { onConflict: "user_id" },
    );

  return { active, detail: active ? "active" : (matched ? "expired" : "no_matching_entitlement_on_revenuecat_customer") };
}
