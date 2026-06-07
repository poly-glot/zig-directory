/** True only for `http:`/`https:` URLs — the schemes safe to use as an href. */
export function isHttpUrl(v: string): boolean {
  try {
    const u = new URL(v);
    return u.protocol === "http:" || u.protocol === "https:";
  } catch {
    return false;
  }
}

/**
 * A link target safe to drop into `href`. Returns the URL only when it is
 * http(s); anything else (e.g. a stored `javascript:`/`data:` URL) collapses
 * to `#` so it can't execute. Guards against XSS via stored link URLs.
 */
export function safeHref(v: string): string {
  return isHttpUrl(v) ? v : "#";
}
