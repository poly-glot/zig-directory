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

## Adding a tool

Add the data it needs to `web/routes/api/v1/`, document that route in
`web/routes/api/v1/_lib/openapi.ts`, then write the tool here. Keep the text
summary short, and reuse `link_card` or `category_card` for the view. Pin
`prefab-ui` to an exact version when this goes to production; it is pre-1.0.

The OpenAPI document is documentation for API consumers, not the tool
contract. `cd web && deno task test` fails if a documented path has no route.
