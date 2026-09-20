import os

from fastmcp.server.auth import RemoteAuthProvider
from fastmcp.server.auth.providers.jwt import JWTVerifier
from pydantic import AnyHttpUrl

ISSUER_URL = os.environ.get("OAUTH_ISSUER_URL", "http://127.0.0.1:8000")
RESOURCE_URL = os.environ.get("MCP_RESOURCE_URL", "http://127.0.0.1:8765/mcp")

verifier = JWTVerifier(
    jwks_uri=f"{ISSUER_URL}/.well-known/jwks.json",
    issuer=ISSUER_URL,
    audience=RESOURCE_URL,
)

remote_auth_provider = RemoteAuthProvider(
    token_verifier=verifier,
    authorization_servers=[AnyHttpUrl(ISSUER_URL)],
    base_url=RESOURCE_URL,
)
