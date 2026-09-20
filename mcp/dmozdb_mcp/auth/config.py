"""Where this resource server sits in the OAuth topology.

Every value is derived from two environment variables so a devcontainer
behind a tunnel and the deployed service differ only in configuration. The
metadata path follows RFC 9728 section 3.1, which inserts the well-known
segment *before* the resource's own path rather than appending to it.
"""

import os
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

# audience pins tokens to this resource, so one minted for another server
# cannot be replayed here; required_scopes makes the scope we advertise in
# scopes_supported and demand in the challenge an actual condition of entry.
verifier = JWTVerifier(
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
