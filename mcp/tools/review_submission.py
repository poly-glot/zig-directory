from typing import Literal

from fastmcp import Context
from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_http_headers
from mcp_types import ToolAnnotations

from app import mcp
from auth import verifier
from client import post_authorized


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


@mcp.tool(
    description=(
        "Approve or reject a pending link submission. The caller's role "
        "comes from their MCP sign-in, not from an argument — only an "
        "admin account can call this."
    ),
    annotations=ToolAnnotations(
        title="Review a submission",
        read_only_hint=False,
        idempotent_hint=True,
    ),
)
async def review_submission(
    ctx: Context, link_id: int, decision: Literal["approve", "reject"]
) -> str:
    status = "approved" if decision == "approve" else "rejected"
    token = await admin_bearer_token()

    link = await post_authorized(
        f"/api/v1/links/{link_id}/status",
        token=token,
        json_body={"status": status},
    )
    return f"{link['title']} — {link['url']} is now {status}."
