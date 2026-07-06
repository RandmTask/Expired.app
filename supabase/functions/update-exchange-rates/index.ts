// update-exchange-rates — fetches all USD-based rates from Frankfurter (ECB-backed,
// free, no key required) and upserts them into the `exchange_rates` table.
//
// Called on a daily schedule via the Supabase dashboard (Functions → Schedule).
// verify_jwt = false (see config.toml) because this is a server-to-server call, not
// a user session. The service role key in SUPABASE_SERVICE_ROLE_KEY lets it bypass RLS.

import { createClient } from "jsr:@supabase/supabase-js@2";

const FRANKFURTER_URL = "https://api.frankfurter.app/latest?base=USD";

Deno.serve(async (_req) => {
  try {
    // Fetch all rates relative to 1 USD from the ECB-backed Frankfurter API.
    const resp = await fetch(FRANKFURTER_URL, {
      headers: { "Accept": "application/json" },
    });

    if (!resp.ok) {
      const body = await resp.text();
      console.error("[update-exchange-rates] Frankfurter error:", resp.status, body);
      return new Response(
        JSON.stringify({ error: "Frankfurter fetch failed", status: resp.status }),
        { status: 502, headers: { "Content-Type": "application/json" } },
      );
    }

    const data = await resp.json() as { base: string; rates: Record<string, number> };
    const ratesFromFrankfurter = data.rates;
    ratesFromFrankfurter["USD"] = 1.0; // Frankfurter omits the base currency itself

    const rows = Object.entries(ratesFromFrankfurter).map(([code, rate]) => ({
      currency_code: code,
      rate_vs_usd: rate,
      updated_at: new Date().toISOString(),
    }));

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { error } = await supabase
      .from("exchange_rates")
      .upsert(rows, { onConflict: "currency_code" });

    if (error) {
      console.error("[update-exchange-rates] Supabase upsert error:", error);
      return new Response(
        JSON.stringify({ error: error.message }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    console.log(`[update-exchange-rates] Updated ${rows.length} rates (base: USD)`);
    return new Response(
      JSON.stringify({ updated: rows.length, base: "USD", date: data.rates }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("[update-exchange-rates] Unexpected error:", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
