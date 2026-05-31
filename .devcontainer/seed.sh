#!/usr/bin/env bash
# Idempotently seed local dev data on container start. Each step is a no-op once
# its data exists, so this is safe to run on every start (a fresh checkout —
# e.g. Codespaces — has neither, since data/dmozdb.dat and web/data/ are
# gitignored). DEV ONLY: production restores the real datasets out-of-band.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1) dmozdb directory DB — expand the tracked compressed snapshot. dmozdb loads
#    dmozdb.dat directly; the WAL/snapshot files are recreated at runtime.
if [ -f "$WORKSPACE/data/dmozdb.dat" ]; then
  echo "[seed] dmozdb DB already present; skipping."
elif [ -f "$WORKSPACE/data/dmozdb.dat.zip" ]; then
  echo "[seed] expanding data/dmozdb.dat.zip -> data/dmozdb.dat ..."
  unzip -q "$WORKSPACE/data/dmozdb.dat.zip" -d "$WORKSPACE/data"
  echo "[seed] dmozdb DB seeded."
else
  echo "[seed] no data/dmozdb.dat.zip snapshot found; starting with an empty DB."
fi

# 2) web user store — create a default admin so /admin is reachable in a fresh
#    checkout (registration alone only yields the `user` role).
if [ -f "$WORKSPACE/web/data/users.db" ]; then
  echo "[seed] users KV already present; skipping."
else
  echo "[seed] creating default admin in web/data/users.db ..."
  mkdir -p "$WORKSPACE/web/data"
  DENO_BIN="$(command -v deno || true)"
  [ -z "$DENO_BIN" ] && DENO_BIN="$HOME/.deno/bin/deno"
  ( cd "$WORKSPACE/web" && "$DENO_BIN" run --unstable-kv -A scripts/seed-admin.ts )
fi
