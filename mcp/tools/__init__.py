"""Importing this package registers every tool on the shared server.

Each module holds one ``@mcp_app.tool``; the decorator runs on import, which
is the whole reason this file lists them. ``server.py`` imports the package
for that side effect alone.
"""

from . import browse, links, review_submission, search

__all__ = ["browse", "links", "review_submission", "search"]
