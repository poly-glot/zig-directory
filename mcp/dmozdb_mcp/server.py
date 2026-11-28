"""Serve the tool layer over MCP's streamable HTTP transport.

Run it as a module from the project root:

    DMOZ_API_URL=http://127.0.0.1:8000 uv run python -m dmozdb_mcp.server

``auth`` and ``tools`` are imported for their registration side effects — the
protected-resource route and the tools themselves — not for any name.
"""

import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.routing import Route

from dmozdb_mcp import auth, tools
from dmozdb_mcp.app import mcp_app

MCP_PATH = "/mcp"
SESSION_IDLE_TIMEOUT_S = 300
SESSIONS_MAX = 2000


def build_app() -> Starlette:
    app = mcp_app.http_app(
        path=MCP_PATH,
        middleware=[Middleware(auth.OpportunisticAuth)],
        session_idle_timeout=SESSION_IDLE_TIMEOUT_S,
    )
    mcp_route = next(
        route
        for route in app.routes
        if isinstance(route, Route) and route.path == MCP_PATH
    )
    mcp_endpoint: Any = mcp_route.endpoint
    serving = app.router.lifespan_context

    @asynccontextmanager
    async def lifespan(scope: Starlette) -> AsyncIterator[None]:
        async with serving(scope):
            mcp_endpoint.session_manager.max_sessions = SESSIONS_MAX
            yield

    app.router.lifespan_context = lifespan
    return app


if __name__ == "__main__":
    uvicorn.run(
        build_app(),
        host=os.environ.get("HOST", "127.0.0.1"),
        port=int(os.environ.get("PORT", "8765")),
    )
