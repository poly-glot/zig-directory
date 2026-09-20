# dmozdb MCP server

Exposes the directory as MCP tools. Each tool is a task ("browse this
category", "list the links under it", "search"), not a mirror of an HTTP
endpoint: the tool layer calls the Fresh app's `/api/v1` over HTTP and never
speaks the binary protocol or touches Deno KV.

| Tool | Auth | Returns |
|---|---|---|
| `browse_category` | none | breadcrumb, child categories, subtree counts |
| `list_links` | none | approved links from a category and everything beneath it, cursor-paged |
| `search_directory` | none | matching categories and links, each link with its category path |
| `review_submission` | admin | approves or rejects a link; the updated link |

Categories are addressed by slug path only, the same `path` the website uses.
`list_links` resolves that path itself, so no numeric ids cross the tool
boundary.

The three reads need no account, exactly like the website they mirror, and
calling `review_submission` without one answers with an RFC 6750 challenge
rather than an error — so a client signs its user in at the moment the
directory is actually asked to change. That is the "sign in when needed"
shape in Claude's connector dialog; see [Identity](#identity-auth).

`review_submission` is therefore listed to *everyone*: `auth=require_roles(...)`
would hide it from `tools/list`, and a tool a client cannot see is never
called, so the challenge never fires. The role check lives in the tool body.

## Two replies per call

Every tool returns a compact text summary for the model. When the client
advertises the MCP Apps extension (`io.modelcontextprotocol/ui`), the same
reply also carries a Prefab view: link cards with title, domain and
description, category cards with Open and Links buttons, and a Next page
button that calls the tool again with the cursor. Clients without the
extension get the text alone and never pay for the component tree.

## Run it

Needs the stack up first (`dmozdb` on :8080, Fresh on :8000 — see
`.devcontainer/run.sh`) and the JWT keypair from `web/.env` set (see
[Identity](#identity-auth) below), then:

```bash
cd mcp
uv sync
DMOZ_API_URL=http://127.0.0.1:8000 uv run python -m dmozdb_mcp.server   # :8765/mcp
```

Register with Claude Code — no token to paste, because the reads are open
and the one write asks for a sign-in when it is called:

```bash
claude mcp add --transport http dmozdb http://127.0.0.1:8765/mcp
claude mcp list
```

Inspect or call a tool without a host:

```bash
uv run fastmcp list http://127.0.0.1:8765/mcp
uv run fastmcp call http://127.0.0.1:8765/mcp browse_category \
  --input-json '{"path":"arts"}'
uv run fastmcp call http://127.0.0.1:8765/mcp review_submission \
  --input-json '{"link_id":1,"decision":"approve"}' --auth <access_token>
```

## Layout

Everything importable lives in the `dmozdb_mcp` package; the project root
holds only configuration and the tests. Each tool is its own module under
`dmozdb_mcp/tools/`, and nothing there imports `dmozdb_mcp/server.py`.

| File | Holds |
|---|---|
| `dmozdb_mcp/app.py` | the shared `FastMCP` instance `mcp_app`, deliberately without a server-wide `auth=` |
| `dmozdb_mcp/auth/config.py` | the `JWTVerifier` for Fresh's tokens, the scope, and this resource's own metadata URL |
| `dmozdb_mcp/auth/challenge.py` | ASGI layer: verifies a token when offered, challenges for protected tools |
| `dmozdb_mcp/auth/metadata.py` | the RFC 9728 protected-resource document the challenge points at |
| `dmozdb_mcp/auth/roles.py` | `protect()`, which registers a tool for the challenge *and* returns its role check |
| `dmozdb_mcp/auth/__init__.py` | imports the three above, registering the metadata route on import |
| `dmozdb_mcp/client.py` | the httpx2 client `_api`, `fetch` (GET), `post_authorized` (POST + bearer), `category_at`, the `JSON` type alias |
| `dmozdb_mcp/formatting.py` | text-summary helpers and the paging constants |
| `dmozdb_mcp/views.py` | Prefab cards and `build_view`/`result` |
| `dmozdb_mcp/tools/*.py` | one `@mcp_app.tool` each |
| `dmozdb_mcp/tools/__init__.py` | imports the four above, registering them on import |
| `dmozdb_mcp/server.py` | imports `auth`/`tools` and serves the app behind `auth.OpportunisticAuth` |
| `test_invariants.py` | the pytest cases that keep auth registration and tool schemas honest |

A card's "Open"/"Browse"/"Next page" buttons call other tools by name
(`CallTool("browse_category", ...)`), not by importing the function — that's
what lets `dmozdb_mcp/views.py` stay free of `dmozdb_mcp/tools/`.

## Adding a tool

Add the data it needs to `web/routes/api/v1/`, then add a module under
`dmozdb_mcp/tools/` with one `@mcp_app.tool` function and import it from
`dmozdb_mcp/tools/__init__.py`. Keep the text summary short, and reuse `link_card` or
`category_card` for the view. Pin `prefab-ui` to an exact version when this
goes to production; it is pre-1.0.

A write tool's route additionally needs to verify the bearer token itself
(`verifyBearerToken` in `web/lib/oauth.ts`) rather than trust the session
cookie the human-facing `/admin` routes use — see
`web/routes/api/v1/links/[id]/status.ts` for the pattern — and the tool
needs its own role check in its body, matching whatever the real
authorization rule for that action already is on the website, not a
convenient guess. Declare it with `protect("name", role=...)` from
`dmozdb_mcp/auth/roles.py`, which registers it for the sign-in challenge and returns the
role check in one call, so the two cannot drift apart.

## Checks

```bash
uv run ruff format --check .
uv run ruff check .
uv run mypy .
uv run pytest
```

The Stop hook runs all four when any `mcp/**/*.py` changed.

`test_invariants.py` asserts what the type-checker cannot: that every write
tool is registered for the 401 challenge and every protected name still
matches a tool, that the body probe and bearer parsing behave, and that no
parameter ships without a description or as an unbounded integer. It needs no
running server.

## Deploying it

`deployment/base/mcp.yaml`, rolled out by `.github/workflows/cd.yaml` on push
to `main`. It serves `directory.junaid.guru/mcp`, sharing the site's hostname
through two ingress path rules that mirror `isMcpPath()` in the devcontainer
proxy.

The pod holds no secret: tools call the web tier's `/api/v1` over the
in-cluster Service, and tokens are verified against that tier's JWKS. The
frontend does need the `mcp-jwt-signing-key` Secret to sign them, and nothing
creates it automatically — see the Secrets section of the root
[README](../README.md#secrets-which-must-exist-before-the-first-apply).

## Identity (`dmozdb_mcp/auth/`)

The app's own accounts (`web/lib/kv-users.ts`) are the identity provider:
Fresh is an OAuth 2.1 Authorization Server (`web/routes/auth/oauth/*`,
`web/routes/auth/.well-known/*`) over its existing users, and `dmozdb_mcp/auth/config.py`
builds the `JWTVerifier` that verifies the JWTs Fresh issues. Users are never
expected to mint a token by hand: a client detects the `401` +
`WWW-Authenticate` challenge and drives the login itself.

`dmozdb_mcp/app.py` deliberately does **not** pass `auth=` to `FastMCP`. That option
installs `RequireAuthMiddleware`, which answers *every* request lacking a
bearer token with a 401 — including `initialize` — so no client could read a
public directory without an account first. There is no anonymous or optional
mode on it. `dmozdb_mcp/auth/challenge.py` supplies the missing middle instead:

- When a request carries a bearer token it is verified and published as
  `scope["user"]`/`scope["auth"]`, exactly as the SDK's own bearer backend
  does. `get_access_token()` reads identity from there, so a tool body can
  ask who is calling without any transport-wide gate.
- When a request carries none *and* names a tool registered by `protect()`, it is
  answered with `401` + `WWW-Authenticate: Bearer resource_metadata="…"`
  (RFC 6750 §3.1: no `error` attribute when no credentials were offered, an
  `error="invalid_token"` when a bad one was). Everything else passes
  through anonymously.

A JSON-RPC `ToolError` is *not* a substitute here. It travels inside a 200
response, so a client sees an ordinary tool failure and has nothing to
trigger a sign-in from; the challenge has to be at the HTTP layer.

Fresh's OAuth surface lives under `/auth` (`OAUTH_ISSUER_URL` ends in
`/auth`) so that a single public hostname can front both the MCP transport
(`/mcp`) and the Authorization Server (`/auth/*`) via path-based routing —
needed when tunnelling a local devcontainer through one hostname, and the
same shape production uses (`OAUTH_ISSUER_URL=https://directory.junaid.guru/auth`
in `deployment/base/web.yaml`). The one exception is RFC 8414's own
discovery document: a well-known metadata URI inserts the issuer's path
*after* `/.well-known/oauth-authorization-server`, not before, so it's
served from `web/routes/.well-known/oauth-authorization-server/auth.ts` —
outside `/auth`, not inside it. Everything `/auth/*` returns
(`authorization_endpoint`, `token_endpoint`, `jwks_uri`) is just a field
value in that document, with no fixed placement rule, so those stay under
`/auth` where they're easy to find.

Authenticating (who you are) and authorizing (what you may do) stay
separate: `dmozdb_mcp/auth/challenge.py` only establishes identity, so an admin-only tool
enforces its own rule:

```python
def _admin_token() -> str:
    token = get_access_token()
    if token is None:
        raise ToolError("Sign in with an admin account to review submissions.")
    if (token.claims or {}).get("role") != "admin":
        raise ToolError("This tool requires an admin account.")
    return token.token
```

`claims["role"]` is the flat, site-wide `role` already on every user
(`user`/`editor`/`admin` — see `kv-users.ts`). There is no per-category
editor stewardship yet (`EditorRolePanel.tsx` says so explicitly), so
`review_submission` requires `"admin"`, not `"editor"` — granting editors a
write capability the website itself doesn't would be a real authorization
bug, not a shortcut.

### Client identity: CIMD and dynamic registration

A client may identify itself two ways, and `resolveClient()` in
`web/lib/oauth.ts` accepts both:

- **CIMD** (`draft-parecki-oauth-client-id-metadata-document`) — the
  `client_id` *is* an HTTPS URL hosting the client's metadata, so nothing is
  registered up front. This is what Claude's connector picks by default
  ("Use Claude's published identity"). `web/lib/cimd.ts` fetches the
  document and rejects it unless the URL is HTTPS with a non-root path,
  resolves to a public address (no loopback, private, link-local, CGNAT or
  multicast range — an unauthenticated caller naming a URL we fetch is an
  SSRF vector), declares a `client_id` identical to its own URL, carries at
  least one syntactically valid `redirect_uri`, and uses no shared-secret
  `token_endpoint_auth_method`. Successful lookups are cached for ten
  minutes so `authorize` and `token` don't refetch per request.
- **Dynamic registration** (RFC 7591, `/auth/oauth/register`) — unchanged,
  and still what a client gets when it picks "Register automatically".

CIMD documents may use wildcard redirect patterns, so redirect validation
goes through `redirectUriMatches()` rather than an exact-string check: the
scheme must match, `*.example.com` matches subdomains only, a loopback
pattern matches any port (RFC 8252 §7.3), and URIs carrying userinfo or
dot-segments are refused outright — both are classic ways to smuggle a
redirect past naive matching.

### Verifying the AS/RS pair end to end

1. Generate a keypair once and put it in `web/.env` (gitignored):
   ```bash
   cd web && deno run -A scripts/generate-jwt-keypair.ts
   # paste the two printed lines into web/.env, plus:
   #   OAUTH_ISSUER_URL="http://127.0.0.1:8000/auth"
   #   MCP_RESOURCE_URL="http://127.0.0.1:8765/mcp"
   ```
2. Register a client:
   ```bash
   curl -X POST http://127.0.0.1:8000/auth/oauth/register \
     -H 'Content-Type: application/json' \
     -d '{"redirect_uris": ["http://127.0.0.1:9999/cb"]}'
   ```
3. Build a PKCE pair and open `/auth/oauth/authorize` in a browser, logged in
   as an existing account:
   ```bash
   python3 - <<'EOF'
   import base64, hashlib, secrets
   verifier = secrets.token_urlsafe(64)
   challenge = base64.urlsafe_b64encode(
       hashlib.sha256(verifier.encode()).digest()
   ).rstrip(b"=").decode()
   print("verifier:", verifier)
   print("challenge:", challenge)
   EOF
   ```
   `http://127.0.0.1:8000/auth/oauth/authorize?response_type=code&client_id=<id>&redirect_uri=http://127.0.0.1:9999/cb&code_challenge=<challenge>&code_challenge_method=S256&resource=http://127.0.0.1:8765/mcp&state=xyz`
   — approve, then copy the `code` from the (404, that's fine) redirect URL.
4. Exchange it:
   ```bash
   curl -X POST http://127.0.0.1:8000/auth/oauth/token \
     -d grant_type=authorization_code -d code=<code> \
     -d client_id=<id> -d redirect_uri=http://127.0.0.1:9999/cb \
     -d code_verifier=<verifier>
   ```
5. Confirm the token verifies and carries the right role:
   ```bash
   cd mcp && OAUTH_ISSUER_URL=http://127.0.0.1:8000/auth \
     MCP_RESOURCE_URL=http://127.0.0.1:8765/mcp \
     uv run python -c "
   import asyncio
   from auth.config import verifier
   print(asyncio.run(verifier.verify_token('<access_token>')))
   "
   ```
6. Confirm the reads are open and the write is *visible* —
   `fastmcp list http://127.0.0.1:8765/mcp` with no `--auth` lists all 4
   tools and `browse_category` returns data. The count is 4 for every
   caller — anonymous, `role=user` and `role=admin` alike — and a
   `role=user` token must still be refused by `review_submission` itself.
7. Confirm the write asks for a sign-in rather than failing. Posting a
   `tools/call` for `review_submission` with no token must answer `401`
   with a `WWW-Authenticate: Bearer resource_metadata="…"` header, and that
   URL must serve the protected-resource document naming the issuer:
   ```bash
   curl -s http://127.0.0.1:8765/.well-known/oauth-protected-resource/mcp
   ```
8. Call `review_submission` with the admin token and confirm the link's
   status actually changes (`GET /api/v1/browse` or the `/admin/links` page).
9. For CIMD, skip step 2 entirely: pass an HTTPS URL serving a client
   document as `client_id` and confirm a token is issued whose `client_id`
   claim is that URL.
