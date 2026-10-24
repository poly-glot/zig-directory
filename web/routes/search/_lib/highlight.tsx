import type { ComponentChildren } from "preact";
import { contentWords } from "./targets.ts";

const REGEX_SPECIALS = /[.*+?^${}()|[\]\\]/g;

export function tokensFor(q: string): string[] {
  return contentWords(q);
}

// Wraps each whole-word occurrence of any token in <mark>; keeps the
// surrounding text intact. Returns a Preact children array so callers render
// directly.
export function highlight(
  text: string,
  tokens: string[],
): ComponentChildren {
  if (tokens.length === 0 || text.length === 0) return text;
  const safe = tokens.map((t) => t.replace(REGEX_SPECIALS, "\\$&"));
  const re = new RegExp(`\\b(${safe.join("|")})\\b`, "gi");
  const parts = text.split(re);
  return parts.map((p, i) => i % 2 === 1 ? <mark key={i}>{p}</mark> : p);
}
