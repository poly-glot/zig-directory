from fastmcp import Context
from fastmcp.apps import PrefabAppConfig
from fastmcp.tools import ToolResult
from mcp_types import ToolAnnotations

from app import mcp
from client import category_at
from formatting import category_summary, counted
from views import build_view, category_card, result


@mcp.tool(
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
        open_world_hint=True,
    ),
)
async def browse_category(ctx: Context, path: str = "") -> ToolResult:
    category, ancestors, children = await category_at(path)
    breadcrumb = " / ".join(
        [ancestor["name"] for ancestor in ancestors] + [category["name"]]
    )

    lines = [category_summary(category), breadcrumb]
    if children:
        lines.append(f"{counted(len(children), 'subcategory', 'subcategories')}:")
        lines += [category_summary(child) for child in children]
    else:
        lines.append("No subcategories. Use list_links for its links.")

    return result(
        ctx,
        lines,
        lambda: build_view(
            category["name"], breadcrumb, [("", children, category_card)]
        ),
    )
