// Plain global CSS — tokens, atoms, utility classes. Loaded once for every
// page; intentionally global, not module-scoped.
import "./assets/tokens.css";
import "./assets/base.css";
import "./assets/typography.css";
import "./assets/utility.css";
import "./assets/buttons.css";

// Eagerly import CSS Modules so their styles reach the browser. The glob differs
// by build mode — DEV needs islands IN, PROD needs them OUT — so we branch on the
// statically-replaced import.meta.env.DEV; the bundler keeps only one literal
// glob call per build.
//
// PROD ("!./islands/**"): non-island module CSS is funnelled into the client-entry
// bundle, which Fresh links on every page. A non-island component has exactly one
// client-side importer (this file), so vite keeps its CSS in the client-entry
// chunk; without this glob those styles live only in chunks Fresh never links (the
// fresh:server_entry chunk, or per-component shared chunks) and are absent from the
// built page. Islands are EXCLUDED because an island is its own client entry:
// globbing its CSS here would make the same *.module.css an input to two entries,
// so vite hoists it into a shared chunk and EMPTIES the island chunk's `css` array
// in the manifest — then Fresh's island-CSS injection has nothing to link and every
// island renders unstyled. The same hoisting hits non-island components that islands
// import (components/admin/{Field,FormFooter,FormGrid}); those land in the
// server_entry stylesheet, which routes/_app.tsx links — see lib/server-entry-css.ts.
//
// DEV (all modules, islands included): vite serves CSS via JS injection and the
// per-chunk hoisting above doesn't apply, so the only job here is to keep the dev
// SSR collector from dropping modules reached only through a transitive
// component-from-component or island import chain (Fresh 2 + @fresh/plugin-vite
// drops those after rapid HMR / on a cold route). Excluding islands here leaves
// every island unstyled in dev, so dev must glob them too.
//
// The returned map MUST be referenced: CSS-module JS is side-effect-free, so a
// bare glob whose result is unused gets tree-shaken out of the production build,
// taking these styles with it. Assigning to a retained global keeps the imports —
// and their extracted CSS — alive. Module-class hashes are path-derived and
// identical across the client and SSR builds, so the SSR'd class names resolve.
const cssModules = import.meta.env.DEV
  ? import.meta.glob("./**/*.module.css", { eager: true })
  : import.meta.glob(["./**/*.module.css", "!./islands/**"], { eager: true });
(globalThis as Record<string, unknown>).__freshCssModules = cssModules;
