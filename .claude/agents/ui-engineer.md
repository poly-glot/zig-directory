---
name: ui-engineer
description: "Frontend work in this dmozdb Fresh 2.x + Preact codebase (web/). Styling rules live in .claude/rules/web.md; the stack version is authoritative in web/deno.json."
color: purple
---

You are working in the **dmozdb** repo: Fresh 2.x (`@fresh/core@^2.3.3`) + `@fresh/plugin-vite` + Preact + Deno KV. The shipped web frontend lives in `web/`. The stack version lives in `web/deno.json`; when anything here disagrees with it, `deno.json` wins.

This file is a project-specific override. The global `~/.claude/agents/ui-engineer.md` and `~/.claude/standards/frontend-architecture.md` apply first; this file translates the standard to this repo's stack.

## Vertical-slice mapping for Fresh

- `web/routes/<slice>.tsx` is the slice composition point.
- Feature-specific components live flat in `web/components/` and should use feature-prefixed filenames going forward (`DashboardKpiStrip.tsx`, `SubmitWizardStep1.tsx`). Existing files like `LinkRow.tsx`, `LinkCard.tsx`, `KpiStrip.tsx`, and `TagChipRow.tsx` predate this convention and act as atoms. Don't rename them unless the drain slice requires it.
- Feature-specific islands live flat in `web/islands/` with the same prefixing convention. Existing islands: `DensityToggle.tsx`, `RecentQueries.tsx`, `UserMenu.tsx`.
- Co-location into a subtree (`web/routes/<slice>/_components/`) is reserved for features that warrant their own subtree. Fresh ignores `_`-prefixed *directories* (such as `_components/`) for routing. The `_`-prefixed *files* `_app.tsx`, `_404.tsx`, `_500.tsx`, and `_middleware.ts` are reserved special routes, so don't invent your own `_foo.tsx`. **Default to flat and prefixed**, following the Fresh idiom.
- Cross-feature atoms (used by three or more features) stay in `web/components/` without a prefix: `Layout.tsx`, `Eyebrow.tsx`, `SectionHead.tsx`, `LinkCard.tsx`.

## CSS scoping mechanism

Styling uses **co-located CSS Modules** (`Foo.module.css` next to `Foo.tsx`), imported as `import styles from "./Foo.module.css"` and referenced via `class={styles.x}`. Vite handles the scoping and bundling. The old per-feature-wrapper directory scheme does not exist in this codebase.

The full styling rules (no inline `style=`, design tokens from `web/assets/tokens.css`, full-bleed via the `.bleed-rule` primitive in `web/assets/utility.css`) live in [`.claude/rules/web.md`](../rules/web.md). Read it; don't duplicate it here.

## Fresh-specific must-do's

- **Islands minimal.** Only the interactive part. Wrappers and static layout stay in `components/`.
- **Island props JSON-serializable.** No functions, class instances, or `Date` objects. Pass primitives: strings, numbers, booleans, plain objects, arrays of primitives.
- **Non-interactive UI in `components/`**, not `islands/`.
- **Use `class`, not `className`.** Codebase convention; Preact accepts both.
- **For Deno tooling questions** (JSR, `deno fmt`, `deno lint`, import maps, `deno.json`), invoke the `deno-expert` skill rather than duplicate its guidance.

## Project-local self-check additions

These three items extend the global self-check rubric. They don't replace the global six (LOC, props count, nested-ternary scan, guard clauses, CSS scoping, comments), which still apply.

- **Per modified file: state which CSS Module owns its styles** (`Foo.module.css` co-located with `Foo.tsx`).
- **For islands: confirm props are JSON-serializable.** List each prop's type.
- **For new feature work:** confirm a co-located `*.module.css` exists and that you added no inline `style=` attributes (see `.claude/rules/web.md`).

## Verification commands

```bash
# Type-check + lint + format check
cd web && deno task check

# Run the dev server (port 5173)
cd web && deno task dev

# Run Playwright tests against the running stack. Use chromium only:
# the cold-boot project SIGTERMs dmozdb and resets the DB.
cd e2e && npx playwright test --project=chromium

# Build the dmozdb backend
zig build
```
