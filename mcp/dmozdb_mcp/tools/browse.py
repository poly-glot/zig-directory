"""The entry point into the category tree."""

from typing import Annotated

from fastmcp import Context
from fastmcp.apps import PrefabAppConfig
from fastmcp.tools import ToolResult
from mcp_types import ToolAnnotations
from pydantic import Field

from dmozdb_mcp import client, formatting, views
from dmozdb_mcp.app import mcp_app


@mcp_app.tool(
    app=PrefabAppConfig(),
    description=(
        "Browse one category of a hand-curated web directory: its breadcrumb, "
        "its child categories and how many links sit beneath it. Call with an "
        "empty path for the top-level categories, then pass the path of a child "
        "to descend. Returns no links; use list_links for those."
    ),
    annotations=ToolAnnotations(
        title="Browse a category",
        read_only_hint=True,
        idempotent_hint=True,
        open_world_hint=False,
    ),
)
async def browse_category(
    ctx: Context,
    path: Annotated[
        str,
        Field(
            description=(
                'Slug path of the category, such as "arts/animation". Comes '
                "from the path field of any category this tool or "
                "search_directory returned. Empty string for the top level."
            )
        ),
    ] = "",
) -> ToolResult:
    """Describe one category and the categories directly beneath it.

    Args:
        ctx: Tool context, used to decide whether to build a view.
        path: Slug path to browse; empty means the top level.

    Returns:
        A summary of the category, its breadcrumb and its children, with
        category cards for a client that can render them.

    Raises:
        ToolError: If no category sits at ``path``.
    """
    browsed = await client.category_at(path)
    breadcrumb = " / ".join(
        [ancestor["name"] for ancestor in browsed.ancestors]
        + [browsed.category["name"]]
    )

    lines = [formatting.category_summary(browsed.category), breadcrumb]
    if browsed.children:
        count = formatting.counted(
            len(browsed.children), "subcategory", "subcategories"
        )
        lines.append(f"{count}:")
        lines += [formatting.category_summary(child) for child in browsed.children]
    else:
        lines.append("No subcategories. Use list_links for its links.")

    return views.result(
        ctx,
        lines,
        lambda: views.build_view(
            browsed.category["name"],
            breadcrumb,
            [views.Section("", browsed.children, views.category_card)],
        ),
    )
