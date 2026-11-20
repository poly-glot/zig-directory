"""What sits next to a site, a category or a named entity in the directory."""

from typing import Annotated, Literal

from mcp_types import ToolAnnotations
from pydantic import Field

from dmozdb_mcp import client, formatting
from dmozdb_mcp.app import mcp_app
from dmozdb_mcp.client import JSON
from dmozdb_mcp.formatting import MAX_LIMIT

DEFAULT_RELATED = 10

type RelatedKind = Literal["site", "category", "entity"]


def _site_line(neighbour: JSON) -> str:
    shared = formatting.counted(neighbour["shared"], "category", "categories")
    return f"{neighbour['name']} — filed together in {shared}"


def _entity_line(neighbour: JSON) -> str:
    shared = formatting.counted(neighbour["shared"], "link", "links")
    return f"{neighbour['name']} — named together on {shared}"


def _category_line(neighbour: JSON) -> str:
    why = "same name" if neighbour["sameName"] else "similar subject"
    return f"{formatting.category_summary(neighbour)} ({why})"


_LINE = {"site": _site_line, "entity": _entity_line, "category": _category_line}
_HEADING = {
    "site": "Sites filed in the same categories as {of}:",
    "entity": "People and organisations named on the same links as {of}:",
    "category": 'Categories related to path "{of}":',
}


@mcp_app.tool(
    description=(
        "Find what is related to a site, a category or a named person or "
        "organisation. For a site: other sites editors filed in the same "
        "categories, so it answers 'sites like imdb.com'. For a category: "
        "other categories with the same name elsewhere in the tree, then "
        "categories on a similar subject. For an entity: the people and "
        "organisations named on the same links. Follow a site with "
        "query_links(domain=...), a category with browse_category or "
        "list_links on its path, and an entity with query_links(entity=...)."
    ),
    annotations=ToolAnnotations(
        title="Find related sites, categories or names",
        read_only_hint=True,
        idempotent_hint=True,
        open_world_hint=False,
    ),
)
async def find_related(
    kind: Annotated[
        RelatedKind,
        Field(
            description=(
                "What `of` is: site for a domain, category for a slug path, "
                "entity for the name of a person or organisation."
            )
        ),
    ],
    of: Annotated[
        str,
        Field(
            min_length=1,
            max_length=256,
            description=(
                'The thing to find neighbours of: a domain such as "imdb.com", '
                'a slug path such as "science/math/number_theory" from '
                "browse_category or search_directory, or a name such as "
                '"United Nations" as query_links reports it.'
            ),
        ),
    ],
    limit: Annotated[
        int,
        Field(ge=1, le=MAX_LIMIT, description="How many neighbours to return."),
    ] = DEFAULT_RELATED,
) -> str:
    """List the neighbours of one site, category or entity.

    Args:
        kind: Which kind of thing ``of`` names.
        of: The domain, slug path or name to start from.
        limit: The most neighbours to return.

    Returns:
        A heading and one line per neighbour, nearest first. A category line
        carries the quoted path ``browse_category`` takes.

    Raises:
        ToolError: If ``of`` is not a domain, an existing path or a name the
            API accepts for ``kind``.
    """
    found = await client.fetch("/api/v1/neighbours", kind=kind, of=of, limit=limit)
    neighbours = found["neighbours"]
    if not neighbours:
        return f"Nothing in the directory is related to {of} as a {kind}."

    lines = [_HEADING[kind].format(of=of)]
    lines += [_LINE[kind](neighbour) for neighbour in neighbours]
    return "\n".join(lines)
