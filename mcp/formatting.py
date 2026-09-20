"""The text summaries every tool returns, and the paging bounds they honour.

These strings are the tool layer's machine-readable contract, not decoration.
Three of four tools return ``ToolResult``, which FastMCP cannot infer an
output schema from, and ``structuredContent`` carries the MCP Apps payload
rather than data — so this text is the only channel every client receives.
The tokens a caller needs in order to make the next call (``path "x/y"``,
``after_id=N``) must stay verbatim and stable here; tool descriptions tell a
model to look for them.
"""

from urllib.parse import urlsplit

from client import JSON

DEFAULT_LIMIT = 20
MAX_LIMIT = 50


def counted(count: int, singular: str, plural: str) -> str:
    return f"{count:,} {singular if count == 1 else plural}"


def domain_of(url: str) -> str:
    return urlsplit(url).netloc.removeprefix("www.")


def category_summary(category: JSON) -> str:
    """Summarise a category, ending in the quoted path used to descend.

    Args:
        category: A category object from ``/api/v1``.

    Returns:
        One line carrying the name, its subtree counts, and its slug path in
        double quotes — the form ``browse_category`` and ``list_links`` both
        take back as their ``path`` argument.
    """
    links = counted(category["linkCountSubtree"], "link", "links")
    children = counted(category["childCount"], "subcategory", "subcategories")
    return f'{category["name"]} — {links}, {children}, path "{category["path"]}"'


def link_summary(link: JSON) -> str:
    """Summarise one link, with its category path and description if present.

    Args:
        link: A link object from ``/api/v1``.

    Returns:
        A line of ``title — url``, optionally followed by a bracketed category
        path and an indented description on the next line.
    """
    where = f" [{link['categoryPath']}]" if link.get("categoryPath") else ""
    described = f"\n  {link['description']}" if link["description"] else ""
    return f"{link['title']} — {link['url']}{where}{described}"


def cursor_summary(next_after_id: int) -> str:
    """State whether another page exists, and how to ask for it.

    Args:
        next_after_id: The cursor the API returned; 0 means no more rows.

    Returns:
        Either an end-of-results line, or the ``after_id=N`` a caller passes
        back to ``list_links`` for the next page.
    """
    if next_after_id == 0:
        return "End of results."
    return f"More available: call again with after_id={next_after_id}."
