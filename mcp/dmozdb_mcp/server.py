"""Serve the tool layer over MCP's streamable HTTP transport.

Run it as a module from the project root:

    DMOZ_API_URL=http://127.0.0.1:8000 uv run python -m dmozdb_mcp.server

``auth`` and ``tools`` are imported for their registration side effects — the
protected-resource route and the tools themselves — not for any name.
"""

import os

import uvicorn
from starlette.middleware import Middleware

from dmozdb_mcp import auth, tools
from dmozdb_mcp.app import mcp_app

if __name__ == "__main__":
    uvicorn.run(
        mcp_app.http_app(path="/mcp", middleware=[Middleware(auth.OpportunisticAuth)]),
        host=os.environ.get("HOST", "127.0.0.1"),
        port=int(os.environ.get("PORT", "8765")),
    )
