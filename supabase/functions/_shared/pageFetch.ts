// Server-side webpage fetch + text extraction for the AI URL-lookup route
// (R2 Phase 2 — "Read Page with AI"). Trusts no part of a user-supplied URL:
// scheme, host, and every redirect hop are re-validated before any bytes are
// requested.
//
// Caveat: DNS-rebinding (a public domain resolving to a private IP at request
// time) is not fully closed — `Deno.resolveDns` support varies by edge runtime
// and this guard degrades gracefully when it's unavailable. Layer 1 (reject IP
// literals + known-internal hostnames) and layer 3 (https-only, redirect cap,
// size/time limits) hold regardless of runtime support.

const MAX_REDIRECTS = 3;
const MAX_BYTES = 500_000;
const FETCH_TIMEOUT_MS = 8_000;

const BLOCKED_HOST_SUFFIXES = [".local", ".internal", ".localhost"];
const BLOCKED_HOSTNAMES = new Set(["localhost", "metadata.google.internal"]);

export class PageFetchError extends Error {}

function isIPLiteral(host: string): boolean {
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return true; // IPv4
  if (host.includes(":")) return true; // IPv6 (URL never gives brackets in .hostname)
  return false;
}

function isPrivateIPv4(ip: string): boolean {
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((p) => Number.isNaN(p))) return false;
  const [a, b] = parts;
  if (a === 10) return true;
  if (a === 127) return true;
  if (a === 169 && b === 254) return true; // link-local, incl. cloud metadata 169.254.169.254
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 0) return true;
  return false;
}

function isPrivateIPv6(ip: string): boolean {
  const lower = ip.toLowerCase();
  return lower === "::1" || lower.startsWith("fc") || lower.startsWith("fd") || lower.startsWith("fe80");
}

async function assertHostAllowed(host: string): Promise<void> {
  const bare = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (BLOCKED_HOSTNAMES.has(bare)) throw new PageFetchError("blocked_host");
  if (BLOCKED_HOST_SUFFIXES.some((suffix) => bare.endsWith(suffix))) throw new PageFetchError("blocked_host");
  if (isIPLiteral(bare)) throw new PageFetchError("ip_literal_not_allowed");

  // Best-effort extra layer: only runs where the edge runtime supports DNS
  // resolution. Skipped (not failed open or closed) when unsupported — layers
  // above already reject the obvious cases.
  const resolveDns = (Deno as unknown as { resolveDns?: typeof Deno.resolveDns }).resolveDns;
  if (typeof resolveDns !== "function") return;
  try {
    const [a, aaaa] = await Promise.all([
      resolveDns(bare, "A").catch(() => [] as string[]),
      resolveDns(bare, "AAAA").catch(() => [] as string[]),
    ]);
    for (const ip of a) if (isPrivateIPv4(ip)) throw new PageFetchError("resolved_to_private_ip");
    for (const ip of aaaa) if (isPrivateIPv6(ip)) throw new PageFetchError("resolved_to_private_ip");
  } catch (e) {
    if (e instanceof PageFetchError) throw e;
    // DNS lookup itself failing (permission, unsupported record type, etc.) —
    // don't block the request on an environment quirk.
  }
}

export interface FetchedPage {
  title: string;
  description: string;
  text: string;
}

export async function fetchPageText(rawUrl: string): Promise<FetchedPage> {
  let current: string;
  try {
    current = new URL(rawUrl).toString();
  } catch {
    throw new PageFetchError("invalid_url");
  }

  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    const url = new URL(current);
    if (url.protocol !== "https:") throw new PageFetchError("scheme_not_allowed");
    await assertHostAllowed(url.hostname);

    let response: Response;
    try {
      response = await fetch(url.toString(), {
        redirect: "manual",
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
        headers: { "User-Agent": "Mozilla/5.0 (compatible; ExpiredApp/1.0)" },
      });
    } catch (e) {
      throw new PageFetchError(`fetch_failed: ${e}`);
    }

    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      if (!location) throw new PageFetchError("redirect_without_location");
      current = new URL(location, url).toString();
      continue;
    }

    if (!response.ok) throw new PageFetchError(`http_${response.status}`);

    const contentType = response.headers.get("content-type") ?? "";
    if (!contentType.includes("text/html") && !contentType.includes("text/plain")) {
      throw new PageFetchError("unsupported_content_type");
    }

    const html = await readBodyCapped(response, MAX_BYTES);
    return extractPageText(html);
  }
  throw new PageFetchError("too_many_redirects");
}

async function readBodyCapped(response: Response, maxBytes: number): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) throw new PageFetchError("empty_body");
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value) {
      total += value.length;
      chunks.push(value);
      if (total >= maxBytes) {
        await reader.cancel();
        break;
      }
    }
  }
  const combined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    combined.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder().decode(combined);
}

function extractPageText(html: string): FetchedPage {
  const titleMatch = html.match(/<title[^>]*>([^<]*)<\/title>/i);
  const descMatch = html.match(/<meta[^>]+name=["']description["'][^>]+content=["']([^"']*)["']/i);

  const strippedText = html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&[a-z]+;/gi, " ")
    .replace(/\s+/g, " ")
    .trim();

  return {
    title: (titleMatch?.[1] ?? "").trim(),
    description: (descMatch?.[1] ?? "").trim(),
    text: strippedText.slice(0, 6000),
  };
}
