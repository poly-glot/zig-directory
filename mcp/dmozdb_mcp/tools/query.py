from typing import Annotated, Literal

from fastmcp import Context
from fastmcp.apps import PrefabAppConfig
from fastmcp.tools import ToolResult
from mcp_types import ToolAnnotations
from pydantic import Field

from dmozdb_mcp import client, formatting, views
from dmozdb_mcp.app import mcp_app
from dmozdb_mcp.client import JSON
from dmozdb_mcp.formatting import MAX_LIMIT

MAX_GROUPS = 50
DEFAULT_GROUPS = 10
DEFAULT_PAGE = 10

type GroupBy = Literal[
    "none", "domain", "site", "host", "branch", "country", "religion", "person", "org"
]
type CountryEdge = Literal["cctld", "category", "entity"]
type Religion = Literal[
    "islam",
    "christianity",
    "judaism",
    "hinduism",
    "buddhism",
    "sikhism",
    "taoism",
    "jainism",
    "bahai",
    "shinto",
    "paganism",
]
ALL_EDGES: tuple[CountryEdge, ...] = ("cctld", "category", "entity")


def _headline(found: JSON) -> str:
    links = formatting.counted(found["total"], "link", "links")
    sites = formatting.counted(found["sites"], "site", "sites")
    hosts = formatting.counted(found["hosts"], "host", "hosts")
    domains = formatting.counted(found["domains"], "domain", "domains")
    return f"{links} on {sites} ({hosts}, {domains})"


def _group_line(group: JSON) -> str:
    links = formatting.counted(group["links"], "link", "links")
    sites = formatting.counted(group["sites"], "site", "sites")
    return f"  {group['key']} — {links}, {sites}"


def _summarize(found: JSON, group_by: str) -> list[str]:
    lines = [_headline(found)]
    if found["groups"]:
        lines.append(f"By {group_by}:")
        lines += [_group_line(group) for group in found["groups"]]
    if found["links"]:
        lines.append("Links:")
        lines += [formatting.link_summary(link) for link in found["links"]]
    lines.append(formatting.cursor_summary(found["nextAfterId"]))
    return lines


@mcp_app.tool(
    app=PrefabAppConfig(),
    description=(
        "Count, filter and group approved links by facts the directory holds: "
        "the site's domain and hosting (subdomain sites such as x.tripod.com "
        "and path sites such as members.tripod.com/~x each count as one "
        "site), the countries tied to a link by its country-code domain, by a "
        "category named for the country or by places and nationalities named "
        "in its text, the religions it is about, the people and organisations "
        "it names, its category subtree, and optional keywords. Use it for "
        "how many, which domains, which countries, which religions, or links "
        "naming someone; use search_directory to find sites by meaning. "
        "Category paths come from browse_category or search_directory. Pass "
        "the after_id from a reply to get the next page of links."
    ),
    annotations=ToolAnnotations(
        title="Count and group links",
        read_only_hint=True,
        idempotent_hint=True,
        open_world_hint=False,
    ),
)
async def query_links(
    ctx: Context,
    domain: Annotated[
        str,
        Field(
            max_length=64,
            description=(
                'Host or domain suffix, matched on whole labels: "tripod.com" '
                'covers every *.tripod.com host, "pk" every .pk host, "ac.uk" '
                "UK universities. Empty for any domain."
            ),
        ),
    ] = "",
    country: Annotated[
        str,
        Field(
            pattern="^([A-Za-z]{2})?$",
            description=(
                'ISO 3166 two-letter country code such as "PK" or "GB". Empty '
                "for any country."
            ),
        ),
    ] = "",
    country_via: Annotated[
        tuple[CountryEdge, ...],
        Field(
            min_length=1,
            description=(
                "Which ties count for the country: the site's country-code "
                "domain (cctld), a category named for the country (category), "
                "places and nationalities named in the link's text (entity)."
            ),
        ),
    ] = ALL_EDGES,
    religions: Annotated[
        tuple[Religion, ...],
        Field(
            description=(
                "Only links about any of these religions. Empty for no religion filter."
            )
        ),
    ] = (),
    entity: Annotated[
        str,
        Field(
            max_length=64,
            description=(
                "A person or organisation the link names, matched as a whole "
                'name in any case, such as "Jamia Farooqia". Empty for none.'
            ),
        ),
    ] = "",
    category_path: Annotated[
        str,
        Field(
            description=(
                'Slug path of a category such as "arts/animation", from '
                "browse_category or search_directory; links in every category "
                "beneath it are included. Empty for the whole directory."
            )
        ),
    ] = "",
    hosted_only: Annotated[
        bool,
        Field(
            description=(
                "Only personal sites on hosting platforms such as tripod, "
                "angelfire, blogspot and ~user pages."
            )
        ),
    ] = False,
    words: Annotated[
        str,
        Field(
            max_length=256,
            description=(
                "Keywords a link's title, URL or description must contain, "
                "whole words of two or more letters. Empty for no keyword "
                "filter."
            ),
        ),
    ] = "",
    match_all_words: Annotated[
        bool,
        Field(description="Require every word instead of any one of them."),
    ] = False,
    group_by: Annotated[
        GroupBy,
        Field(
            description=(
                "Tally the matching links by domain, site, host, top-level "
                "branch, country, religion, person or organisation, largest "
                "first. none for totals only."
            )
        ),
    ] = "none",
    groups: Annotated[
        int,
        Field(ge=0, le=MAX_GROUPS, description="How many groups to return."),
    ] = DEFAULT_GROUPS,
    limit: Annotated[
        int,
        Field(
            ge=0,
            le=MAX_LIMIT,
            description="How many matching links to list; 0 for counts only.",
        ),
    ] = DEFAULT_PAGE,
    after_id: Annotated[
        int,
        Field(
            ge=0,
            description=(
                "Cursor for the next page of links: pass the after_id this "
                "tool reported last time. 0 starts at the first page."
            ),
        ),
    ] = 0,
) -> ToolResult:
    found = await client.fetch(
        "/api/v1/links/query",
        domain=domain,
        country=country,
        via=",".join(country_via),
        religion=",".join(religions),
        entity=entity,
        category=category_path,
        hosted="1" if hosted_only else "",
        words=words,
        match="all" if match_all_words else "any",
        group=group_by,
        groups=groups,
        limit=limit,
        after=after_id,
    )
    lines = _summarize(found, group_by)

    arguments = {
        "domain": domain,
        "country": country,
        "country_via": list(country_via),
        "religions": list(religions),
        "entity": entity,
        "category_path": category_path,
        "hosted_only": hosted_only,
        "words": words,
        "match_all_words": match_all_words,
        "group_by": group_by,
        "groups": groups,
        "limit": limit,
        "after_id": found["nextAfterId"],
    }
    next_page = (
        views.NextPage("query_links", arguments) if found["nextAfterId"] else None
    )

    return views.result(
        ctx,
        lines,
        lambda: views.build_view(
            "Links by facts",
            lines[0],
            [views.Section("", found["links"], views.link_card)],
            next_page=next_page,
        ),
    )
