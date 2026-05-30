// Shared formatters used across routes and components. Live here so the
// "Aug 12, 2026" / "Aug 2026" / "2 days ago" rendering stays identical
// in every slice — change once, applied everywhere.

export function pad2(n: number): string {
  return n.toString().padStart(2, "0");
}

export function pad7(n: number): string {
  return n.toString().padStart(7, "0");
}

// "May 10, 2026" — used for indexed/added/reviewed timestamps.
// Returns undefined for the zero-Date sentinel so callers can omit the row.
export function formatLongDate(d: Date): string | undefined {
  if (d.getTime() <= 0) return undefined;
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "2-digit",
    year: "numeric",
  });
}

// Same shape as formatLongDate but returns "—" instead of undefined.
// Use when the cell must always render a string.
export function formatLongDateOrDash(d: Date): string {
  return formatLongDate(d) ?? "—";
}

// "May 2026" — used for "member since" style cells.
export function formatMonthYear(d: Date | string | number): string {
  const date = d instanceof Date ? d : new Date(d);
  return date.toLocaleDateString("en-US", { month: "short", year: "numeric" });
}

// "2s ago" / "5m ago" / "3h ago" / "12d ago" / "never". Used by admin/integrity.
export function relativeTime(unixSec: number): string {
  if (unixSec <= 0) return "never";
  const now = Math.floor(Date.now() / 1000);
  const diff = now - unixSec;
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

// Best-effort hostname extraction; falls back to the raw URL when the
// input doesn't parse (still happens on legacy DMOZ data).
export function safeHostname(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}

// Comma-separated tag string → trimmed, non-empty array.
export function parseTags(raw: string): string[] {
  return raw.split(",").map((t) => t.trim()).filter((t) => t.length > 0);
}

// "—" placeholder for empty record fields. Keeps cells width-stable.
export function dashOrValue(s: string): string {
  return s.length > 0 ? s : "—";
}

// Word-wise truncation that appends "…" when the input exceeds max.
// Used by search results to keep cards a uniform height.
export function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  return text.slice(0, max).trimEnd() + "…";
}

/**
 * Humanise a DMOZ-canonical category name for display.
 * Stored names follow the legacy ODP convention of underscores for
 * word separators ("Emergency_Preparation") so they're URL-safe and
 * round-trip with the slug. Reading them in the UI as separated words
 * is friendlier; storage and slug stay untouched.
 */
export function formatCategoryName(name: string): string {
  return name.replace(/_/g, " ");
}
