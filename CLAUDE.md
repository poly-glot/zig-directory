# dmozdb / zig-directory: Project Contract

A DMOZ-style web directory: a Zig backend database (`dmozdb`, binary protocol, in `src/`) behind a Deno/Fresh web frontend (in `web/`). This file loads every session. The enforceable conventions live in [`.claude/rules/`](.claude/rules/). Read them.

## Core principles

- **Simplicity first.** The smallest change that correctly solves the problem wins. Justify added machinery against the current scale, not a hypothetical one.
- **No laziness, no band-aids.** Fix root causes, not symptoms. If you patch a symptom to unblock, say so and name the real fix.
- **Declarative, testable, maintainable.** Senior-level code: clear names, focused units, no clever one-liners, behavior covered by tests.

## Verify before "done" (non-negotiable)

A change is done only when the relevant gate passes and, for anything user-visible, you have confirmed the rendered result against the running app.

- Zig change: `zig build test` (exit 0).
- Web change: `cd web && deno task check` (fmt, lint, type-check).
- User-visible web change: also `curl` the affected route and run Playwright with `cd e2e && npx playwright test --project=chromium --reporter=line`. Pass `--project=chromium` because the `cold-boot` project SIGTERMs `dmozdb` and tears the DB out from under the other tests. Green specs miss CSS and width regressions, so look at the page.
- Cite the evidence in your summary. The Stop hook runs the scoped gate and blocks turn-end on failure. The visual check is yours to do.

The recurring failure: you verify a narrow probe, declare done, and then the user opens the page and it is still broken.

## Runtime facts

- **`DMOZDB_HOST=127.0.0.1`** for the Deno app. Without it, IPv6 resolution gives "Directory service unavailable".
- **Restart `dmozdb` after every `zig build`.** vite/chromium can OOM-kill it. Launch it in the background. The post-build hook reminds you.
- **Never hand-edit `web/lib/dmoz-protocol.gen.ts`.** Regenerate it via `zig build gen-client-ts` (see [protocol.md](.claude/rules/protocol.md)).

## Source of truth

The web stack version lives in **`web/deno.json`**. Docs and rules describe it; they never override it. When a doc disagrees with `deno.json`, fix the doc.

## Knowledge hierarchy

- **Durable canon:** this file and `.claude/rules/`, version-controlled and inherited by subagents.
- **Session and project state:** `memory.md`, `docs/superpowers/` specs and plans.
- **Scratch:** home-dir auto-memory. Capture a lesson there, then *promote* it into a rule here. It isn't shared, so don't rely on it.

## Communication

When debugging stalls past two or three cycles, stop narrating ruled-out hypotheses. Give the user an **issue / scope / fix** snapshot they can act on, then execute.

## Rules index

- [`common.md`](.claude/rules/common.md): cross-cutting (trailing newline, root-cause over band-aid, no commented-out code).
- [`zig.md`](.claude/rules/zig.md): Zig backend (cleanup, allocators, errors, comptime, comment carve-out).
- [`web.md`](.claude/rules/web.md): Fresh/Preact (islands, no inline styles, `.bleed-rule`, tokens).
- [`protocol.md`](.claude/rules/protocol.md): binary protocol and generated client.
- [`architecture.md`](.claude/rules/architecture.md): server owns hierarchy, smallest-change and migration discipline.
