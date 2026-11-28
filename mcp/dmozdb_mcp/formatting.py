"""The text summaries every tool returns, and the paging bounds they honour.

These strings are the tool layer's machine-readable contract, not decoration.
Most tools return ``ToolResult``, which FastMCP cannot infer an
output schema from, and ``structuredContent`` carries the MCP Apps payload
rather than data — so this text is the only channel every client receives.
The tokens a caller needs in order to make the next call (``path "x/y"``,
``after_id=N``) must stay verbatim and stable here; tool descriptions tell a
model to look for them.
"""

import re
from urllib.parse import urlsplit

from pydantic import AfterValidator

from dmozdb_mcp.client import JSON

DEFAULT_LIMIT = 20
MAX_LIMIT = 50
MAX_AFTER_ID = 2**53 - 1

_LINE_BREAKING_RUN = re.compile(r"[\s\x00-\x1f\x7f-\x9f]+")


def single_line(text: str) -> str:
    """Collapse stored text onto one line.

    Stored titles, descriptions and names are written by strangers. A newline
    in one could forge a line of the summary, such as the cursor or end of
    results line a caller relies on, so every run of whitespace or control
    characters becomes one space.
    """
    return _LINE_BREAKING_RUN.sub(" ", text).strip()


def utf8_bytes_at_most(limit: int) -> AfterValidator:
    """Refuse a string longer than ``limit`` bytes of UTF-8.

    The routes and the backend cap these parameters in bytes, which JSON Schema
    cannot express, so the bound is enforced here and each description states
    it. ``max_length`` stays beside it as the character ceiling a caller can
    see in the schema.
    """

    def check(value: str) -> str:
        if len(value.encode()) > limit:
            raise ValueError(f"must be at most {limit} bytes of UTF-8")
        return value

    return AfterValidator(check)


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
    name = single_line(category["name"])
    path = single_line(category["path"])
    return f'{name} — {links}, {children}, path "{path}"'


def link_summary(link: JSON) -> str:
    """Summarise one link, with its category path and description if present.

    Args:
        link: A link object from ``/api/v1``.

    Returns:
        A line of ``title — url``, optionally followed by a bracketed category
        path and an indented description on the next line.
    """
    category_path = single_line(link.get("categoryPath") or "")
    where = f" [{category_path}]" if category_path else ""
    description = single_line(link["description"] or "")
    described = f"\n  {description}" if description else ""
    return (
        f"{single_line(link['title'])} — {single_line(link['url'])}{where}{described}"
    )


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
