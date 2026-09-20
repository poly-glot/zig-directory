from typing import Literal, cast

from fastmcp import Context
from fastmcp.server.auth import AccessToken, require_roles
from fastmcp.server.dependencies import get_access_token
from mcp_types import ToolAnnotations

from app import mcp
from client import post_authorized


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
    auth=require_roles("admin", extract=lambda claims: claims["role"]),
)
async def review_submission(
    ctx: Context, link_id: int, decision: Literal["approve", "reject"]
) -> str:
    status = "approved" if decision == "approve" else "rejected"
    token = cast(AccessToken, get_access_token())

    link = await post_authorized(
        f"/api/v1/links/{link_id}/status",
        token=token.token,
        json_body={"status": status},
    )
    return f"{link['title']} — {link['url']} is now {status}."
