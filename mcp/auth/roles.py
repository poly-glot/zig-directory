from collections.abc import Callable

from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_access_token

PROTECTED_TOOLS: set[str] = set()


def protect(tool_name: str, *, role: str) -> Callable[[], str]:
    """Register a tool for the 401 challenge and return its access-token getter.

    Registration and enforcement come from this one call, so a tool cannot be
    challenged without also being checked, nor checked without being
    challenged. Forgetting one of the two was the drift this removes.
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
