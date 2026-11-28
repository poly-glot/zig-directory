"""Invariants ruff and mypy cannot see. No running server required.

The auth cases guard a security path with no other automated check: a write
tool nobody registered for the 401 challenge, or a registered name that no
longer matches a tool, both type-check cleanly and both break sign-in. The
schema cases guard the contract a model actually reads, which is the input
schema rather than the tool description.
"""

import asyncio
import base64
import json
from collections.abc import AsyncIterator, Sequence
from contextlib import asynccontextmanager
from typing import Any, cast

import httpx2
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastmcp.tools import Tool

from dmozdb_mcp import auth, server, tools  # noqa: F401  (registers routes and tools)
from dmozdb_mcp import client as upstream_client
from dmozdb_mcp.app import mcp_app
from dmozdb_mcp.auth import challenge, config, roles
from dmozdb_mcp.server import build_app


@pytest.fixture(scope="module")
def listed_tools() -> Sequence[Tool]:
    """Every registered tool, as the server would list them."""
    return asyncio.run(mcp_app.list_tools())


@pytest.fixture(scope="module")
def write_tool_names(listed_tools: Sequence[Tool]) -> set[str]:
    """Names of tools that do not declare themselves read-only."""
    return {
        tool.name
        for tool in listed_tools
        if not (tool.annotations and tool.annotations.read_only_hint)
    }


def test_every_protected_name_is_a_real_tool(listed_tools: Sequence[Tool]) -> None:
    unknown = roles.PROTECTED_TOOLS - {tool.name for tool in listed_tools}
    assert not unknown, f"PROTECTED_TOOLS names no such tool: {sorted(unknown)}"


def test_every_write_tool_is_protected(write_tool_names: set[str]) -> None:
    unguarded = write_tool_names - roles.PROTECTED_TOOLS
    assert not unguarded, (
        f"write tools missing from PROTECTED_TOOLS: {sorted(unguarded)}. "
        "Declare them with auth.roles.protect() so an anonymous call is "
        "challenged instead of erroring."
    )


def _tools_call(name: str) -> bytes:
    return (
        b'{"jsonrpc":"2.0","id":1,"method":"tools/call",'
        b'"params":{"name":"' + name.encode() + b'"}}'
    )


def test_body_probe_detects_a_protected_call() -> None:
    protected = next(iter(roles.PROTECTED_TOOLS))
    assert challenge._body_calls_protected_tool(_tools_call(protected))
    assert challenge._body_calls_protected_tool(b"[" + _tools_call(protected) + b"]")


@pytest.mark.parametrize(
    "body",
    [
        pytest.param(b'{"method":"tools/list"}', id="another-method"),
        pytest.param(b"not json at all", id="not-json"),
        pytest.param(b"", id="empty"),
        pytest.param(b'{"method":"tools/call","params":[]}', id="params-not-object"),
    ],
)
def test_body_probe_ignores_everything_else(body: bytes) -> None:
    assert not challenge._body_calls_protected_tool(body)


def test_body_probe_ignores_a_public_tool() -> None:
    assert not challenge._body_calls_protected_tool(_tools_call("browse_category"))


def _scope(header: bytes | None) -> dict[str, object]:
    return {"headers": [(b"authorization", header)] if header else []}


@pytest.mark.parametrize(
    ("header", "expected"),
    [
        pytest.param(b"Bearer abc.def.ghi", "abc.def.ghi", id="bearer"),
        pytest.param(b"bearer abc", "abc", id="lowercase-scheme"),
        pytest.param(b"Basic dXNlcjpwdw==", None, id="another-scheme"),
        pytest.param(b"Bearer", None, id="scheme-only"),
        pytest.param(b"Bearer ", None, id="empty-credential"),
        pytest.param(None, None, id="no-header"),
    ],
)
def test_bearer_parsing(header: bytes | None, expected: str | None) -> None:
    assert challenge._bearer_token(_scope(header)) == expected


def test_every_parameter_is_described(listed_tools: Sequence[Tool]) -> None:
    for tool in listed_tools:
        for name, spec in (tool.parameters.get("properties") or {}).items():
            assert spec.get("description"), (
                f"{tool.name}.{name} has no description. A bare type tells a "
                "model nothing; use Annotated[T, Field(description=...)]."
            )


