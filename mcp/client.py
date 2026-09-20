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


def _error_detail(response: httpx2.Response) -> str:
    """Relay the API's own 4xx wording, never a 5xx body.

    A 4xx message is written by this project's routes and tells the model how
    to correct the call. A 5xx body is whatever the failure produced, so it is
    reported by status alone rather than handed to the model verbatim.
    """
    if response.status_code >= 500:
        return f"the directory service failed ({response.status_code})"
    try:
        detail = response.json().get("error")
    except ValueError:
        detail = None
    return str(detail) if detail else f"directory returned {response.status_code}"


def _parse_response(response: httpx2.Response) -> JSON:
    if response.is_error:
        raise ToolError(_error_detail(response))
    return cast(JSON, response.json())


async def fetch(endpoint: str, **params: str | int) -> JSON:
    response = await api.get(
        endpoint,
        params={k: v for k, v in params.items() if v is not None and v != ""},
    )
    return _parse_response(response)


async def post_authorized(endpoint: str, *, token: str, json_body: JSON) -> JSON:
    response = await api.post(
        endpoint,
        json=json_body,
        headers={"Authorization": f"Bearer {token}"},
    )
    return _parse_response(response)


async def category_at(path: str) -> tuple[JSON, list[JSON], list[JSON]]:
    try:
        browsed = await fetch("/api/v1/browse", path=path)
    except ToolError as unreachable:
        raise ToolError(
            f'no category at path "{path}". {UNKNOWN_PATH_HINT}'
        ) from unreachable
    category = browsed["category"]
    if category is None:
        raise ToolError(f'no category at path "{path}". {UNKNOWN_PATH_HINT}')
    return category, browsed["ancestors"], browsed["children"]
