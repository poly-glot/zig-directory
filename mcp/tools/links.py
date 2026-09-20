from fastmcp import Context
from fastmcp.tools import ToolResult
from mcp_types import ToolAnnotations

from app import mcp
from client import category_at, fetch
from formatting import DEFAULT_LIMIT, clamped, counted, cursor_summary, link_summary
from views import build_view, link_card, result


@mcp.tool(
    app=True,
    description=(
        "List approved links filed in a category and in every category beneath "
        "it. Takes the same slug path as browse_category. Pass the after_id from "
        "a previous reply to get the next page; an after_id of 0 in the reply "
        "means there are no more."
    ),
    annotations=ToolAnnotations(
        title="List links in a category",
        read_only_hint=True,
        open_world_hint=True,
    ),
)
async def list_links(
    ctx: Context, path: str, after_id: int = 0, limit: int = DEFAULT_LIMIT
) -> ToolResult:
    category, _, _ = await category_at(path)
    page = await fetch(
        f"/api/v1/categories/{category['id']}/links",
        after_id=after_id,
        limit=clamped(limit),
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
            {"path": path, "after_id": page["nextAfterId"], "limit": clamped(limit)},
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