def test_no_unbounded_integer_parameters(listed_tools: Sequence[Tool]) -> None:
    for tool in listed_tools:
        for name, spec in (tool.parameters.get("properties") or {}).items():
            if spec.get("type") != "integer":
                continue
            assert "minimum" in spec or "maximum" in spec, (
                f"{tool.name}.{name} is an unbounded integer. Mirror the "
                "server-side bound in the schema so a caller can respect it."
            )


INITIALIZE = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "probe", "version": "1"},
    },
}


UI_EXTENSION = "io.modelcontextprotocol/ui"
MCP_HEADERS = {"accept": "application/json, text/event-stream"}


def _initialize_with(capabilities: dict[str, Any]) -> dict[str, Any]:
    params = {**INITIALIZE["params"], "capabilities": capabilities}  # type: ignore[dict-item]
    return {**INITIALIZE, "params": params}


def _rpc_result(response: httpx2.Response) -> dict[str, Any]:
    data = [
        line.removeprefix("data:")
        for line in response.text.splitlines()
        if line.startswith("data:")
    ]
    return cast(dict[str, Any], json.loads(data[-1] if data else response.text))


@asynccontextmanager
async def _serving() -> AsyncIterator[httpx2.AsyncClient]:
    app = build_app()
    async with (
        app.router.lifespan_context(app),
        httpx2.AsyncClient(
            transport=httpx2.ASGITransport(app=app), base_url="http://testserver"
        ) as client,
    ):
        yield client


