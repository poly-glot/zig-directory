from typing import Annotated

from fastmcp import Context
from fastmcp.apps import PrefabAppConfig
from fastmcp.tools import ToolResult
from mcp_types import ToolAnnotations
from pydantic import Field

from app import mcp
from client import category_at, fetch
from formatting import (
    DEFAULT_LIMIT,
    MAX_LIMIT,
    counted,
    cursor_summary,
    link_summary,
)
from views import build_view, link_card, result


@mcp.tool(
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
    category, _, _ = await category_at(path)
    page = await fetch(
        f"/api/v1/categories/{category['id']}/links",
        after_id=after_id,
        limit=limit,
    )
    links = page["links"]
    shown = (
        f"{len(links)} of {counted(page['total'], 'link', 'links')} "
        f"under {category['name']}"
    )

    lines = [shown] + [link_summary(link) for link in links]
    lines.append(cursor_summary(page["nextAfterId"]))

    next_page = (
        (
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
            f"Links under {category['name']}",
            shown,
            [("", links, link_card)],
            next_page=next_page,
        ),
    )
