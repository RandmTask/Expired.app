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

// ---------------------------------------------------------------------------
// Cascade support: the proxy tries providers in order, so it must build each
// provider's request body itself (the client used to do this per-provider;
// now the client sends one generic prompt/image pair for whichever provider
// the server ends up trying). Ported from ScreenshotImportAnalyzer.swift —
// keep both in sync if a provider's request shape changes.
// ---------------------------------------------------------------------------

/** Providers whose models can read the screenshot directly. Text-only
 * providers (DeepSeek) get OCR lines instead — see `textPrompt` below. */
export const VISION_CAPABLE: ReadonlySet<ProviderID> = new Set(["openai", "claude", "gemini"]);

/** Same fallback defaults as `ScreenshotAIProvider.defaultModelID` in Swift.
 * Only used if the `ai_model_<provider>` row is missing from app_config. */
export const DEFAULT_MODEL: Record<ProviderID, string> = {
  openai: "gpt-4.1-mini",
  deepseek: "deepseek-chat",
  claude: "claude-3-5-haiku-latest",
  gemini: "gemini-2.5-flash",
};

export interface ImagePayload {
  mime: string;
  base64: string;
}

/** Best-effort token count from each provider's own usage/metadata field, so
 * `usage.token_estimate` reflects real spend instead of staying permanently 0. */
export function extractTokenCount(provider: ProviderID, raw: unknown): number {
  const obj = raw as Record<string, unknown> | null;
  if (!obj) return 0;
  switch (provider) {
    case "openai":
    case "deepseek": {
      const usage = obj.usage as Record<string, unknown> | undefined;
      return Number(usage?.total_tokens ?? 0);
    }
    case "claude": {
      const usage = obj.usage as Record<string, unknown> | undefined;
      return Number(usage?.input_tokens ?? 0) + Number(usage?.output_tokens ?? 0);
    }
    case "gemini": {
      const usage = obj.usageMetadata as Record<string, unknown> | undefined;
      return Number(usage?.totalTokenCount ?? 0);
    }
    default:
      return 0;
  }
}

/** Builds the provider-specific chat-completions/messages body. `visionPrompt`
 * + `image` are used for vision-capable providers; `textPrompt` (already
 * carries the OCR lines) is used otherwise. */
export function buildRequestBody(
  provider: ProviderID,
  model: string,
  args: { visionPrompt: string; textPrompt: string; image?: ImagePayload },
): unknown {
  const useVision = VISION_CAPABLE.has(provider) && !!args.image;

  switch (provider) {
    case "openai":
      return useVision
        ? {
          model,
          temperature: 0,
          messages: [
            { role: "system", content: "You extract subscription data and return JSON only." },
            { role: "user", content: [
              { type: "text", text: args.visionPrompt },
              { type: "image_url", image_url: { url: `data:${args.image!.mime};base64,${args.image!.base64}` } },
            ] },
          ],
        }
        : {
          model,
          temperature: 0,
          messages: [
            { role: "system", content: "You extract subscription data and return JSON only." },
            { role: "user", content: args.textPrompt },
          ],
        };
    case "claude":
      return {
        model,
        max_tokens: 1200,
        temperature: 0,
        messages: [{ role: "user", content: useVision
          ? [
            { type: "text", text: args.visionPrompt },
            { type: "image", source: { type: "base64", media_type: args.image!.mime, data: args.image!.base64 } },
          ]
          : args.textPrompt }],
      };
    case "gemini":
      return {
        contents: [{ parts: useVision
          ? [
            { text: args.visionPrompt },
            { inline_data: { mime_type: args.image!.mime, data: args.image!.base64 } },
          ]
          : [{ text: args.textPrompt }] }],
        generationConfig: { temperature: 0 },
      };
    case "deepseek":
      return {
        model,
        temperature: 0,
        messages: [
          { role: "system", content: "You extract subscription data and return JSON only." },
          { role: "user", content: args.textPrompt },
        ],
      };
  }
}
