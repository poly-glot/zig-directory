import os
from collections.abc import Callable
from typing import Literal
from urllib.parse import urlsplit

import httpx2
from fastmcp import Context, FastMCP
from fastmcp.apps import UI_EXTENSION_ID
from fastmcp.exceptions import ToolError
from fastmcp.tools import ToolResult
from prefab_ui import PrefabApp
from prefab_ui.actions import CallTool
from prefab_ui.components import (
    Badge,
    Button,
    Card,
    CardTitle,
    Grid,
    H3,
    Link,
    Muted,
    Row,
    Small,
)

DEFAULT_LIMIT = 20
MAX_LIMIT = 50
CARD_MIN_WIDTH = "20rem"
CARD_GAP = 3

api = httpx2.AsyncClient(
    base_url=os.environ.get("DMOZ_API_URL", "http://127.0.0.1:8000"),
    timeout=30,
)

mcp = FastMCP("dmozdb")


async def fetch(endpoint: str, **params) -> dict:
    response = await api.get(
        endpoint,
        params={k: v for k, v in params.items() if v is not None and v != ""},
    )
    if response.is_error:
        try:
            detail = response.json().get("error")
        except ValueError:
            detail = None
        raise ToolError(detail or f"directory returned {response.status_code}")
    return response.json()


UNKNOWN_PATH_HINT = (
    "Use search_directory to find one, or browse_category with an empty path "
    "to start at the top."
)


async def category_at(path: str) -> tuple[dict, list[dict], list[dict]]:
    try:
        browsed = await fetch("/api/v1/browse", path=path)
    except ToolError as unreachable:
        raise ToolError(
            f'no category at path "{path}" ({unreachable}). {UNKNOWN_PATH_HINT}'
        ) from unreachable
    category = browsed["category"]
    if category is None:
        raise ToolError(f'no category at path "{path}". {UNKNOWN_PATH_HINT}')
    return category, browsed["ancestors"], browsed["children"]


def clamped(limit: int) -> int:
    return max(1, min(limit, MAX_LIMIT))


def counted(count: int, singular: str, plural: str) -> str:
    return f"{count:,} {singular if count == 1 else plural}"


def domain_of(url: str) -> str:
    return urlsplit(url).netloc.removeprefix("www.")


def category_summary(category: dict) -> str:
    links = counted(category["linkCountSubtree"], "link", "links")
    children = counted(category["childCount"], "subcategory", "subcategories")
    return f"{category['name']} — {links}, {children}, path \"{category['path']}\""


def link_summary(link: dict) -> str:
    where = f" [{link['categoryPath']}]" if link.get("categoryPath") else ""
    described = f"\n  {link['description']}" if link["description"] else ""
    return f"{link['title']} — {link['url']}{where}{described}"


def cursor_summary(next_after_id: int) -> str:
    if next_after_id == 0:
        return "End of results."
    return f"More available: call again with after_id={next_after_id}."


def link_card(link: dict) -> None:
    with Card(css_class="p-4 flex flex-col gap-1"):
        Link(
            link["title"],
            href=link["url"],
            target="_blank",
            css_class="font-medium leading-snug",
        )
        Small(domain_of(link["url"]), css_class="text-muted-foreground")
        if link["description"]:
            Muted(link["description"], css_class="text-sm")
        if link.get("categoryPath"):
            with Row(gap=2, align="center", css_class="pt-1"):
                Badge(link["categoryPath"], variant="secondary")
                Button(
                    "Browse",
                    variant="ghost",
                    size="xs",
                    onClick=CallTool(
                        browse_category, arguments={"path": link["categoryPath"]}
                    ),
                )


def category_card(category: dict) -> None:
    with Card(css_class="p-4 flex flex-col gap-2"):
        CardTitle(category["name"], css_class="text-base")
        Muted(
            f"{counted(category['linkCountSubtree'], 'link', 'links')} · "
            f"{counted(category['childCount'], 'subcategory', 'subcategories')}",
            css_class="text-sm",
        )
        with Row(gap=2):
            Button(
                "Open",
                size="xs",
                onClick=CallTool(browse_category, arguments={"path": category["path"]}),
            )
            Button(
                "Links",
                variant="outline",
                size="xs",
                onClick=CallTool(list_links, arguments={"path": category["path"]}),
            )


Section = tuple[str, list[dict], Callable[[dict], None]]


def build_view(
    heading: str,
    subheading: str,
    sections: list[Section],
    next_page: tuple[object, dict] | None = None,
) -> PrefabApp:
    with PrefabApp(title=heading, css_class="p-4 flex flex-col gap-4") as app:
        H3(heading)
        if subheading:
            Muted(subheading, css_class="text-sm")

        for label, items, render in sections:
            if not items:
                continue
            if label:
                Small(label, css_class="uppercase tracking-wide text-muted-foreground")
            with Grid(minColumnWidth=CARD_MIN_WIDTH, gap=CARD_GAP):
                for item in items:
                    render(item)

        if next_page is not None:
            tool, arguments = next_page
            Button(
                "Next page",
                variant="outline",
                size="sm",
                css_class="self-start",
                onClick=CallTool(tool, arguments=arguments),
            )
    return app


def result(ctx: Context, lines: list[str], view: Callable[[], PrefabApp]) -> ToolResult:
    text = "\n".join(lines)
    if not ctx.client_supports_extension(UI_EXTENSION_ID):
        return ToolResult(content=text)
    return ToolResult(content=text, structured_content=view())


@mcp.tool(
    app=True,
    description=(
        "Browse one category of a hand-curated web directory: its breadcrumb, "
        "its child categories and how many links sit beneath it. Call with an "
        "empty path for the top-level categories, then pass the path of a child "
        "to descend. Returns no links; use list_links for those."
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


@mcp.tool(
    app=True,
    description=(
        "List approved links filed in a category and in every category beneath "
        "it. Takes the same slug path as browse_category. Pass the after_id from "
        "a previous reply to get the next page; an after_id of 0 in the reply "
        "means there are no more."
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
            list_links,
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


@mcp.tool(
    app=True,
    description=(
        "Search the directory for categories and approved links, matching on "
        "category names and on link titles, URLs and descriptions. Use it to "
        "find an entry point when you do not know the category path."
    ),
)
async def search_directory(
    ctx: Context,
    q: str,
    scope: Literal["both", "links", "categories"] = "both",
    limit: int = DEFAULT_LIMIT,
) -> ToolResult:
    found = await fetch("/api/v1/search", q=q, scope=scope, limit=clamped(limit))
    categories = found["categories"]
    links = found["links"]

    lines = [
        f'"{q}": {counted(len(categories), "category", "categories")}, '
        f'{counted(len(links), "link", "links")}'
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


if __name__ == "__main__":
    mcp.run(
        transport="http",
        host="127.0.0.1",
        port=int(os.environ.get("PORT", "8765")),
    )
