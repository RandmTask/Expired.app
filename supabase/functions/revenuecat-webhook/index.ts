// revenuecat-webhook — mirrors RevenueCat entitlement state into public.entitlements,
// the server-side source of truth the ai-proxy checks. Configured with verify_jwt = false
// (RevenueCat is not a Supabase user); authenticated instead by a shared bearer secret
// set in both the RevenueCat dashboard and the REVENUECAT_WEBHOOK_SECRET function secret.
//
// app_user_id MUST be the Supabase user UUID — the client configures RevenueCat with
// appUserID = the anonymous Supabase session id, so the two systems share one identity.

import { json } from "../_shared/cors.ts";
import { serviceClient } from "../_shared/auth.ts";

// Event types that mean the subscription is currently entitled.
const ACTIVE_TYPES = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "PRODUCT_CHANGE",
  "UNCANCELLATION",
  "NON_RENEWING_PURCHASE",
  "SUBSCRIPTION_EXTENDED",
]);
// Event types that mean access has ended. (CANCELLATION only stops auto-renew;
// access continues until EXPIRATION, so it is intentionally NOT here.)
const INACTIVE_TYPES = new Set(["EXPIRATION", "SUBSCRIPTION_PAUSED", "BILLING_ISSUE"]);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  // Shared-secret auth.
  const expected = Deno.env.get("REVENUECAT_WEBHOOK_SECRET");
  if (!expected || req.headers.get("Authorization") !== `Bearer ${expected}`) {
    return json({ error: "Unauthorized" }, 401);
  }

  let event: Record<string, unknown>;
  try {
    event = (await req.json()).event ?? {};
  } catch {
    return json({ error: "Invalid body" }, 400);
  }

  const userId = String(event.app_user_id ?? "");
  const type = String(event.type ?? "");
  // RevenueCat anonymous ids are prefixed; only mirror real Supabase UUIDs.
  if (!userId || userId.startsWith("$RCAnonymousID:")) {
    return json({ ok: true, skipped: "no resolvable user id" });
  }

  let premiumActive: boolean | null = null;
  if (ACTIVE_TYPES.has(type)) premiumActive = true;
  else if (INACTIVE_TYPES.has(type)) premiumActive = false;
  if (premiumActive === null) return json({ ok: true, skipped: `ignored type ${type}` });

  const expiresMs = Number(event.expiration_at_ms ?? 0);
  const expiresAt = expiresMs > 0 ? new Date(expiresMs).toISOString() : null;

  const { error } = await serviceClient()
    .from("entitlements")
    .upsert(
      {
        user_id: userId,
        premium_active: premiumActive,
        expires_at: expiresAt,
        updated_at: new Date().toISOString(),
      },
      { onConflict: "user_id" },
    );
  if (error) return json({ error: error.message }, 500);

  return json({ ok: true });
});
