"""Declaring a tool protected, and enforcing what that means.

The two halves used to live apart: a name in a frozenset here, a role check
written by hand in the tool body. Forgetting the set only weakened the
sign-in prompt, but forgetting the check would let any authenticated caller
run a write, and nothing detected either. ``protect`` makes them one call.
"""

from collections.abc import Callable

from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_access_token

PROTECTED_TOOLS: set[str] = set()


def protect(tool_name: str, *, role: str) -> Callable[[], str]:
    """Register a tool for the 401 challenge and return its token getter.

    Registration and enforcement come from this one call, so a tool cannot be
    challenged without also being checked, nor checked without being
    challenged.

    Args:
        tool_name: The registered tool name, which must match the decorated
            function's name. ``selfcheck`` fails if it names no real tool.
        role: The site-wide role a caller must hold, as it appears in the
            token's ``role`` claim.

    Returns:
        A callable returning the caller's raw access token, for forwarding to
        an API route that verifies it again. It raises ``ToolError`` unless
        the caller is signed in and holds ``role``, so calling it is the
        authorization check; a tool body must not skip it.
    """
    PROTECTED_TOOLS.add(tool_name)

    def caller_token() -> str:
        token = get_access_token()
        if token is None:
            raise ToolError(f"Sign in with an account holding the {role} role.")
        if (token.claims or {}).get("role") != role:
            raise ToolError(f"This tool requires the {role} role.")
        return token.token

    return caller_token
