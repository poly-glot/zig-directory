import json
from typing import Any

from fastmcp.server.auth import AccessToken
from fastmcp.utilities.logging import get_logger
from mcp.server.auth.middleware.bearer_auth import AuthenticatedUser
from starlette.authentication import AuthCredentials
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from auth import RESOURCE_METADATA_URL, SCOPES, verifier

PROTECTED_TOOLS = frozenset({"review_submission"})

logger = get_logger(__name__)


def _bearer_token(scope: Scope) -> str | None:
    for name, value in scope.get("headers", []):
        if name.lower() != b"authorization":
            continue
        method, _, token = value.decode("latin-1").partition(" ")
        return token if method.lower() == "bearer" and token else None
    return None


def _protected_tool_called(message: Any) -> str | None:
    if not isinstance(message, dict) or message.get("method") != "tools/call":
        return None
    params = message.get("params")
    if not isinstance(params, dict):
        return None
    name = params.get("name")
    return name if name in PROTECTED_TOOLS else None


def _body_protected_tool(body: bytes) -> str | None:
    if not body:
        return None
    try:
        payload = json.loads(body)
    except ValueError:
        return None
    messages = payload if isinstance(payload, list) else [payload]
    for message in messages:
        name = _protected_tool_called(message)
        if name is not None:
            return name
    return None


async def _drain(receive: Receive) -> tuple[bytes, Receive]:
    chunks: list[bytes] = []
    more_body = True
    while more_body:
        message = await receive()
        if message["type"] != "http.request":
            break
        chunks.append(message.get("body", b""))
        more_body = message.get("more_body", False)
    body = b"".join(chunks)

    replayed = False

    async def replay() -> Message:
        nonlocal replayed
        if replayed:
            return await receive()
        replayed = True
        return {"type": "http.request", "body": body, "more_body": False}

    return body, replay


async def _send_challenge(send: Send, *, token_was_supplied: bool) -> None:
    parts = [
        f'resource_metadata="{RESOURCE_METADATA_URL}"',
        f'scope="{" ".join(SCOPES)}"',
    ]
    if token_was_supplied:
        parts.insert(0, 'error="invalid_token"')
    await send(
        {
            "type": "http.response.start",
            "status": 401,
            "headers": [
                (b"content-length", b"0"),
                (b"www-authenticate", f"Bearer {', '.join(parts)}".encode()),
            ],
        }
    )
    await send({"type": "http.response.body", "body": b""})


class OpportunisticAuth:
    """Authenticate when a token is present, challenge only for protected tools.

    FastMCP's own ``auth=`` gates the whole transport, which would force a
    sign-in before anyone could read a public directory. This verifies a bearer
    token when one is offered and publishes the identity the way the SDK's own
    bearer backend does, so a tool body's ``get_access_token()`` sees it, then
    answers an unauthenticated call to a protected tool with the RFC 6750
    challenge that drives a client's sign-in flow.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def _authenticate(self, scope: Scope) -> tuple[AccessToken | None, bool]:
        token = _bearer_token(scope)
        if token is None:
            return None, False
        return await verifier.verify_token(token), True

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        access_token, token_was_supplied = await self._authenticate(scope)
        if access_token is not None:
            scope["user"] = AuthenticatedUser(access_token)
            scope["auth"] = AuthCredentials(access_token.scopes)

        if access_token is None and scope["method"] == "POST":
            body, receive = await _drain(receive)
            tool = _body_protected_tool(body)
            if tool is not None:
                logger.info("challenging unauthenticated call to %s", tool)
                await _send_challenge(send, token_was_supplied=token_was_supplied)
                return

        await self.app(scope, receive, send)
