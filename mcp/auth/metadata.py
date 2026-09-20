"""The RFC 9728 document a 401 challenge points a client at.

FastMCP generates its own at the mount path appended to the resource URL,
which doubles the ``/mcp`` segment; a client derives the path by inserting
the well-known segment instead, looks where the spec says, and gets a 404.
This serves it where the spec puts it.
"""

from starlette.requests import Request
from starlette.responses import JSONResponse

from app import mcp_app

from .config import ISSUER_URL, RESOURCE_METADATA_PATH, RESOURCE_URL, SCOPE


@mcp_app.custom_route(RESOURCE_METADATA_PATH, methods=["GET"])
async def protected_resource_metadata(request: Request) -> JSONResponse:
    """Name this resource and the authorization server that speaks for it.

    Args:
        request: Unused; the document is the same for every caller.

    Returns:
        The protected-resource metadata, including the scope a client should
        request so it need not guess one.
    """
    return JSONResponse(
        {
            "resource": RESOURCE_URL,
            "authorization_servers": [ISSUER_URL],
            "bearer_methods_supported": ["header"],
            "scopes_supported": [SCOPE],
        }
    )
