"""The shared FastMCP instance that tools and routes register themselves on.

It lives in its own module so ``tools/`` and ``auth/`` can reach the server
without importing ``server.py`` and, with it, uvicorn and a ``__main__``
guard.

The instance is named ``mcp_app`` rather than ``mcp`` because the MCP SDK is
itself the top-level package ``mcp``; a module holding both would rebind the
name depending on import order.

It is created deliberately without ``auth=``, which would gate the whole
transport. See ``auth.challenge.OpportunisticAuth`` for what replaces it.
"""

from fastmcp import FastMCP

mcp_app = FastMCP("dmozdb")
