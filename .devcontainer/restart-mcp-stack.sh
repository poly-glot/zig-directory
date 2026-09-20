#!/usr/bin/env bash
set -u

export PATH="$HOME/.local/bin:$PATH"
export UV_PROJECT_ENVIRONMENT="$HOME/.venvs/dmozdb-mcp"

pkill -f "[d]ev-tunnel-proxy.ts"
pkill -f "[d]mozdb_mcp.server"
sleep 2

cd /workspaces/zig-directory/mcp
DMOZ_API_URL=http://127.0.0.1:8000 \
MCP_RESOURCE_URL=https://mcp.junaid.guru/mcp \
OAUTH_ISSUER_URL=https://mcp.junaid.guru/auth \
HOST=0.0.0.0 PORT=4001 \
  nohup uv run python -m dmozdb_mcp.server > /tmp/mcp.log 2>&1 &

nohup deno run --allow-net /workspaces/zig-directory/.devcontainer/dev-tunnel-proxy.ts \
  > /tmp/proxy.log 2>&1 &

sleep 6
pgrep -af "dmozdb_mcp.server|dev-tunnel-proxy.ts" | cut -c1-110
