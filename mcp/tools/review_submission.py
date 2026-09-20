"""The one tool that changes the directory, and the only one requiring a role."""

from typing import Annotated, Literal

from mcp_types import ToolAnnotations
from pydantic import Field

from app import mcp_app
from auth.roles import protect
from client import post_authorized

_admin_token = protect("review_submission", role="admin")


@mcp_app.tool(
    description=(
        "Approve or reject a pending link submission. The caller's role "
        "comes from their MCP sign-in, not from an argument — only an "
        "admin account can call this."
    ),
    annotations=ToolAnnotations(
        title="Review a submission",
        read_only_hint=False,
        destructive_hint=False,
        idempotent_hint=True,
        open_world_hint=False,
    ),
)
async def review_submission(
    link_id: Annotated[
        int,
        Field(
            ge=1,
            description=(
                "Numeric id of the link to rule on, as shown in the admin "
                "queue. This is an id, not a slug path."
            ),
        ),
    ],
    decision: Annotated[
        Literal["approve", "reject"],
        Field(
            description=(
                "approve publishes the link into its category; reject hides "
                "it. Either ruling can be changed later by another call."
            )
        ),
    ],
) -> str:
    """Rule on a pending submission, as the signed-in admin.

    Args:
        link_id: The link to rule on.
        decision: Whether to publish or hide it.

    Returns:
        A line naming the link and the status it now holds.

    Raises:
        ToolError: If the caller is not signed in, does not hold the admin
            role, or the API refuses the change.
    """
    status = "approved" if decision == "approve" else "rejected"
    token = _admin_token()

    link = await post_authorized(
        f"/api/v1/links/{link_id}/status",
        token=token,
        json_body={"status": status},
    )
    return f"{link['title']} — {link['url']} is now {status}."
