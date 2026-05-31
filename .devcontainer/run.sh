#!/usr/bin/env bash
# Bring up the full stack (dmozdb backend + Fresh web) in one of two modes:
#   dev  - Fresh dev server via vite, hot-reloading (default)
#   prod - built Fresh bundle served live via `deno serve`, no auto-refresh
set -euo pipefail

MODE="${1:-dev}"
if [ "$MODE" != "dev" ] && [ "$MODE" != "prod" ]; then
  echo "usage: run.sh [dev|prod]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="/tmp"

cd "$WORKSPACE"

echo "[run:$MODE] Stopping any previous instances..."
pkill -f "zig-out/bin/dmozdb" 2>/dev/null || true
pkill -f "vite" 2>/dev/null || true
pkill -f "_fresh/server.js" 2>/dev/null || true

# Seed the directory DB and the user store if they aren't already present
# (idempotent). Runs while the servers are stopped so nothing holds the files.
bash "$SCRIPT_DIR/seed.sh"

echo "[run:$MODE] Building dmozdb (ReleaseSafe)..."
zig build -Doptimize=ReleaseSafe

GATEWAY="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}' || true)"
export DMOZDB_BIND="0.0.0.0"
export DMOZDB_PORT="8080"
export DMOZDB_DATA_DIR="$WORKSPACE/data"
# Pin Fresh -> dmozdb dial address to IPv4 loopback. The devcontainer's
# /etc/hosts resolves "localhost" to ::1 first; dmozdb binds 0.0.0.0 (IPv4
# only), so Deno's IPv6 attempt fails with ECONNREFUSED. Skipping DNS
# sidesteps that.
export DMOZDB_HOST="127.0.0.1"
if [ -n "${GATEWAY:-}" ]; then
  export DMOZDB_TRUSTED="$GATEWAY"
fi

mkdir -p "$DMOZDB_DATA_DIR"

echo "[run:$MODE] Starting dmozdb on 0.0.0.0:8080 (trusted=${DMOZDB_TRUSTED:-none}) -> $LOG_DIR/dmozdb.log"
setsid nohup "$WORKSPACE/zig-out/bin/dmozdb" </dev/null >"$LOG_DIR/dmozdb.log" 2>&1 &
disown || true

cd "$WORKSPACE/web"
if [ "$MODE" = "prod" ]; then
  # Build the static bundle, then serve it live. `deno serve` defaults to
  # 0.0.0.0:8000, so no host/port flags are needed. No file watching here:
  # the page is served as built and will not auto-refresh.
  echo "[run:prod] Building Fresh production bundle..."
  deno task build
  echo "[run:prod] Starting Fresh production server on 0.0.0.0:8000 -> $LOG_DIR/web.log"
  setsid nohup deno task start </dev/null >"$LOG_DIR/web.log" 2>&1 &
else
  echo "[run:dev] Starting Fresh dev server on 0.0.0.0:8000 -> $LOG_DIR/web.log"
  setsid nohup env HOSTNAME=0.0.0.0 deno task dev </dev/null >"$LOG_DIR/web.log" 2>&1 &
fi
disown || true

# Give children a moment to fully detach before this script (and its exec session) exits
sleep 1

echo "[run:$MODE] Done. Tail logs with: tail -f /tmp/dmozdb.log /tmp/web.log"