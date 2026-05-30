#!/usr/bin/env bash
set -euo pipefail

# On container start, bring the stack up in dev mode (hot-reloading web server).
# The startup logic is shared with the `dev`/`prod` aliases via run.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/run.sh" dev