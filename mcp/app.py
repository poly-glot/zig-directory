from fastmcp import FastMCP

from auth import remote_auth_provider

mcp = FastMCP("dmozdb", auth=remote_auth_provider)
