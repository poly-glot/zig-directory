# dmozdb MCP server

Exposes the directory as MCP tools. Each tool is a task ("browse this
category", "list the links under it", "search"), not a mirror of an HTTP
endpoint: the tool layer calls the Fresh app's `/api/v1` over HTTP and never
speaks the binary protocol or touches Deno KV.

| Tool | Returns |
|---|---|
| `browse_category` | breadcrumb, child categories, subtree counts |
| `list_links` | approved links from a category and everything beneath it, cursor-paged |
| `search_directory` | matching categories and links, each link with its category path |

Categories are addressed by slug path only, the same `path` the website uses.
`list_links` resolves that path itself, so no numeric ids cross the tool
boundary.

## Two replies per call

Every tool returns a compact text summary for the model. When the client
advertises the MCP Apps extension (`io.modelcontextprotocol/ui`), the same
reply also carries a Prefab view: link cards with title, domain and
description, category cards with Open and Links buttons, and a Next page
button that calls the tool again with the cursor. Clients without the
extension get the text alone and never pay for the component tree.

## Run it

Needs the stack up first (`dmozdb` on :8080, Fresh on :8000 — see
`.devcontainer/run.sh`), then:

```bash
cd mcp
uv sync
DMOZ_API_URL=http://127.0.0.1:8000 uv run python server.py   # :8765/mcp
```

Register it with Claude Code, and check the handshake:

```bash
claude mcp add --transport http dmozdb http://127.0.0.1:8765/mcp
claude mcp list
```

Inspect or call a tool without a host:

```bash
uv run fastmcp list http://127.0.0.1:8765/mcp
uv run fastmcp call http://127.0.0.1:8765/mcp browse_category '{"path":"arts"}'
```

## Layout

Each tool is its own module under `tools/`; nothing there imports `server.py`.

| File | Holds |
|---|---|
| `app.py` | the shared `FastMCP` instance the tool modules register against |
| `client.py` | the httpx2 client, `fetch`, `category_at`, the `JSON` type alias |
| `formatting.py` | text-summary helpers and the paging constants |
| `views.py` | Prefab cards and `build_view`/`result` |
| `tools/browse.py`, `tools/links.py`, `tools/search.py` | one `@mcp.tool` each |
| `tools/__init__.py` | imports the three above, registering them on import |
| `server.py` | imports `tools` and runs the HTTP transport |

A card's "Open"/"Browse"/"Next page" buttons call other tools by name
(`CallTool("browse_category", ...)`), not by importing the function — that's
what lets `views.py` stay free of `tools/`.

## Adding a tool

Add the data it needs to `web/routes/api/v1/`, document that route in
`web/routes/api/v1/_lib/openapi.ts`, then add a module under `tools/` with
one `@mcp.tool` function and import it from `tools/__init__.py`. Keep the
text summary short, and reuse `link_card` or `category_card` for the view.
Pin `prefab-ui` to an exact version when this goes to production; it is
pre-1.0.

The OpenAPI document is documentation for API consumers, not the tool
contract. `cd web && deno task test` fails if a documented path has no route.

## Checks

```bash
uv run ruff format --check .
uv run ruff check .
uv run mypy .
```

The Stop hook runs this automatically when a `mcp/*.py` file changed.

## Identity (`auth.py`, built but not wired)

The app's own accounts (`web/lib/kv-users.ts`) are the identity provider:
Fresh is an OAuth 2.1 Authorization Server (`web/routes/oauth/*`,
`web/routes/.well-known/*`) over its existing users, and `auth.py` builds a
`RemoteAuthProvider` that verifies the JWTs Fresh issues. `server.py` does
**not** pass `auth=` to `FastMCP` yet — `browse_category`, `list_links` and
`search_directory` stay open with no login, exactly as today. Wiring it in
for a future write tool is:

```python
from auth import remote_auth_provider
mcp = FastMCP("dmozdb", auth=remote_auth_provider)

from fastmcp.server.auth import require_roles

@mcp.tool(auth=require_roles("editor", "admin", extract=lambda c: c["role"]))
async def approve_submission(...): ...
```

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
6. Confirm `browse_category` etc. still work with **no** `Authorization`
   header — the read tools must be unaffected by any of the above.
