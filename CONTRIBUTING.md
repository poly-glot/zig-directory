# Contributing

Thanks for looking. This is a one-person project, so a small, focused change that comes with its test is the easiest
thing to review. If you plan something large, open an issue first and say what you want to change.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security problems privately, as
[SECURITY.md](SECURITY.md) describes. Contributions are under the [MIT licence](LICENSE).

## What you need

- **Linux.** The server uses epoll and `O_DIRECT`, so `zig build test` runs only on Linux. On macOS or Windows, work
  inside the [Dev Container](.devcontainer/devcontainer.json) or any Linux container that has Zig 0.16.0.
  The Dev Container bind-mounts `~/.claude` and will not start if it is missing, so run `mkdir -p ~/.claude` first.
- **Zig 0.16.0**, the version in `build.zig.zon`. The only Zig dependency is [zigstore](https://github.com/poly-glot/zigstore),
  which the build fetches.
- **Deno** for `web/`, **uv** for `mcp/` and **Node** for `e2e/`, if you touch those parts.

## Build

```bash
zig build                         # zig-out/bin/dmozdb only
zig build -Dtools=true            # also zig-out/bin/bench and zig-out/bin/dmoz_import
zig build -Doptimize=ReleaseSafe  # what production runs; every assertion stays on
```

The [README quickstart](README.md#quickstart) shows how to start the server on the sample store.

## The gates

A change is done when the gate for the part you touched passes. Continuous integration (`.github/workflows/ci.yaml`)
runs the same ones.

| You changed | Run | What it covers |
|-------------|-----|----------------|
| Zig (`src/`, `bench/`, `build.zig`) | `zig build test` | The unit and end-to-end tests, and the TigerStyle checker `src/tidy.zig` |
| Zig, plus the tools | `zig build -Dtools=true` | The bench client and the importer, which are not in the test graph |
| Web (`web/`) | `cd web && deno task check` | Formatting, lint and type-check |
| Web tests | `cd web && deno task test` | Needs the models: `deno run -A scripts/fetch-models.ts` first |
| MCP (`mcp/`) | `cd mcp && uv run ruff format --check . && uv run ruff check . && uv run mypy . && uv run pytest` | Format, lint, types and the invariants |
| Anything a person sees in the browser | `cd e2e && npx playwright test --project=chromium --reporter=line` | The Playwright suite |

Pass `--project=chromium` to Playwright. The `cold-boot` project stops `dmozdb` and takes the database away from the
other tests. Green specs also miss CSS and width problems, so open the page and look at it.

If you changed the wire protocol, regenerate the TypeScript client and commit it in the same commit:

```bash
zig build gen-client-ts
cd web && deno fmt lib/dmoz-protocol.gen.ts && deno check
```

Never edit `web/lib/dmoz-protocol.gen.ts` by hand. [`.claude/rules/protocol.md`](.claude/rules/protocol.md) has the
reasons.

## TigerStyle and the tidy checker

All Zig follows [TigerStyle](https://tigerstyle.dev). The rules, and where this repository departs from them, are in
[`.claude/rules/zig.md`](.claude/rules/zig.md). `src/tidy.zig` checks the mechanical half: line and function length,
naming, bounded loops, recursion, `usize` fields and banned patterns. It runs inside `zig build test`. To run only
that, which takes about a second and works on any host with Zig 0.16.0:

```bash
zig test src/tidy.zig
```

On macOS, `zig build test -Dtarget=aarch64-linux-musl` compiles the whole test binary for Linux in about ten seconds.
The only failure that is acceptable there is the final "unable to execute" step.

Format with `zig fmt src/ bench/` before you commit. The other rule files are in [`.claude/rules/`](.claude/rules/):
[`common.md`](.claude/rules/common.md), [`web.md`](.claude/rules/web.md), [`mcp.md`](.claude/rules/mcp.md) and
[`architecture.md`](.claude/rules/architecture.md).

## Commits and pull requests

- One logical change per commit, in the Conventional Commits style that the history uses: `fix(subtree): ...`,
  `feat(search): ...`, `docs(readme): ...`, `refactor(zig): ...`. Keep the subject short.
- The body says what was wrong or missing and why this is the smallest change that fixes it. The diff already shows
  what changed.
- Fix the cause, not the place where it shows up. If you ship a workaround, say so and name the real fix.
- Every bug fix comes with a test that fails without the fix. Run the test against the unfixed code and see it fail.
- The pull request template carries the gates as a checklist. Fill it in.

If you use an AI assistant, the same rules apply. The repository already carries its rules for one, and a change from
an assistant is held to the same gates as any other.

## Changing the code

### Adding a new binary op

1. Add the op code to the `Op` enum in `src/binary_protocol.zig`
2. Add a case to the `dispatch` switch and write the handler (reuse `GetHandlerType`, `DeleteHandlerType`,
   `TextUpdateHandlerType` or `write_row_list` where they fit)
3. Implement the business logic in `src/operations/`; a mutation gets a `compute_*_change_set` function and, if it needs a
   new effect, a `changeset.zig` variant plus its `src/apply/` handler
4. Add tests next to the handler and, for a workflow, in `src/e2e_test.zig`
5. Run `zig build gen-client-ts` and commit the regenerated `web/lib/dmoz-protocol.gen.ts` in the same commit

To extend an existing op without breaking older callers, append optional trailing bytes (the status filter and
`after_id` on the list ops do this) rather than forking a new op number.

### Adding a new index

1. Add one entry to the `.indexes` tuple of the `zigstore.schema(...)` literal in `src/directory.zig`; add its name to
   `.memtable_indexes` if writes should be buffered
2. Add the `tree()` (and `memtable()`) accessor on `Directory`
3. Write to it from the relevant `src/apply/` handler and read it from `src/operations/`
4. The page-0 header gains a root/count slot for the new index automatically; the engine validates `magic` and
   `format_version` on open, so bump `format_version` when an existing `store.dat` must be rejected rather than opened

### Code style

All Zig follows [TigerStyle](https://tigerstyle.dev); the repo's rule file is `.claude/rules/zig.md`
and `src/tidy.zig` enforces the mechanical part inside `zig build test` (also runnable alone with
`zig test src/tidy.zig`).

- `snake_case` functions, variables, files and constants with the qualifier last (`subtree_offset_max`);
  `PascalCase` types; a type-returning function ends in `Type`
- Assert arguments, return values and invariants (`const assert = std.debug.assert;`), two per
  function on average; bytes from the network, the WAL or the disk are validated with errors, never asserted
- Every loop has a declared bound, no recursion, no `while (true)`; `u32`/`u64` for domain values,
  `usize` only at the slice boundary
- Functions at most 70 lines, lines at most 100 columns, `zig fmt` clean
- Memory is allocated at startup; the request path works in preallocated buffers
- Comments say why (and tests say how); they are sentences with a capital letter and a full stop
- Use `std.log.scoped(.module_name)` for logging (not `std.debug.print`)
- Use `comptime` assertions to validate struct sizes and alignment
- Prefix padding/reserved fields with `_`
- Use comptime generics to eliminate handler duplication