def test_anonymous_initialize_cannot_open_more_sessions_than_the_cap(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(server, "SESSIONS_MAX", 2)

    async def statuses() -> list[int]:
        async with _serving() as client:
            return [
                (
                    await client.post("/mcp", json=INITIALIZE, headers=MCP_HEADERS)
                ).status_code
                for _ in range(3)
            ]

    assert asyncio.run(statuses()) == [200, 200, 503], (
        "an unauthenticated flood must hit a ceiling, not the pod's memory limit"
    )


def test_sessions_expire_after_a_finite_idle_timeout() -> None:
    async def idle_timeout() -> float | None:
        app = build_app()
        endpoint: Any = next(
            cast(Any, route).endpoint
            for route in app.routes
            if cast(Any, route).path == "/mcp"
        )
        async with app.router.lifespan_context(app):
            timeout: float | None = endpoint.session_manager.session_idle_timeout
            return timeout

    assert asyncio.run(idle_timeout()) == server.SESSION_IDLE_TIMEOUT_S


def test_a_client_advertising_the_ui_extension_gets_a_view_over_http(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    browsed = {
        "category": {
            "id": 1,
            "name": "Arts",
            "path": "arts",
            "linkCountSubtree": 3,
            "childCount": 0,
        },
        "ancestors": [],
        "children": [],
    }
    monkeypatch.setattr(
        upstream_client,
        "_api",
        httpx2.AsyncClient(
            transport=httpx2.MockTransport(
                lambda request: httpx2.Response(200, json=browsed)
            ),
            base_url="http://api.test",
        ),
    )
    call = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {"name": "browse_category", "arguments": {"path": "arts"}},
    }

    async def structured_content(capabilities: dict[str, Any]) -> Any:
        async with _serving() as client:
            opened = await client.post(
                "/mcp", json=_initialize_with(capabilities), headers=MCP_HEADERS
            )
            headers = {
                **MCP_HEADERS,
                "mcp-protocol-version": _rpc_result(opened)["result"][
                    "protocolVersion"
                ],
            }
            if session := opened.headers.get("mcp-session-id"):
                headers["mcp-session-id"] = session
            await client.post(
                "/mcp",
                json={"jsonrpc": "2.0", "method": "notifications/initialized"},
                headers=headers,
            )
            reply = await client.post("/mcp", json=call, headers=headers)
            return _rpc_result(reply)["result"].get("structuredContent")

    with_ui = {
        "extensions": {UI_EXTENSION: {"mimeTypes": ["text/html;profile=mcp-app"]}}
    }

    assert asyncio.run(structured_content(with_ui)) is not None
    assert asyncio.run(structured_content({})) is None


def test_search_directory_names_the_tools_that_follow_it(
    listed_tools: Sequence[Tool],
) -> None:
    search = next(tool for tool in listed_tools if tool.name == "search_directory")

    assert "browse_category" in (search.description or "")
    assert "list_links" in (search.description or "")


def _tool(listed_tools: Sequence[Tool], name: str) -> Tool:
    return next(tool for tool in listed_tools if tool.name == name)


def test_search_query_carries_the_length_bounds_the_route_enforces(
    listed_tools: Sequence[Tool],
) -> None:
    schema = _tool(listed_tools, "search_directory").parameters["properties"]["q"]

    assert schema["minLength"] == 2
    assert schema["maxLength"] == 256


def test_every_cursor_carries_the_ceiling_the_routes_enforce(
    listed_tools: Sequence[Tool],
) -> None:
    cursors = [
        (tool.name, tool.parameters["properties"]["after_id"])
        for tool in listed_tools
        if "after_id" in (tool.parameters.get("properties") or {})
    ]

    assert {name for name, _ in cursors} == {"list_links", "query_links"}
    for name, schema in cursors:
        assert schema["minimum"] == 0, name
        assert schema["maximum"] == 2**53 - 1, name


def test_query_links_names_the_filters_of_which_one_is_required(
    listed_tools: Sequence[Tool],
) -> None:
    description = _tool(listed_tools, "query_links").description or ""

    for filter_name in (
        "category_path",
        "category_names",
        "domain",
        "country",
        "words",
        "entity",
        "religions",
    ):
        assert filter_name in description
    assert "At least one of" in description
    assert "too broad" in description


def _jwks_with(kid: str) -> dict[str, list[dict[str, str]]]:
    numbers = rsa.generate_private_key(65537, 2048).public_key().public_numbers()

    def encode(value: int) -> str:
        raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    key = {
        "kty": "RSA",
        "kid": kid,
        "alg": "RS256",
        "use": "sig",
        "n": encode(numbers.n),
        "e": encode(numbers.e),
    }
    return {"keys": [key]}


def _verifier_counting_fetches() -> tuple[config.MissThrottledVerifier, list[int]]:
    verifier = config.MissThrottledVerifier(jwks_uri="http://jwks.test/jwks.json")
    fetches: list[int] = []

    async def fetch_jwks() -> dict[str, list[dict[str, str]]]:
        fetches.append(1)
        return _jwks_with("k1")

    verifier._fetch_jwks = fetch_jwks  # type: ignore[method-assign]
    return verifier, fetches


def test_unknown_key_ids_do_not_each_cost_a_jwks_fetch() -> None:
    verifier, fetches = _verifier_counting_fetches()

    async def present_unknown_kids() -> None:
        for kid in ("a", "b", "c", "a"):
            with pytest.raises(ValueError, match="not found in JWKS"):
                await verifier._get_jwks_key(kid)

    asyncio.run(present_unknown_kids())

    assert len(fetches) == 1


def test_a_cached_key_id_is_served_without_a_fetch_after_a_miss() -> None:
    verifier, fetches = _verifier_counting_fetches()

    async def verify() -> str:
        await verifier._get_jwks_key("k1")
        with pytest.raises(ValueError, match="not found in JWKS"):
            await verifier._get_jwks_key("unknown")
        return await verifier._get_jwks_key("k1")

    assert asyncio.run(verify()).startswith("-----BEGIN PUBLIC KEY-----")
    assert len(fetches) == 1


def test_an_unknown_key_id_is_retried_once_the_miss_interval_has_passed() -> None:
    verifier, fetches = _verifier_counting_fetches()

    async def miss_twice() -> None:
        with pytest.raises(ValueError, match="not found in JWKS"):
            await verifier._get_jwks_key("unknown")
        verifier._last_miss_fetch_s -= config.JWKS_MISS_INTERVAL_S + 1
        with pytest.raises(ValueError, match="not found in JWKS"):
            await verifier._get_jwks_key("unknown")

    asyncio.run(miss_twice())

    assert len(fetches) == 2
