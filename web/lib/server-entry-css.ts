// Resolve the hashed filename of the production `fresh:server_entry` stylesheet.
//
// Why this exists: @fresh/plugin-vite links exactly three kinds of CSS into the
// built HTML — the global client-entry bundle, per-route chunk CSS, and
// per-island chunk CSS. Vite hoists every *shared* server-rendered style into
// the `fresh:server_entry` chunk: the app shell (_layout, SiteHeader,
// SiteFooter) plus components imported by both server routes and islands
// (components/admin/{Field,FormFooter,FormGrid}). That chunk's CSS is emitted
// and served but never <link>ed, so those styles are absent in prod (dev is
// unaffected — vite injects all CSS itself). Fresh exposes no API to register a
// global stylesheet, so `_app.tsx` links this file explicitly.
//
// The filename is content-hashed per build, so we read it from the server-side
// vite manifest (written on every `deno task build`) rather than hardcoding it.
// The read is cached after the first call; callers must gate on
// `import.meta.env.PROD` so dev never reads a stale built manifest.

let cached: string | null | undefined;

export function serverEntryCssHref(): string | null {
  if (cached !== undefined) return cached;
  try {
    // Resolve relative to this module's own directory (the built _fresh/server
    // dir), not the process cwd: that loads under both `deno serve` (cwd = web/)
    // and a `deno compile` binary, which extracts embedded files to a temp dir
    // that is never the cwd. `css[0]` is a build-relative path like
    // "assets/server-entry-*.css".
    const manifest = JSON.parse(
      Deno.readTextFileSync(`${import.meta.dirname}/.vite/manifest.json`),
    ) as Record<string, { css?: string[] }>;
    const css = manifest["fresh:server_entry"]?.css?.[0];
    cached = css ? `/${css}` : null;
  } catch (err) {
    // No manifest (e.g. never built) — degrade gracefully rather than 500.
    console.error("[server-entry-css] manifest read failed:", err);
    cached = null;
  }
  return cached;
}
