from typing import Annotated, Literal

from fastmcp import Context
from fastmcp.apps import PrefabAppConfig
from fastmcp.tools import ToolResult
from mcp_types import ToolAnnotations
from pydantic import Field

from app import mcp
from client import fetch
from formatting import (
    DEFAULT_LIMIT,
    MAX_LIMIT,
    category_summary,
    counted,
    link_summary,
)
from views import build_view, category_card, link_card, result


@mcp.tool(
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
    found = await fetch("/api/v1/search", q=q, scope=search_in, limit=limit)
    categories = found["categories"]
    links = found["links"]

    lines = [
        f'"{q}": {counted(len(categories), "category", "categories")}, '
        f"{counted(len(links), 'link', 'links')}"
    ]
    if categories:
        lines.append("Categories:")
        lines += [category_summary(category) for category in categories]
    if links:
        lines.append("Links:")
        lines += [link_summary(link) for link in links]
    if not categories and not links:
        lines.append("No matches.")

    return result(
        ctx,
        lines,
        lambda: build_view(
            f'Search: "{q}"',
            f"{len(categories)} categories · {len(links)} links",
            [("Categories", categories, category_card), ("Links", links, link_card)],
        ),
    )
