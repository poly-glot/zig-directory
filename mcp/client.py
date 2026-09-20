"""HTTP access to the Fresh app's ``/api/v1``, the tool layer's only source.

Nothing here speaks dmozdb's binary protocol or touches Deno KV; the web tier
owns both. Transport and API failures surface as ``ToolError`` so a tool body
never has to translate them itself.
"""

import os
from typing import Any, NamedTuple, cast

import httpx2
from fastmcp.exceptions import ToolError

type JSON = dict[str, Any]

UNKNOWN_PATH_HINT = (
    "Use search_directory to find one, or browse_category with an empty path "
    "to start at the top."
)

_api = httpx2.AsyncClient(
    base_url=os.environ.get("DMOZ_API_URL", "http://127.0.0.1:8000"),
    timeout=30,
)


class Browsed(NamedTuple):
    """A category together with the two lists that place it in the tree."""

    category: JSON
    ancestors: list[JSON]
    children: list[JSON]


def _error_detail(response: httpx2.Response) -> str:
    """Relay the API's own 4xx wording, never a 5xx body.

    A 4xx message is written by this project's routes and tells the model how
    to correct the call. A 5xx body is whatever the failure produced, so it is
    reported by status alone rather than handed to the model verbatim.

    Args:
        response: The error response to describe.

    Returns:
        A one-line description safe to show a caller.
    """
    if response.status_code >= 500:
        return f"the directory service failed ({response.status_code})"
    try:
        detail = response.json().get("error")
    except ValueError:
        detail = None
    return str(detail) if detail else f"directory returned {response.status_code}"


def _parse_response(response: httpx2.Response) -> JSON:
    """Decode a successful response.

    Args:
        response: The response to decode.

    Returns:
        The decoded JSON object.

    Raises:
        ToolError: If the response carries a 4xx or 5xx status.
    """
    if response.is_error:
        raise ToolError(_error_detail(response))
    return cast(JSON, response.json())


async def fetch(endpoint: str, **params: str | int) -> JSON:
    """GET ``endpoint``, omitting any parameter passed as the empty string.

    Omitting rather than sending an empty value is what lets
    ``browse_category(path="")`` ask for the top level, instead of asking for
    a category whose path happens to be empty.

    Args:
        endpoint: Path beneath the API base URL, e.g. ``/api/v1/browse``.
        **params: Query parameters. Any equal to ``""`` are left off.

    Returns:
        The decoded JSON object.

    Raises:
        ToolError: If the API answers with an error status.
    """
    response = await _api.get(
        endpoint,
        params={name: value for name, value in params.items() if value != ""},
    )
    return _parse_response(response)


async def post_authorized(endpoint: str, *, token: str, json_body: JSON) -> JSON:
    """POST ``json_body`` to ``endpoint`` as the holder of ``token``.

    The route verifies the bearer token itself rather than trusting a session
    cookie, so the caller's identity survives the hop.

    Args:
        endpoint: Path beneath the API base URL.
        token: The caller's access token, forwarded as a bearer credential.
        json_body: The request body.

    Returns:
        The decoded JSON object.

    Raises:
        ToolError: If the API answers with an error status, including the
            401 and 403 it raises for a token that is missing or unprivileged.
    """
    response = await _api.post(
        endpoint,
        json=json_body,
        headers={"Authorization": f"Bearer {token}"},
    )
    return _parse_response(response)


async def category_at(path: str) -> Browsed:
    """Resolve a slug path to its category, ancestors and children.

    Args:
        path: Slug path such as ``arts/animation``. Empty means the top level.

    Returns:
        The resolved category with its ancestor chain and direct children.

    Raises:
        ToolError: If the API cannot be reached, or if no category sits at
            ``path``. Both carry ``UNKNOWN_PATH_HINT`` so the model is told
            how to find a real path rather than guessing again.
    """
    try:
        browsed = await fetch("/api/v1/browse", path=path)
    except ToolError as unreachable:
        raise ToolError(
            f'no category at path "{path}". {UNKNOWN_PATH_HINT}'
        ) from unreachable

    category = browsed["category"]
    if category is None:
        raise ToolError(f'no category at path "{path}". {UNKNOWN_PATH_HINT}')

    return Browsed(category, browsed["ancestors"], browsed["children"])
