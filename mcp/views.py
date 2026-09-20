from collections.abc import Callable

from fastmcp import Context
from fastmcp.apps import UI_EXTENSION_ID
from fastmcp.tools import ToolResult
from prefab_ui import PrefabApp
from prefab_ui.actions import CallTool
from prefab_ui.components import (
    H3,
    Badge,
    Button,
    Card,
    CardTitle,
    Grid,
    Link,
    Muted,
    Row,
    Small,
)

from client import JSON
from formatting import counted, domain_of

CARD_MIN_WIDTH = "20rem"
CARD_GAP = 3

Section = tuple[str, list[JSON], Callable[[JSON], None]]


def link_card(link: JSON) -> None:
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
                        "browse_category", arguments={"path": link["categoryPath"]}
                    ),
                )


def category_card(category: JSON) -> None:
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
                onClick=CallTool(
                    "browse_category", arguments={"path": category["path"]}
                ),
            )
            Button(
                "Links",
                variant="outline",
                size="xs",
                onClick=CallTool("list_links", arguments={"path": category["path"]}),
            )


def build_view(
    heading: str,
    subheading: str,
    sections: list[Section],
    next_page: tuple[str, JSON] | None = None,
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
            tool_name, arguments = next_page
            Button(
                "Next page",
                variant="outline",
                size="sm",
                css_class="self-start",
                onClick=CallTool(tool_name, arguments=arguments),
            )
    return app


def result(ctx: Context, lines: list[str], view: Callable[[], PrefabApp]) -> ToolResult:
    text = "\n".join(lines)
    if not ctx.client_supports_extension(UI_EXTENSION_ID):
        return ToolResult(content=text)
    return ToolResult(content=text, structured_content=view())
