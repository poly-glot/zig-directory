"""Finding an entry point when no category path is known yet."""

from typing import Annotated, Literal

from fastmcp import Context
from fastmcp.apps import PrefabAppConfig
from fastmcp.tools import ToolResult
from mcp_types import ToolAnnotations
from pydantic import Field

from dmozdb_mcp import client, formatting, views
from dmozdb_mcp.app import mcp_app
from dmozdb_mcp.client import JSON
from dmozdb_mcp.formatting import DEFAULT_LIMIT, MAX_LIMIT


def _summarize(query: str, categories: list[JSON], links: list[JSON]) -> list[str]:
    """Turn a result set into its text summary, grouped by kind.

    Args:
        query: What was searched for, echoed back so a reply stands alone.
        categories: Matching categories.
        links: Matching links.

    Returns:
        The summary lines, ending in "No matches." when both are empty.
    """
    lines = [
        f'"{query}": {formatting.counted(len(categories), "category", "categories")}, '
        f"{formatting.counted(len(links), 'link', 'links')}"
    ]
    if categories:
        lines.append("Categories:")
        lines += [formatting.category_summary(category) for category in categories]
    if links:
        lines.append("Links:")
        lines += [formatting.link_summary(link) for link in links]
    if not categories and not links:
        lines.append("No matches.")
    return lines


@mcp_app.tool(
    app=PrefabAppConfig(),
    description=(
        "Search the directory for categories and approved links, matching on "
        "category names and on link titles, URLs and descriptions. Use it to "
        "find an entry point when you do not know the category path."
    ),
    annotations=ToolAnnotations(
        title="Search the directory",
        read_only_hint=True,
        idempotent_hint=True,
        open_world_hint=False,
    ),
)
async def search_directory(
    ctx: Context,
    q: Annotated[
        str,
        Field(
            min_length=2,
            description=(
                "What to look for, at least two characters. Matched against "
                "category names and against link titles, URLs and "
                "descriptions."
            ),
        ),
    ],
    search_in: Annotated[
        Literal["both", "links", "categories"],
        Field(
            description=(
                "Which kind of entry to return: categories when looking for "
                "a path to browse, links when looking for sites, both by "
                "default."
            )
        ),
    ] = "both",
    limit: Annotated[
        int,
        Field(
            ge=1,
            le=MAX_LIMIT,
            description="How many of each kind to return.",
        ),
    ] = DEFAULT_LIMIT,
) -> ToolResult:
    """Search categories and links, each link carrying its category path.

    Args:
        ctx: Tool context, used to decide whether to build a view.
        q: The query, at least two characters.
        search_in: Which kinds of entry to return.
        limit: How many of each kind to return.

    Returns:
        The matches grouped by kind, with cards for a client that can render
        them.

    Raises:
        ToolError: If the directory service cannot be reached.
    """
    found = await client.fetch("/api/v1/search", q=q, scope=search_in, limit=limit)
    categories = found["categories"]
    links = found["links"]

    return views.result(
        ctx,
        _summarize(q, categories, links),
        lambda: views.build_view(
            f'Search: "{q}"',
            f"{len(categories)} categories · {len(links)} links",
            [
                views.Section("Categories", categories, views.category_card),
                views.Section("Links", links, views.link_card),
            ],
        ),
    )
