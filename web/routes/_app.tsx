import { define } from "../utils.ts";
import { serverEntryCssHref } from "../lib/server-entry-css.ts";

const SITE = "DMOZSTYLE";
const DEFAULT_TITLE = `${SITE} — a hand-curated directory of the open web`;
const DEFAULT_DESCRIPTION =
  "A hand-curated, editor-vetted directory of the open web — categories, " +
  "links, and search served from a custom Zig database.";

export default define.page(function App({ Component, state }) {
  // In production, vite hoists all shared server-rendered CSS (app shell +
  // components shared by routes and islands) into the server_entry chunk, which
  // Fresh serves but never links. Link it here. In dev, vite injects CSS itself,
  // so this is skipped — and gating on PROD keeps dev from reading a stale
  // built manifest. See lib/server-entry-css.ts.
  const sharedCss = import.meta.env.PROD ? serverEntryCssHref() : null;
  // Per-page title/description: each route sets state.title (and optionally
  // state.description) in its handler; we add the brand and fall back to the
  // site default. The home route leaves state.title unset to use DEFAULT_TITLE.
  const title = state.title ? `${state.title} · ${SITE}` : DEFAULT_TITLE;
  const description = state.description ?? DEFAULT_DESCRIPTION;
  return (
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>{title}</title>
        <meta name="description" content={description} />
        {sharedCss ? <link rel="stylesheet" href={sharedCss} /> : null}
      </head>
      <body>
        <Component />
      </body>
    </html>
  );
});
