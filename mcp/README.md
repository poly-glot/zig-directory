# dmozdb MCP server

Projects the directory's JSON API (`/api/v1`) as MCP tools. The tool list is
generated from the API's own OpenAPI document, so adding a documented route
adds a tool with no Python change. This server speaks HTTP to the Fresh app
only — never the binary protocol, never Deno KV.

Tools: `browse_category`, `list_links_in_subtree`, `search_directory`.

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

Add the route under `web/routes/api/v1/`, then document it in
`web/routes/api/v1/_lib/openapi.ts`. The `operationId` becomes the MCP tool
name and the `description` is what the model reads, so write it for a model.
`cd web && deno task test` fails if a documented path has no route file.
