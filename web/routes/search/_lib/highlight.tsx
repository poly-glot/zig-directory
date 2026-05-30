import type { ComponentChildren } from "preact";

const REGEX_SPECIALS = /[.*+?^${}()|[\]\\]/g;
const TOKEN_SPLIT = /\W+/;

export function tokensFor(q: string): string[] {
  return q.toLowerCase().split(TOKEN_SPLIT).filter((t) => t.length >= 2);
}

// Wraps each occurrence of any token in <mark>; keeps the surrounding text
// intact. Returns a Preact children array so callers render directly.
export function highlight(
  text: string,
  tokens: string[],
): ComponentChildren {
  if (tokens.length === 0 || text.length === 0) return text;
  const safe = tokens.map((t) => t.replace(REGEX_SPECIALS, "\\$&"));
  const re = new RegExp(`(${safe.join("|")})`, "gi");
  const parts = text.split(re);
  return parts.map((p, i) => i % 2 === 1 ? <mark key={i}>{p}</mark> : p);
}
