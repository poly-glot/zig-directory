"""Reading the approved links filed under a category and its descendants."""

from typing import Annotated

from fastmcp import Context
from fastmcp.apps import PrefabAppConfig
from fastmcp.tools import ToolResult
from mcp_types import ToolAnnotations
from pydantic import Field

from app import mcp_app
from client import JSON, category_at, fetch
from formatting import (
    DEFAULT_LIMIT,
    MAX_LIMIT,
    counted,
    cursor_summary,
    link_summary,
)
from views import NextPage, Section, build_view, link_card, result


def _summarize(page: JSON, category_name: str) -> tuple[str, list[str]]:
    """Turn one page of links into its headline and full text summary.

    Args:
        page: The API's link page, with ``links``, ``total`` and
            ``nextAfterId``.
        category_name: The category the page was taken from.

    Returns:
        The headline on its own, since the view reuses it as a subheading,
        and the complete summary lines including the cursor hint.
    """
    headline = (
        f"{len(page['links'])} of {counted(page['total'], 'link', 'links')} "
        f"under {category_name}"
    )
    lines = [headline] + [link_summary(link) for link in page["links"]]
    lines.append(cursor_summary(page["nextAfterId"]))
    return headline, lines


@mcp_app.tool(
    app=PrefabAppConfig(),
    description=(
        "List approved links filed in a category and in every category beneath "
        "it. Takes the same slug path as browse_category. Pass the after_id from "
        "a previous reply to get the next page; an after_id of 0 in the reply "
        "means there are no more."
    ),
    annotations=ToolAnnotations(
        title="List links in a category",
        read_only_hint=True,
        idempotent_hint=True,
        open_world_hint=False,
    ),
)
async def list_links(
    ctx: Context,
    path: Annotated[
        str,
        Field(
            description=(
                'Slug path of the category, such as "arts/animation", from '
                "browse_category or search_directory. Links filed in every "
                "category beneath it are included."
            )
        ),
    ],
    after_id: Annotated[
        int,
        Field(
            ge=0,
            description=(
                "Cursor for the next page: pass the after_id this tool "
                "reported last time. 0 starts at the first page, and a "
                "reported after_id of 0 means there are no more."
            ),
        ),
    ] = 0,
    limit: Annotated[
        int,
        Field(
            ge=1,
            le=MAX_LIMIT,
            description="How many links to return in this page.",
        ),
    ] = DEFAULT_LIMIT,
) -> ToolResult:
    """List one cursor-paged page of links from a category's subtree.

    Args:
        ctx: Tool context, used to decide whether to build a view.
        path: Slug path of the category to read.
        after_id: Cursor from a previous reply; 0 starts at the first page.
        limit: Page size.

    Returns:
        The page's links with a cursor hint, and link cards plus a Next page
        button for a client that can render them.

    Raises:
        ToolError: If no category sits at ``path``.
    """
    browsed = await category_at(path)
    page = await fetch(
        f"/api/v1/categories/{browsed.category['id']}/links",
        after_id=after_id,
        limit=limit,
    )
    headline, lines = _summarize(page, browsed.category["name"])

    next_page = (
        NextPage(
            "list_links",
            {"path": path, "after_id": page["nextAfterId"], "limit": limit},
        )
        if page["nextAfterId"]
        else None
    )

    return result(
        ctx,
        lines,
        lambda: build_view(
            f"Links under {browsed.category['name']}",
            headline,
            [Section("", page["links"], link_card)],
            next_page=next_page,
        ),
    )
