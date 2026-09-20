import os
from urllib.parse import urlsplit

from fastmcp.server.auth.providers.jwt import JWTVerifier

ISSUER_URL = os.environ.get("OAUTH_ISSUER_URL", "http://127.0.0.1:8000/auth")
RESOURCE_URL = os.environ.get("MCP_RESOURCE_URL", "http://127.0.0.1:8765/mcp")

verifier = JWTVerifier(
    jwks_uri=f"{ISSUER_URL}/.well-known/jwks.json",
    issuer=ISSUER_URL,
    audience=RESOURCE_URL,
)

_resource = urlsplit(RESOURCE_URL)
RESOURCE_METADATA_PATH = (
    f"/.well-known/oauth-protected-resource{_resource.path.rstrip('/')}"
)
RESOURCE_METADATA_URL = (
    f"{_resource.scheme}://{_resource.netloc}{RESOURCE_METADATA_PATH}"
)
