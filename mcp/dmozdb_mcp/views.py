"""Prefab cards, and the envelope every tool's view is wrapped in.

Views are built only for clients that advertise the MCP Apps extension;
everyone else gets the text summary alone and never pays for a component
tree. Cards call other tools by name rather than importing them, which is
what keeps this module free of ``tools/``.
"""

from collections.abc import Callable
from typing import NamedTuple

from fastmcp import Context
from fastmcp.apps import UI_EXTENSION_ID
from fastmcp.tools import ToolResult
from prefab_ui import PrefabApp
from prefab_ui.actions import CallTool, SetState
from prefab_ui.components import (
    H3,
    Badge,
    Button,
    Card,
    CardTitle,
    Div,
    Grid,
    Link,
    Muted,
    Row,
    Slot,
    Small,
)
from prefab_ui.rx import RESULT

from dmozdb_mcp import formatting
from dmozdb_mcp.client import JSON

CARD_MIN_WIDTH = "20rem"
CARD_GAP = 3
VIEW_SLOT = "view"

Renderer = Callable[[JSON], None]


class Section(NamedTuple):
    """One labelled group of cards within a view."""

    label: str
    items: list[JSON]
    render: Renderer


class NextPage(NamedTuple):
    """The tool call that fetches the page after the one being rendered."""

    tool_name: str
    arguments: JSON


def _replacement_body() -> object:
    """Address the content a replying tool's view should be swapped in for.

    ``build_view`` nests its content two levels deep — ``PrefabApp`` adds an
    implicit ``pf-app-root`` Div, inside which sits the ``Slot`` this targets,
    and inside that the Div holding the cards. Binding to the reply's inner
    Div therefore replaces the cards while leaving the Slot itself in place.

    Binding one level shallower targets the Slot, which makes it contain
    itself; that self-reference hangs the renderer rather than failing, so the
    depth is load-bearing and belongs in one place.
    """
    return RESULT.view.children[0].children[0]


def navigate(tool_name: str, arguments: JSON) -> CallTool:
    """Build the click action that replaces this view with another tool's.

    Args:
        tool_name: The tool to call, by registered name.
        arguments: Its arguments.

    Returns:
        A ``CallTool`` action that swaps the reply's cards into this view's
        slot on success.
    """
    return CallTool(
        tool_name,
        arguments=arguments,
        on_success=SetState(VIEW_SLOT, _replacement_body()),
    )


def link_card(link: JSON) -> None:
    """Render one link as a card, with a Browse button for its category."""
    with Card(css_class="p-4 flex flex-col gap-1"):
        Link(
            link["title"],
            href=link["url"],
            target="_blank",
            css_class="font-medium leading-snug",
        )
        Small(formatting.domain_of(link["url"]), css_class="text-muted-foreground")
        if link["description"]:
            Muted(link["description"], css_class="text-sm")
        if link.get("categoryPath"):
            with Row(gap=2, align="center", css_class="pt-1"):
                Badge(link["categoryPath"], variant="secondary")
                Button(
                    "Browse",
                    variant="ghost",
                    size="xs",
                    onClick=navigate("browse_category", {"path": link["categoryPath"]}),
                )


def category_card(category: JSON) -> None:
    """Render one category as a card, with Open and Links buttons."""
    with Card(css_class="p-4 flex flex-col gap-2"):
        CardTitle(category["name"], css_class="text-base")
        links = formatting.counted(category["linkCountSubtree"], "link", "links")
        children = formatting.counted(
            category["childCount"], "subcategory", "subcategories"
        )
        Muted(f"{links} · {children}", css_class="text-sm")
        with Row(gap=2):
            Button(
                "Open",
                size="xs",
                onClick=navigate("browse_category", {"path": category["path"]}),
            )
            Button(
                "Links",
                variant="outline",
                size="xs",
                onClick=navigate("list_links", {"path": category["path"]}),
            )


def build_view(
    heading: str,
    subheading: str,
    sections: list[Section],
    next_page: NextPage | None = None,
) -> PrefabApp:
    """Assemble one tool's view: a heading, card grids, and maybe a pager.

    Args:
        heading: The view title.
        subheading: A line beneath it; omitted when empty.
        sections: Card groups in order. Empty ones are skipped, and a section
            with no label renders its grid without a heading.
        next_page: The call that fetches the following page, if there is one.

    Returns:
        The app, with its content inside the slot ``navigate`` replaces.
    """
    with (
        PrefabApp(title=heading, css_class="p-4 flex flex-col gap-4") as app,
        Slot(VIEW_SLOT),
        Div(css_class="flex flex-col gap-4"),
    ):
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
            Button(
                "Next page",
                variant="outline",
                size="sm",
                css_class="self-start",
                onClick=navigate(next_page.tool_name, next_page.arguments),
            )
    return app


def result(ctx: Context, lines: list[str], view: Callable[[], PrefabApp]) -> ToolResult:
    """Pair a tool's text summary with a view, for clients that can show one.

    Args:
        ctx: The tool's context, used to read the client's advertised
            extensions.
        lines: The text summary, one element per line.
        view: Builds the view. Taken unbuilt, and never called for a client
            without the MCP Apps extension, so those clients pay nothing for
            a component tree they cannot render.

    Returns:
        The text alone, or the text plus the view.
    """
    text = "\n".join(lines)
    if not ctx.client_supports_extension(UI_EXTENSION_ID):
        return ToolResult(content=text)
    return ToolResult(content=text, structured_content=view())
