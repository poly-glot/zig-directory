"""The ASGI layer that lets one server be public and protected at once.

FastMCP's ``auth=`` gates the whole transport, 401-ing even ``initialize``,
and has no anonymous or optional mode. This supplies the missing middle: a
token is verified when offered, and only a call to a registered write tool is
challenged.
"""

import json
from typing import Any, NamedTuple

from fastmcp.server.auth import AccessToken
from fastmcp.utilities.logging import get_logger
from mcp.server.auth.middleware.bearer_auth import AuthenticatedUser
from starlette.authentication import AuthCredentials
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from .config import RESOURCE_METADATA_URL, SCOPE, verifier
from .roles import PROTECTED_TOOLS

MAX_PROBE_BYTES = 1 << 20

logger = get_logger(__name__)


class Authentication(NamedTuple):
    """What a request's ``Authorization`` header turned out to be worth."""

    token: AccessToken | None
    was_supplied: bool


def _bearer_token(scope: Scope) -> str | None:
    """Pull the bearer credential out of an ASGI scope's headers.

    Args:
        scope: The ASGI connection scope.

    Returns:
        The token, or None if no ``Authorization`` header is present, it uses
        another scheme, or it carries no value.
    """
    for name, value in scope.get("headers", []):
        if name.lower() != b"authorization":
            continue
        method, _, token = value.decode("latin-1").partition(" ")
        return token if method.lower() == "bearer" and token else None
    return None


def _calls_protected_tool(message: Any) -> bool:
    """Report whether one JSON-RPC message invokes a registered write tool."""
    if not isinstance(message, dict) or message.get("method") != "tools/call":
        return False
    params = message.get("params")
    return isinstance(params, dict) and params.get("name") in PROTECTED_TOOLS


def _body_calls_protected_tool(body: bytes) -> bool:
    """Report whether a request body invokes a registered write tool.

    Args:
        body: The buffered request body, which may be a single JSON-RPC
            message or a batch, and may not be JSON at all.

    Returns:
        True if any message in it names a tool in ``PROTECTED_TOOLS``. A body
        that will not parse is not a tool call, so it is left to the app.
    """
    if not body:
        return False
    try:
        payload = json.loads(body)
    except ValueError:
        return False
    messages = payload if isinstance(payload, list) else [payload]
    return any(_calls_protected_tool(message) for message in messages)


async def _drain(receive: Receive) -> tuple[bytes, Receive]:
    """Buffer enough of the body to name the tool, then hand it back unchanged.

    Stops at ``MAX_PROBE_BYTES`` so an unauthenticated caller cannot make the
    server hold an arbitrary body before any authorization decision. A body
    that large is not a tool call worth probing.

    Args:
        receive: The ASGI receive channel, which is consumed here.

    Returns:
        The buffered bytes, and a replacement receive channel that replays
        them once before delegating to the real one. When the cap was hit the
        replay reports ``more_body``, leaving the remainder for the app to
        read rather than truncating the request.
    """
    chunks: list[bytes] = []
    size = 0
    more_body = True
    capped = False

    while more_body:
        message = await receive()
        if message["type"] != "http.request":
            more_body = False
            break
        chunk: bytes = message.get("body", b"")
        chunks.append(chunk)
        size += len(chunk)
        more_body = message.get("more_body", False)
        if size > MAX_PROBE_BYTES and more_body:
            capped = True
            break

    body = b"".join(chunks)
    replayed = False

    async def replay() -> Message:
        nonlocal replayed
        if replayed:
            return await receive()
        replayed = True
        return {"type": "http.request", "body": body, "more_body": capped}

    return body, replay


async def _send_challenge(send: Send, *, token_was_supplied: bool) -> None:
    """Answer with the RFC 6750 challenge that starts a client's sign-in.

    Args:
        send: The ASGI send channel.
        token_was_supplied: Whether the caller offered a credential. RFC 6750
            section 3.1 omits ``error`` when none was offered, and reports
            ``invalid_token`` when one was and it failed.
    """
    parts = [
        f'resource_metadata="{RESOURCE_METADATA_URL}"',
        f'scope="{SCOPE}"',
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
    """Authenticate when a token is present, challenge only for write tools.

    A bearer token, when offered, is verified and published the way the SDK's
    own bearer backend does, so a tool body's ``get_access_token()`` sees it.
    An unauthenticated call to a registered write tool is answered with the
    RFC 6750 challenge that drives a client's sign-in flow.

    Opportunistic means no credentials are demanded, not that bad ones are
    ignored: a token that fails to verify is answered with ``invalid_token``
    whatever it was calling, so an expired token is a prompt to refresh rather
    than a silent downgrade to anonymous results. Only a request carrying no
    credentials at all reaches a public tool unauthenticated.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def _authenticate(self, scope: Scope) -> Authentication:
        """Verify the request's bearer token, if it offered one."""
        token = _bearer_token(scope)
        if token is None:
            return Authentication(None, was_supplied=False)
        return Authentication(await verifier.verify_token(token), was_supplied=True)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        authentication = await self._authenticate(scope)

        if authentication.token is not None:
            scope["user"] = AuthenticatedUser(authentication.token)
            scope["auth"] = AuthCredentials(authentication.token.scopes)
        elif authentication.was_supplied:
            logger.info("rejecting a bearer token that did not verify")
            await _send_challenge(send, token_was_supplied=True)
            return
        elif scope["method"] == "POST":
            body, receive = await _drain(receive)
            if _body_calls_protected_tool(body):
                logger.info("challenging unauthenticated call to a protected tool")
                await _send_challenge(send, token_was_supplied=False)
                return

        await self.app(scope, receive, send)
