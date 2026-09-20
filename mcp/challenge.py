import json
from typing import Any

from fastmcp.server.auth import AccessToken
from mcp.server.auth.middleware.bearer_auth import AuthenticatedUser
from starlette.authentication import AuthCredentials
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from auth import RESOURCE_METADATA_URL, verifier

PROTECTED_TOOLS = frozenset({"review_submission"})


def _bearer_token(scope: Scope) -> str | None:
    for name, value in scope.get("headers", []):
        if name.lower() != b"authorization":
            continue
        method, _, token = value.decode("latin-1").partition(" ")
        return token if method.lower() == "bearer" and token else None
    return None


def _calls_protected_tool(message: Any) -> bool:
    if not isinstance(message, dict) or message.get("method") != "tools/call":
        return False
    params = message.get("params")
    return isinstance(params, dict) and params.get("name") in PROTECTED_TOOLS


def _body_calls_protected_tool(body: bytes) -> bool:
    if not body:
        return False
    try:
        payload = json.loads(body)
    except ValueError:
        return False
    if isinstance(payload, list):
        return any(_calls_protected_tool(message) for message in payload)
    return _calls_protected_tool(payload)


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
    parts = [f'resource_metadata="{RESOURCE_METADATA_URL}"']
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
    bearer backend does, so ``require_roles`` and ``tools/list`` filtering keep
    working, then answers an unauthenticated call to a protected tool with the
    RFC 6750 challenge that drives a client's sign-in flow.
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
            if _body_calls_protected_tool(body):
                await _send_challenge(send, token_was_supplied=token_was_supplied)
                return

        await self.app(scope, receive, send)
