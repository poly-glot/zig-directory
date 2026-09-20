from urllib.parse import urlsplit

from client import JSON

DEFAULT_LIMIT = 20
MAX_LIMIT = 50


def counted(count: int, singular: str, plural: str) -> str:
    return f"{count:,} {singular if count == 1 else plural}"


def domain_of(url: str) -> str:
    return urlsplit(url).netloc.removeprefix("www.")


def category_summary(category: JSON) -> str:
    links = counted(category["linkCountSubtree"], "link", "links")
    children = counted(category["childCount"], "subcategory", "subcategories")
    return f'{category["name"]} — {links}, {children}, path "{category["path"]}"'


def link_summary(link: JSON) -> str:
    where = f" [{link['categoryPath']}]" if link.get("categoryPath") else ""
    described = f"\n  {link['description']}" if link["description"] else ""
    return f"{link['title']} — {link['url']}{where}{described}"


def cursor_summary(next_after_id: int) -> str:
    if next_after_id == 0:
        return "End of results."
    return f"More available: call again with after_id={next_after_id}."
