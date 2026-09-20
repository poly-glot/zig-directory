"""Identity for the MCP transport: verification, challenge, and discovery.

Importing this package registers the RFC 9728 protected-resource route as a
side effect, which is why ``server.py`` imports it for its name alone. Only
the middleware and that registration are exported; the verifier, the scope
and the derived URLs stay behind ``auth.config`` because nothing outside the
package reads them.
"""

from . import metadata
from .challenge import OpportunisticAuth

__all__ = ["OpportunisticAuth", "metadata"]
