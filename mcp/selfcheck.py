"""Assert the invariants ruff and mypy cannot see.

Run: uv run python selfcheck.py

Two kinds of thing live here. The auth invariants guard a security path that
has no other automated check: a write tool that nobody registered for the 401
challenge, or a protected name that no longer matches a tool, both type-check
cleanly and both break sign-in. The schema invariants guard the contract a
model actually reads, which is the input schema rather than the prose.
"""

import asyncio

import auth  # noqa: F401  (registers the protected-resource route)
import tools  # noqa: F401  (registers the tools, and their protect() calls)
from app import mcp
from auth.challenge import _bearer_token, _body_calls_protected_tool
from auth.roles import PROTECTED_TOOLS

SCHEMA_EXEMPT_BOUNDS = {"path", "q", "decision", "search_in"}


def check_no_auth_drift(tool_names: set[str], writes: set[str]) -> None:
    unknown = PROTECTED_TOOLS - tool_names
    assert not unknown, f"PROTECTED_TOOLS names no such tool: {sorted(unknown)}"

    unguarded = writes - PROTECTED_TOOLS
    assert not unguarded, (
        f"write tools missing from PROTECTED_TOOLS: {sorted(unguarded)}. "
        "Declare them with auth.roles.protect() so an anonymous call is "
        "challenged instead of erroring."
    )


def check_body_probe() -> None:
    def call(name: str) -> bytes:
        return (
            b'{"jsonrpc":"2.0","id":1,"method":"tools/call",'
            b'"params":{"name":"' + name.encode() + b'"}}'
        )

    protected = next(iter(PROTECTED_TOOLS))

    assert _body_calls_protected_tool(call(protected))
    assert _body_calls_protected_tool(b"[" + call(protected) + b"]")
    assert not _body_calls_protected_tool(call("browse_category"))
    assert not _body_calls_protected_tool(b'{"method":"tools/list"}')
    assert not _body_calls_protected_tool(b"not json at all")
    assert not _body_calls_protected_tool(b"")
    assert not _body_calls_protected_tool(b'{"method":"tools/call","params":[]}')


def check_bearer_parsing() -> None:
    def scope(header: bytes | None) -> dict[str, object]:
        return {"headers": [(b"authorization", header)] if header else []}

    assert _bearer_token(scope(b"Bearer abc.def.ghi")) == "abc.def.ghi"
    assert _bearer_token(scope(b"bearer abc")) == "abc"
    assert _bearer_token(scope(b"Basic dXNlcjpwdw==")) is None
    assert _bearer_token(scope(b"Bearer")) is None
    assert _bearer_token(scope(b"Bearer ")) is None
    assert _bearer_token(scope(None)) is None


def check_schemas(schemas: dict[str, dict[str, object]]) -> None:
    for name, schema in schemas.items():
        properties = schema.get("properties") or {}
        assert isinstance(properties, dict)
        for param, spec in properties.items():
            assert spec.get("description"), (
                f"{name}.{param} has no description. A bare type tells a "
                "model nothing; use Annotated[T, Field(description=...)]."
            )
            if param in SCHEMA_EXEMPT_BOUNDS or spec.get("type") != "integer":
                continue
            assert "minimum" in spec or "maximum" in spec, (
                f"{name}.{param} is an unbounded integer. Mirror the "
                "server-side bound in the schema so a caller can respect it."
            )


async def main() -> None:
    listed = await mcp.list_tools()
    tool_names = {t.name for t in listed}
    writes = {
        t.name for t in listed if not (t.annotations and t.annotations.read_only_hint)
    }
    schemas = {t.name: t.parameters for t in listed}

    check_no_auth_drift(tool_names, writes)
    check_body_probe()
    check_bearer_parsing()
    check_schemas(schemas)

    print(
        f"selfcheck: ok — {len(tool_names)} tools, "
        f"{len(writes)} write ({', '.join(sorted(writes))}), "
        f"all protected and all parameters described"
    )


if __name__ == "__main__":
    asyncio.run(main())
