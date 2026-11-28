"""Where this resource server sits in the OAuth topology.

Every value is derived from two environment variables so a devcontainer
behind a tunnel and the deployed service differ only in configuration. The
metadata path follows RFC 9728 section 3.1, which inserts the well-known
segment *before* the resource's own path rather than appending to it.
"""

import os
import time
from typing import Any
from urllib.parse import urlsplit

from fastmcp.server.auth.providers.jwt import JWTVerifier

ISSUER_URL = os.environ.get("OAUTH_ISSUER_URL", "http://127.0.0.1:8000/auth")
RESOURCE_URL = os.environ.get("MCP_RESOURCE_URL", "http://127.0.0.1:8765/mcp")

SCOPE = "mcp"

# Where the signing keys are fetched from, which is not the same question as
# who issued the token. In the cluster the issuer is a public HTTPS URL while
# the keys are better fetched over the internal Service, so verification does
# not depend on the load balancer routing a pod's request back to itself.
# The issuer claim is still checked against ISSUER_URL either way.
JWKS_URI = os.environ.get("MCP_JWKS_URI", f"{ISSUER_URL}/.well-known/jwks.json")

JWKS_MISS_INTERVAL_S = 30


class MissThrottledVerifier(JWTVerifier):
    """A verifier that refetches the JWKS at most once per miss interval.

    FastMCP refetches the whole key set for every token whose ``kid`` it does
    not hold, so a stranger sending random kids turned each request into a
    request to the web tier. A kid already cached is served as before; an
    unknown one is refused without a fetch while the last fetch is recent.
    The throttle covers unknown ``kid`` values only. A cached key whose TTL
    has lapsed, and a token with no ``kid``, still reach FastMCP's own
    refetch; the web tier serves exactly one key, so neither is reachable
    with a stranger's input.
    """

    def __init__(self, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self._last_miss_fetch_s = float("-inf")

    async def _get_jwks_key(self, kid: str | None) -> str:
        if kid is None or kid in self._jwks_cache:
            return await super()._get_jwks_key(kid)

        now = time.monotonic()
        if now - self._last_miss_fetch_s < JWKS_MISS_INTERVAL_S:
            raise ValueError(f"Key ID '{kid}' not found in JWKS")

        self._last_miss_fetch_s = now
        return await super()._get_jwks_key(kid)


# audience pins tokens to this resource, so one minted for another server
# cannot be replayed here; required_scopes makes the scope we advertise in
# scopes_supported and demand in the challenge an actual condition of entry.
verifier = MissThrottledVerifier(
    jwks_uri=JWKS_URI,
    issuer=ISSUER_URL,
    audience=RESOURCE_URL,
    required_scopes=[SCOPE],
)

_resource = urlsplit(RESOURCE_URL)
RESOURCE_METADATA_PATH = (
    f"/.well-known/oauth-protected-resource{_resource.path.rstrip('/')}"
)
RESOURCE_METADATA_URL = (
    f"{_resource.scheme}://{_resource.netloc}{RESOURCE_METADATA_PATH}"
)
