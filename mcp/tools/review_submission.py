from typing import Literal

from fastmcp import Context
from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_access_token
from mcp_types import ToolAnnotations

from app import mcp
from client import post_authorized


def _admin_token() -> str:
    token = get_access_token()
    if token is None:
        raise ToolError("Sign in with an admin account to review submissions.")
    if (token.claims or {}).get("role") != "admin":
        raise ToolError("This tool requires an admin account.")
    return token.token


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
    token = _admin_token()

    link = await post_authorized(
        f"/api/v1/links/{link_id}/status",
        token=token,
        json_body={"status": status},
    )
    return f"{link['title']} — {link['url']} is now {status}."
