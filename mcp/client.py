import os
from typing import Any, cast

import httpx2
from fastmcp.exceptions import ToolError

type JSON = dict[str, Any]

api = httpx2.AsyncClient(
    base_url=os.environ.get("DMOZ_API_URL", "http://127.0.0.1:8000"),
    timeout=30,
)

UNKNOWN_PATH_HINT = (
    "Use search_directory to find one, or browse_category with an empty path "
    "to start at the top."
)


async def fetch(endpoint: str, **params: str | int) -> JSON:
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
    return cast(JSON, response.json())


async def category_at(path: str) -> tuple[JSON, list[JSON], list[JSON]]:
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
