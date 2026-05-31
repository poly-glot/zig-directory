#!/usr/bin/env bash
# Supervises the two colocated processes (dmozdb backend + Deno/Fresh web) and,
# on pod termination, signals both and waits for dmozdb to finish its WAL drain
# / snapshot. Run under tini (see Dockerfile ENTRYPOINT) which forwards SIGTERM
# here. No `set -e`: with background jobs and a signal trap, an aborting shell
# would skip the graceful drain.
set -uo pipefail

# Persisted paths live on mounted volumes; ensure they exist before either
# process opens them (an empty PVC mount may not pre-create nested dirs).
mkdir -p "${DMOZDB_DATA_DIR:-/var/lib/dmozdb}"
mkdir -p "$(dirname "${KV_PATH:-/web/data/users.db}")"

# Backend bound to loopback (DMOZDB_BIND=127.0.0.1 from the image env); the
# frontend reaches it over 127.0.0.1, which the backend always trusts.
echo "[entrypoint] starting dmozdb backend on 127.0.0.1:${DMOZDB_PORT:-8080}..."
dmozdb &
DMOZDB_PID=$!

echo "[entrypoint] starting web frontend on 0.0.0.0:8000..."
deno serve -A --unstable-kv /web/_fresh/server.js &
WEB_PID=$!

shutdown() {
  echo "[entrypoint] signal received; stopping children..."
  kill -TERM "$WEB_PID" "$DMOZDB_PID" 2>/dev/null || true
}
trap shutdown TERM INT

# Wake when either child exits (a crash) or a signal arrives, then stop the
# other and block until both have exited — letting dmozdb drain cleanly.
wait -n
echo "[entrypoint] a process exited; draining the other..."
kill -TERM "$WEB_PID" "$DMOZDB_PID" 2>/dev/null || true
wait
echo "[entrypoint] all processes stopped."
