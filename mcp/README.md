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
boundary. `review_submission` always appears in `tools/list` — unlike the
website's own `/admin` pages, the MCP server can't hide it per caller — but
calling it without a valid admin bearer token fails.

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
[Identity](#identity-authpy) below), then:

```bash
cd mcp
uv sync
DMOZ_API_URL=http://127.0.0.1:8000 uv run python server.py   # :8765/mcp
```

The three reads are anonymous, same as the website. Only `review_submission`
needs a bearer token, minted by Fresh's OAuth server (see below), from an
admin account. Register with Claude Code:

```bash
claude mcp add --transport http dmozdb http://127.0.0.1:8765/mcp
```

Add `--header "Authorization: Bearer <access_token>"` only if you also want
to call `review_submission`.

Inspect or call a tool without a host:

```bash
uv run fastmcp list http://127.0.0.1:8765/mcp
uv run fastmcp call http://127.0.0.1:8765/mcp browse_category \
  --input-json '{"path":"arts"}'
uv run fastmcp call http://127.0.0.1:8765/mcp review_submission \
  --input-json '{"link_id":1,"decision":"approve"}' --auth <access_token>
```

## Layout

Each tool is its own module under `tools/`; nothing there imports `server.py`.

| File | Holds |
|---|---|
| `app.py` | the shared `FastMCP` instance — no server-wide `auth=`, so reads stay anonymous |
| `auth.py` | builds the `JWTVerifier` that verifies Fresh's tokens; `review_submission` calls it directly |
| `client.py` | the httpx2 client, `fetch` (GET), `post_authorized` (POST + bearer), `category_at`, the `JSON` type alias |
| `formatting.py` | text-summary helpers and the paging constants |
| `views.py` | Prefab cards and `build_view`/`result` |
| `tools/browse.py`, `tools/links.py`, `tools/search.py`, `tools/review_submission.py` | one `@mcp.tool` each |
| `tools/__init__.py` | imports the four above, registering them on import |
| `server.py` | imports `tools` and runs the HTTP transport |

A card's "Open"/"Browse"/"Next page" buttons call other tools by name
(`CallTool("browse_category", ...)`), not by importing the function — that's
what lets `views.py` stay free of `tools/`.

## Adding a tool

Add the data it needs to `web/routes/api/v1/`, then add a module under
`tools/` with one `@mcp.tool` function and import it from
`tools/__init__.py`. Keep the text summary short, and reuse `link_card` or
`category_card` for the view. Pin `prefab-ui` to an exact version when this
goes to production; it is pre-1.0.

A write tool's route additionally needs to verify the bearer token itself
(`verifyBearerToken` in `web/lib/oauth.ts`) rather than trust the session
cookie the human-facing `/admin` routes use — see
`web/routes/api/v1/links/[id]/status.ts` for the pattern. The MCP tool needs
the same check on its own side, matching whatever the real authorization
rule for that action already is on the website, not a convenient guess — see
`admin_bearer_token` in `tools/review_submission.py`. There's no server-wide
`auth=` to lean on (see [Identity](#identity-authpy)), so every write tool
verifies its own token; promote that check into a shared module once a
second write tool needs it.

## Checks

```bash
uv run ruff format --check .
uv run ruff check .
uv run mypy .
```

The Stop hook runs this automatically when a `mcp/*.py` file changed.

## Identity (`auth.py`)

The app's own accounts (`web/lib/kv-users.ts`) are the identity provider:
Fresh is an OAuth 2.1 Authorization Server (`web/routes/oauth/*`,
`web/routes/.well-known/*`) over its existing users, and `auth.py` builds the
`JWTVerifier` that verifies the JWTs Fresh issues.

`app.py` does *not* pass `auth=` to `FastMCP` — that option gates the entire
server at the transport layer with no way to require login for one tool
while leaving others anonymous, and `browse_category`, `list_links` and
`search_directory` mirror the website's own public reads, so the server
stays anonymous by default, same as `/api/v1/browse` et al.

`review_submission` is the one tool that needs a caller's identity, so it
verifies the bearer token itself instead of relying on a server-wide gate:

```python
from auth import verifier


async def admin_bearer_token() -> str:
    header = get_http_headers(include={"authorization"}).get("authorization", "")
    scheme, _, token = header.partition(" ")

    access_token = None
    if scheme.lower() == "bearer" and token:
        access_token = await verifier.verify_token(token)
    if access_token is None:
        raise ToolError("Missing or invalid bearer token.")
    if (access_token.claims or {}).get("role") != "admin":
        raise ToolError("This tool requires an admin account.")
    return access_token.token
```

`access_token.claims["role"]` reads the flat, site-wide `role` already on
every user (`user`/`editor`/`admin` — see `kv-users.ts`). There is no
per-category editor stewardship yet (`EditorRolePanel.tsx` says so
explicitly), so `review_submission` requires `"admin"`, not `"editor"` —
granting editors a write capability the website itself doesn't would be a
real authorization bug, not a shortcut.

The trade-off: FastMCP's `auth=` would have hidden `review_submission` from
`tools/list` for non-admins for free. Hand-verifying means it always lists,
and only fails on call for a caller without the right token — worth it here
to keep the three reads genuinely public, since it's one tool, not the whole
server.

### Verifying the AS/RS pair end to end

1. Generate a keypair once and put it in `web/.env` (gitignored):
   ```bash
   cd web && deno run -A scripts/generate-jwt-keypair.ts
   # paste the two printed lines into web/.env, plus:
   #   OAUTH_ISSUER_URL="http://127.0.0.1:8000"
   #   MCP_RESOURCE_URL="http://127.0.0.1:8765/mcp"
   ```
2. Register a client:
   ```bash
   curl -X POST http://127.0.0.1:8000/oauth/register \
     -H 'Content-Type: application/json' \
     -d '{"redirect_uris": ["http://127.0.0.1:9999/cb"]}'
   ```
3. Build a PKCE pair and open `/oauth/authorize` in a browser, logged in as
   an existing account:
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
   `http://127.0.0.1:8000/oauth/authorize?response_type=code&client_id=<id>&redirect_uri=http://127.0.0.1:9999/cb&code_challenge=<challenge>&code_challenge_method=S256&resource=http://127.0.0.1:8765/mcp&state=xyz`
   — approve, then copy the `code` from the (404, that's fine) redirect URL.
4. Exchange it:
   ```bash
   curl -X POST http://127.0.0.1:8000/oauth/token \
     -d grant_type=authorization_code -d code=<code> \
     -d client_id=<id> -d redirect_uri=http://127.0.0.1:9999/cb \
     -d code_verifier=<verifier>
   ```
5. Confirm the token verifies and carries the right role:
   ```bash
   cd mcp && OAUTH_ISSUER_URL=http://127.0.0.1:8000 \
     MCP_RESOURCE_URL=http://127.0.0.1:8765/mcp \
     uv run python -c "
   import asyncio, auth
   print(asyncio.run(auth.verifier.verify_token('<access_token>')))
   "
   ```
6. Confirm the reads stay public — `fastmcp list http://127.0.0.1:8765/mcp`
   with no `--auth` lists all 4 tools (`review_submission` included, since it
   is never hidden), and `fastmcp call ... browse_category ...` with no
   `--auth` succeeds.
7. Confirm `review_submission` is still gated — calling it with no `--auth`,
   or with a `role=user` token, fails with "Missing or invalid bearer token"
   or "This tool requires an admin account." Calling it with a `role=admin`
   token succeeds and the link's status actually changes (`GET
   /api/v1/browse` or the `/admin/links` page).
