#!/usr/bin/env bash
# Run a bench command under cgroup constraints via systemd-run.
# Usage: ./bench/run-constrained.sh <profile> -- <bench-subcommand> [bench-args...]
# Profiles:
#   1cpu2gb        — 1 CPU core, 2 GB memory, swap disabled
#   2cpu4gb        — 2 CPU cores, 4 GB memory, swap disabled
#   unconstrained  — no cgroup limits
#
# The wrapper auto-injects --profile=$PROFILE after the subcommand so the
# JSON Lines record carries the right tag.

set -euo pipefail

PROFILE="${1:-unconstrained}"
shift || true
[[ "${1:-}" == "--" ]] && shift

# First remaining arg is the bench subcommand; insert --profile after it.
SUB="${1:-}"
[[ -n "$SUB" ]] || { echo "Usage: $0 {1cpu2gb|2cpu4gb|unconstrained} -- <bench-subcommand> [args...]" >&2; exit 1; }
shift

BENCH_BIN="./zig-out/bin/bench"
[[ -x "$BENCH_BIN" ]] || { echo "Build first: zig build -Doptimize=ReleaseFast" >&2; exit 1; }

case "$PROFILE" in
  1cpu2gb)
    exec systemd-run --user --scope --quiet \
      -p CPUQuota=100% -p MemoryMax=2G -p MemorySwapMax=0 \
      "$BENCH_BIN" "$SUB" --profile "$PROFILE" "$@"
    ;;
  2cpu4gb)
    exec systemd-run --user --scope --quiet \
      -p CPUQuota=200% -p MemoryMax=4G -p MemorySwapMax=0 \
      "$BENCH_BIN" "$SUB" --profile "$PROFILE" "$@"
    ;;
  unconstrained)
    exec "$BENCH_BIN" "$SUB" --profile "$PROFILE" "$@"
    ;;
  *)
    echo "Unknown profile: $PROFILE" >&2
    echo "Usage: $0 {1cpu2gb|2cpu4gb|unconstrained} -- <bench-subcommand> [args...]" >&2
    exit 1
    ;;
esac
