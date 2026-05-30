#!/usr/bin/env bash
# Launch dmozdb under cgroup constraints via systemd-run.
# Usage: ./bench/run-server-constrained.sh <profile> [dmozdb-args...]
# Profiles match run-constrained.sh.

set -euo pipefail

PROFILE="${1:-unconstrained}"
shift || true

DMOZDB_BIN="./zig-out/bin/dmozdb"
[[ -x "$DMOZDB_BIN" ]] || { echo "Build first: zig build -Doptimize=ReleaseFast" >&2; exit 1; }

case "$PROFILE" in
  1cpu2gb)
    exec systemd-run --user --scope --quiet \
      -p CPUQuota=100% -p MemoryMax=2G -p MemorySwapMax=0 \
      "$DMOZDB_BIN" "$@"
    ;;
  2cpu4gb)
    exec systemd-run --user --scope --quiet \
      -p CPUQuota=200% -p MemoryMax=4G -p MemorySwapMax=0 \
      "$DMOZDB_BIN" "$@"
    ;;
  unconstrained)
    exec "$DMOZDB_BIN" "$@"
    ;;
  *)
    echo "Unknown profile: $PROFILE" >&2
    echo "Usage: $0 {1cpu2gb|2cpu4gb|unconstrained} [dmozdb-args...]" >&2
    exit 1
    ;;
esac
