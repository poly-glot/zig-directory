import os

import tools
from app import mcp

if __name__ == "__main__":
    mcp.run(
        transport="http",
        host="127.0.0.1",
        port=int(os.environ.get("PORT", "8765")),
    )
