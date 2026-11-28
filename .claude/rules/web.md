# Web Conventions (`web/`, Fresh 2.x + Preact)

The stack version lives in **`web/deno.json`**: currently `@fresh/core@^2.3.3`, `@fresh/plugin-vite`, and Vite. Co-located CSS Modules (`*.module.css`) are the styling mechanism. There is no `web/static/css/` feature-wrapper scheme. When this file disagrees with `web/deno.json`, `deno.json` wins, so fix this file.

- DO: **Islands hold only interactivity.** Interactive bits go in `web/islands/`; static layout and markup stay in `web/components/` and route files. Keep islands minimal.
- DO: **Island props are JSON-serializable.** Strings, numbers, booleans, plain objects, arrays. No functions, class instances, or `Date`s across the island boundary.
- DO: **Use `class`, not `className`.** Codebase convention; Preact accepts both.
- DO: **Route handlers follow the existing `createDefine`/`PageProps` shape.** Don't hand-roll context plumbing.

## Styling

- NEVER: **Inline `style=`.** No `style="..."` or `style={{…}}` in any `.tsx`. Lift the rule into the co-located `*.module.css` and reference it via `class={styles.x}`. The web-guard hook blocks this. Touching a file with a pre-existing inline style makes it yours to clean up; "it was already there" is not an excuse.
- DO: **Design tokens over hardcoded values.** Use the custom properties in `web/assets/tokens.css` (`--ink`, `--rule`, `--paper`, the spacing scale) instead of literal colors or sizes.
- NEVER: **Raw full-bleed geometry.** Don't write `width: 100vw` with `position:absolute; left:50%; transform:translateX(-50%)` for a viewport-wide rule or strip. Use the `.bleed-rule` primitive in `web/assets/utility.css`: `class="… bleed-rule" data-bleed="bottom|top|both"`. If `.bleed-rule` doesn't cover your case, extend the primitive rather than re-derive the raw block. The web-guard hook warns on this.

## Comments

- DO: **Keep comments that explain server/client rendering boundaries, island hydration caveats, and accessibility rationale.**
- NEVER: **Write JSDoc that restates a typed prop's default**, like `/** @default 10 */` over `pageSize = 10`.

## Verify

Run `cd web && deno task check` (fmt check, lint, type-check). For any user-visible change, `curl` the route and run the Playwright suite. Green specs don't catch CSS or visual-width changes, so confirm the rendered result yourself. See the verify section of the root [CLAUDE.md](../../CLAUDE.md).

## Request guards (`web/main.ts`)

Four root pieces run around every route. Their reasons live here, not in the code.

- DO: **Keep the body cap in `lib/body-limit.ts`.** `REQUEST_BODY_MAX_BYTES` is 64 KiB: the largest legitimate body is a form of a few hundred bytes or a bulk-action list of at most 200 ids. Over it answers 413 before a route calls `formData()` or `json()`. A body with no `Content-Length` is counted, not trusted.
- DO: **Set browser headers only in `lib/security-headers.ts`.** The CSP is applied in production builds only, because the vite dev server injects un-nonced styles. It uses the nonce Fresh renders into its inline scripts and styles, so there is no `unsafe-inline`. It deliberately sets no `form-action`: the OAuth consent form posts to this origin and then redirects to the client's `redirect_uri`, and Chromium enforces `form-action` on that redirect. Headers are rebuilt onto a new `Response` because `Response.redirect()` headers are immutable.
- NEVER: **Add `style=` or an inline `<script>` to a page.** Both are blocked in production by that policy.
- DO: **List calls default to approved links.** The `list*` methods of `DmozClient` send `approved` unless the caller passes `status`, and admin, backfill and dashboard callers opt out with `"any"` or an explicit status. A new public list call is therefore safe by default.
- DO: **Keep `PublicApp` as the app class.** Fresh decodes route params with `decodeURI` before any middleware runs, so `/category/%FF` throws a `URIError` out of `handler()`. `PublicApp` turns that into a 400 with the security headers. Reject a bad id or cursor with a 400 and its reason; never clamp or coerce it (`parseEntityId`, `pageSize` and `afterCursor` return `undefined` for that).
