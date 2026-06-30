// models — proxies each provider's model-list endpoint so the live model picker
// keeps working with no provider key on device. Mirrors ScreenshotAIModelService.
//
// Contract (POST): { "provider": "openai"|"claude"|"gemini"|"deepseek" }
// Returns the provider's raw /models JSON; the Swift client parses each shape.

import { corsHeaders } from "../_shared/cors.ts";
import { json } from "../_shared/cors.ts";
import { userIdFromRequest } from "../_shared/auth.ts";
import { modelsTarget, ProviderID } from "../_shared/providers.ts";

const ALLOWED: ProviderID[] = ["openai", "claude", "gemini", "deepseek"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: { message: "Method not allowed" } }, 405);

  const userId = await userIdFromRequest(req);
  if (!userId) return json({ error: { message: "Not authenticated" } }, 401);

  let provider: ProviderID;
  try {
    provider = (await req.json()).provider;
    if (!ALLOWED.includes(provider)) throw new Error("bad provider");
  } catch {
    return json({ error: { message: "Invalid request body" } }, 400);
  }

  const target = modelsTarget(provider);
  if (!target) return json({ error: { message: "Provider not configured" } }, 502);

  let upstream: Response;
  try {
    upstream = await fetch(target.url, { method: "GET", headers: target.headers });
  } catch (e) {
    return json({ error: { message: `Upstream request failed: ${e}` } }, 502);
  }

  const payload = await upstream.text();
  return new Response(payload, {
    status: upstream.status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
