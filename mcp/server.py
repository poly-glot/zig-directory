import os

import httpx2
from fastmcp import FastMCP

API_URL = os.environ.get("DMOZ_API_URL", "http://127.0.0.1:8000")
OPENAPI_URL = f"{API_URL}/api/v1/openapi.json"

spec = httpx2.get(OPENAPI_URL).raise_for_status().json()

mcp = FastMCP.from_openapi(
    spec,
    client=httpx2.AsyncClient(base_url=API_URL, timeout=30),
    name="dmozdb",
)

if __name__ == "__main__":
    mcp.run(transport="http", host="127.0.0.1", port=int(os.environ.get("PORT", "8765")))
