"""The one tool that changes the directory, and the only one requiring a role."""

from typing import Annotated, Literal

from mcp_types import ToolAnnotations
from pydantic import Field

from dmozdb_mcp import client, formatting
from dmozdb_mcp.app import mcp_app
from dmozdb_mcp.auth import roles

_admin_token = roles.protect("review_submission", role="admin")


@mcp_app.tool(
    description=(
        "Approve or reject a pending link submission. The caller's role "
        "comes from their MCP sign-in, not from an argument — only an "
        "admin account can call this. Before ruling, query_links(domain=...) "
        "shows how many links and categories the submission's domain already "
        "holds; the reply here repeats that standing after the change."
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
        A line naming the link and the status it now holds, then how many
        approved links and categories its domain holds in the directory.

    Raises:
        ToolError: If the caller is not signed in, does not hold the admin
            role, or the API refuses the change.
    """
    status = "approved" if decision == "approve" else "rejected"
    token = _admin_token()

    link = await client.post_authorized(
        f"/api/v1/links/{link_id}/status",
        token=token,
        json_body={"status": status},
    )
    ruling = f"{link['title']} — {link['url']} is now {status}."
    domain = formatting.domain_of(link["url"])
    if not domain:
        return ruling

    standing = await client.fetch("/api/v1/links/query", domain=domain, limit=0)
    links = formatting.counted(standing["total"], "approved link", "approved links")
    categories = formatting.counted(standing["categories"], "category", "categories")
    return f"{ruling}\n{domain} holds {links} in {categories}."
