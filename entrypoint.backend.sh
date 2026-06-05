#!/usr/bin/env bash
# Launches the dmozdb backend as PID 1's child under tini. `exec` replaces
# this shell with dmozdb so tini forwards SIGTERM straight to it, letting its
# own signal handler drain the WAL / write a snapshot before the pod dies.
set -uo pipefail

# The data dir is a mounted PVC; ensure it exists before dmozdb opens it.
mkdir -p "${DMOZDB_DATA_DIR:-/var/lib/dmozdb}"

echo "[entrypoint] starting dmozdb on ${DMOZDB_BIND:-0.0.0.0}:${DMOZDB_PORT:-8080} (trusted=${DMOZDB_TRUSTED:-loopback-only})"
exec dmozdb
