"""The dmozdb MCP server: the directory projected as MCP tools.

Modules used to sit at the top level and resolve only because the process
happened to start in this directory, which put generic names like ``client``
and ``views`` in the global module namespace. They live under a package now,
so an import says which project it came from.

Serve it with ``python -m dmozdb_mcp.server``.
"""
