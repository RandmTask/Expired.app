// Provider routing for the thin AI forwarder.
//
// The CLIENT builds the exact provider request body (it already knows each
// provider's shape) and sends { provider, model, body }. The proxy injects the
// server-held key and forwards. This keeps the Swift response-parsing untouched —
// only the transport + key handling moves server-side.

export type ProviderID = "openai" | "claude" | "gemini" | "deepseek";

export interface ForwardTarget {
  url: string;
  headers: Record<string, string>;
}

/** Returns null if the provider is unknown or its key secret is missing. */
export function chatTarget(provider: ProviderID, model: string): ForwardTarget | null {
  switch (provider) {
    case "openai": {
      const key = Deno.env.get("OPENAI_API_KEY");
      if (!key) return null;
      return {
        url: "https://api.openai.com/v1/chat/completions",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      };
    }
    case "deepseek": {
      const key = Deno.env.get("DEEPSEEK_API_KEY");
      if (!key) return null;
      return {
        url: "https://api.deepseek.com/chat/completions",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      };
    }
    case "claude": {
      const key = Deno.env.get("ANTHROPIC_API_KEY");
      if (!key) return null;
      return {
        url: "https://api.anthropic.com/v1/messages",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": key,
          "anthropic-version": "2023-06-01",
        },
      };
    }
    case "gemini": {
      const key = Deno.env.get("GEMINI_API_KEY");
      if (!key || !model) return null;
      return {
        url: `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`,
        headers: { "Content-Type": "application/json" },
      };
    }
    default:
      return null;
  }
}

/** Models-list endpoint per provider (GET). Mirrors ScreenshotAIModelService. */
export function modelsTarget(provider: ProviderID): ForwardTarget | null {
  switch (provider) {
    case "openai": {
      const key = Deno.env.get("OPENAI_API_KEY");
      if (!key) return null;
      return { url: "https://api.openai.com/v1/models", headers: { Authorization: `Bearer ${key}` } };
    }
    case "deepseek": {
      const key = Deno.env.get("DEEPSEEK_API_KEY");
      if (!key) return null;
      return { url: "https://api.deepseek.com/models", headers: { Authorization: `Bearer ${key}` } };
    }
    case "claude": {
      const key = Deno.env.get("ANTHROPIC_API_KEY");
      if (!key) return null;
      return {
        url: "https://api.anthropic.com/v1/models?limit=100",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01" },
      };
    }
    case "gemini": {
      const key = Deno.env.get("GEMINI_API_KEY");
      if (!key) return null;
      return {
        url: `https://generativelanguage.googleapis.com/v1beta/models?key=${key}&pageSize=200`,
        headers: {},
      };
    }
    default:
      return null;
  }
}
