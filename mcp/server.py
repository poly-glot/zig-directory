import os

import uvicorn
from starlette.middleware import Middleware

import auth
import tools
from app import mcp

if __name__ == "__main__":
    uvicorn.run(
        mcp.http_app(path="/mcp", middleware=[Middleware(auth.OpportunisticAuth)]),
        host=os.environ.get("HOST", "127.0.0.1"),
        port=int(os.environ.get("PORT", "8765")),
    )
