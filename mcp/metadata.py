from starlette.requests import Request
from starlette.responses import JSONResponse

from app import mcp
from auth import ISSUER_URL, RESOURCE_METADATA_PATH, RESOURCE_URL


@mcp.custom_route(RESOURCE_METADATA_PATH, methods=["GET"])
async def protected_resource_metadata(request: Request) -> JSONResponse:
    return JSONResponse(
        {
            "resource": RESOURCE_URL,
            "authorization_servers": [ISSUER_URL],
            "bearer_methods_supported": ["header"],
        }
    )
