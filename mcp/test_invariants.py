"""Invariants ruff and mypy cannot see. No running server required.

The auth cases guard a security path with no other automated check: a write
tool nobody registered for the 401 challenge, or a registered name that no
longer matches a tool, both type-check cleanly and both break sign-in. The
schema cases guard the contract a model actually reads, which is the input
schema rather than the tool description.
"""

import asyncio
from collections.abc import Sequence

import pytest
from fastmcp.tools import Tool

import auth  # noqa: F401  (registers the protected-resource route)
import tools  # noqa: F401  (registers the tools, and their protect() calls)
from app import mcp_app
from auth.challenge import _bearer_token, _body_calls_protected_tool
from auth.roles import PROTECTED_TOOLS


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
    unknown = PROTECTED_TOOLS - {tool.name for tool in listed_tools}
    assert not unknown, f"PROTECTED_TOOLS names no such tool: {sorted(unknown)}"


def test_every_write_tool_is_protected(write_tool_names: set[str]) -> None:
    unguarded = write_tool_names - PROTECTED_TOOLS
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
    protected = next(iter(PROTECTED_TOOLS))
    assert _body_calls_protected_tool(_tools_call(protected))
    assert _body_calls_protected_tool(b"[" + _tools_call(protected) + b"]")


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
    assert not _body_calls_protected_tool(body)


def test_body_probe_ignores_a_public_tool() -> None:
    assert not _body_calls_protected_tool(_tools_call("browse_category"))


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
    assert _bearer_token(_scope(header)) == expected


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
