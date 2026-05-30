export function formField(form: FormData, name: string): string {
  return form.get(name)?.toString()?.trim() ?? "";
}

export function truncateText(text: string, max: number): string {
  return text.length > max ? text.slice(0, max) + "..." : text;
}

/** URL-safe slug from a display name: lowercase, non-alphanumerics → single
 * hyphen, trimmed. Used to default a category slug when the field is blank. */
export function slugify(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
}

export function pluralize(
  count: number,
  singular: string,
  plural?: string,
): string {
  return `${count} ${count === 1 ? singular : (plural ?? singular + "s")}`;
}

export function adminRedirect(path: string, message: string): Response {
  const sep = path.includes("?") ? "&" : "?";
  return new Response(null, {
    status: 303,
    headers: {
      Location: `${path}${sep}message=${encodeURIComponent(message)}`,
    },
  });
}

/**
 * Stable 32-bit non-zero fold of a UUID v4 string into the u64
 * `submitter_id` slot on the Zig Link record. Same input always
 * produces the same output, so /dashboard's "my submissions" lookup
 * matches what /submit recorded. Slice 4b will replace this with a
 * sequential KV-backed id once we add a backend index.
 */
export function userIdToSubmitterId(userId: string): number {
  let hi = 0xdeadbeef ^ 0;
  let lo = 0x41c6ce57 ^ 0;
  for (let i = 0; i < userId.length; i++) {
    const ch = userId.charCodeAt(i);
    hi = Math.imul(hi ^ ch, 2654435761);
    lo = Math.imul(lo ^ ch, 1597334677);
  }
  hi = Math.imul(hi ^ (hi >>> 16), 2246822507);
  lo = Math.imul(lo ^ (lo >>> 13), 3266489909);
  const n = ((hi >>> 0) * 0x10000 + (lo >>> 0)) >>> 0;
  return n === 0 ? 1 : n;
}
