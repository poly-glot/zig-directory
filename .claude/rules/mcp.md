# MCP Conventions (`mcp/`, the FastMCP server)

The tool layer projects the Fresh app's `/api/v1` as MCP tools. A tool is a
task, not an endpoint mirror. Nothing under `mcp/` speaks the binary protocol
or touches Deno KV.

## The schema is the contract, not the prose

A model reads `inputSchema`. Tool-level description text is not attached to
any argument, so it is the weakest place to put a rule about one.

- DO: **Describe every parameter with `Annotated[T, Field(description=...)]`.**
  A bare `path: str` ships as `{"type": "string"}` and tells the caller
  nothing. Say what the value is and where it comes from — "slug path from
  `browse_category`, empty for the top level".
- DO: **Mirror server-side validation as schema constraints.** If the route
  400s below two characters, the parameter carries `min_length=2`. If the
  handler silently clamps, the schema carries `ge=`/`le=` with the same
  bounds. A caller that cannot see a limit cannot respect it, and silent
  clamping makes a truncated page look like the end of the data.
- NEVER: **Clamp where the schema is silent.** Capping 200 to 50 in the body
  while the schema says only `integer` produces a wrong answer with no
  signal; `le=50` makes pydantic refuse at the boundary and say why.
- DO: **Name the next tool in the description.** These tools are a
  traversal (`search_directory` → `browse_category` → `list_links`); say
  which one follows and on what argument.

## Annotations: state them, don't inherit them

MCP defaults are `readOnlyHint=false`, `destructiveHint=true`,
`idempotentHint=false`, `openWorldHint=true`. An omitted hint is a claim, and
usually the wrong one.

- DO: **Set all four on every write tool.** A status flip that an admin can
  reverse is `destructive_hint=False`; leaving it unset asserts the opposite
  and trips "confirm before destructive" behaviour in clients.
- DO: **Set `open_world_hint=False` for tools that only touch this
  directory.** It defaults to true, which claims an open-ended external
  surface.

## Return types

- Tools returning `ToolResult` get **no `outputSchema`** — FastMCP cannot
  infer one. Tools returning a plain type get an auto-wrapped schema
  (`{"result": …}`, `x-fastmcp-wrap-result`).
- `structuredContent` is occupied by the MCP Apps payload for UI-capable
  clients and absent for everyone else, so it is **not** a data channel here.
- DO: **Treat the text summary as the machine-readable contract**, since it
  is the only channel every client gets. Keep the token a caller needs for
  the next call verbatim and stable in it — `path "arts/animation"`,
  `after_id=12792` — and never reword those without checking the tool
  descriptions that tell a model to look for them.

## Where authorization lives

Two independent checks, both mandatory. Neither is a substitute for the other.

- DO: **Enforce the role inside the tool body**, reading identity from
  `get_access_token()`. This is the authoritative check and it must fail
  closed: no token, or a token without the role, raises `ToolError`.
- DO: **Enforce it again in the `/api/v1` route**, with `verifyBearerToken`
  and an explicit role test. The data-owning layer never trusts that a
  caller arrived through the tool.
- NEVER: **Take identity, role, or user id from a tool argument.** It comes
  from the verified token's claims and nowhere else.
- NEVER: **Add `auth=require_roles(...)` to a tool that should prompt a
  sign-in.** FastMCP hides `auth=`-gated tools from `tools/list` for anyone
  failing the check, and a tool a client cannot see is never called, so the
  401 challenge never fires and the server reads as needing no sign-in.
  Visible-then-challenged is the only arrangement where deferred sign-in
  works.
- DO: **Declare a new write tool with `protect()` from `auth/roles.py`.**
  One call registers the name for the 401 challenge and returns the getter
  that enforces the role, so a tool cannot be challenged without being
  checked or checked without being challenged. `test_invariants.py` fails if
  a write tool is missing, or if a registered name matches no tool.

## Tokens

- DO: **Keep the audience bound to this resource.** `JWTVerifier` is built
  with `audience=RESOURCE_URL` and the Fresh side verifies the same value.
  That binding is what stops a token minted for another resource being
  replayed here.
- DO: **Forward the caller's token only to this application's own
  `/api/v1`,** which re-verifies signature, issuer, audience and role. That
  is one resource server split across two processes, not token passthrough.
- NEVER: **Forward a caller's token to a third-party API.** That is the
  passthrough antipattern the MCP spec forbids: the upstream cannot tell who
  is calling and the token becomes a confused-deputy credential. Use a
  separate credential the server owns.
- NEVER: **Log a token, an `Authorization` header, or claim values.** Log the
  decision (`anon`/`bearer`, which tool was challenged), never the secret.

## Verify

`cd mcp && uv run ruff format --check . && uv run ruff check . && uv run mypy .
&& uv run pytest`. The Stop hook runs all four when any `mcp/**/*.py`
changed, and `.github/workflows/ci.yaml` runs them again on push and PR.

- DO: **Put a security-relevant invariant in `test_invariants.py`.** It runs
  without a server, so a check that a tool is registered, a header parses, or
  a schema carries its bound costs nothing to keep.

For anything touching `auth/`, confirm on a running server, not by reading:

1. anonymous `tools/list` lists every tool, write tools included;
2. anonymous call to a protected tool returns `401` with
   `WWW-Authenticate: Bearer resource_metadata="…", scope="…"`;
3. a garbage bearer returns `401 error="invalid_token"`, never a `500`;
4. a `role=user` token is refused by the tool body;
5. a `role=admin` token succeeds and the change actually lands.
