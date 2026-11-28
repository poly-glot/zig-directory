## What changed and why

<!-- What was wrong or missing, and why this is the smallest change that fixes it. -->

## Gates

Tick what you ran, and delete the rows for parts you did not touch. [CONTRIBUTING.md](https://github.com/poly-glot/zig-directory/blob/main/CONTRIBUTING.md) explains each one.

- [ ] Zig changed: `zig build test` passes (it includes the `src/tidy.zig` TigerStyle checker)
- [ ] Zig changed: `zig fmt src/ bench/` leaves no diff
- [ ] Zig changed: `zig build -Dtools=true` builds the bench client and the importer
- [ ] Wire protocol changed: ran `zig build gen-client-ts`, ran `deno fmt` on the result, and committed `web/lib/dmoz-protocol.gen.ts` in this pull request
- [ ] Web changed: `cd web && deno task check` passes
- [ ] Web changed: `cd web && deno task test` passes
- [ ] MCP changed: `cd mcp && uv run ruff format --check . && uv run ruff check . && uv run mypy . && uv run pytest` passes
- [ ] Anything a person sees changed: ran `cd e2e && npx playwright test --project=chromium --reporter=line` and looked at the page

## Tests

- [ ] A bug fix comes with a test that fails without the fix, and I saw it fail
- [ ] A new behaviour comes with a test

## Checks

- [ ] The change fixes the cause, not the place where it shows up
- [ ] No new dependency
- [ ] Docs and the README match the change
- [ ] Commits follow the history's style (`fix(scope): subject`, with a body that says what was wrong)
