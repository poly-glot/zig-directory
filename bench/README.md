# bench — dmozdb benchmark harness

Multi-workload benchmark client emitting **JSON Lines** with p50 / p95 / p99 / p99.9 latency percentiles, throughput, and RSS samples. Designed for cgroup-constrained 1 CPU / 2 GB and 2 CPU / 4 GB cloud profiles.

## Quick start

```bash
# 1. Build the server plus the tools (bench is always compiled ReleaseFast)
zig build -Dtools=true

# 2. Start dmozdb with a fresh data dir
mkdir -p /tmp/bench-data
DMOZDB_DATA_DIR=/tmp/bench-data ./zig-out/bin/dmozdb &
SERVER_PID=$!
sleep 2

# 3. Seed a deterministic fixture
./zig-out/bin/bench seed \
  --data-dir /tmp/bench-data \
  --categories 1000 \
  --links 100000 \
  --output /tmp/bench.jsonl

# 4. Run a read workload
./zig-out/bin/bench get_link \
  --data-dir /tmp/bench-data \
  --workers 4 \
  --ops-per-worker 20000 \
  --output /tmp/bench.jsonl

# 5. Inspect results
jq '.workload, .latency_ns' /tmp/bench.jsonl

# 6. Tear down
kill $SERVER_PID
```

A plain `zig build` produces only `dmozdb`; `bench` and `dmoz_import` exist only after `zig build -Dtools=true`.

## Subcommands

| Subcommand                                             | Purpose                                                                  |
|--------------------------------------------------------|--------------------------------------------------------------------------|
| `bench seed`                                           | Populate a deterministic category tree + link fixture; write `seed.json` sidecar |
| `bench create_link`                                    | Write hammer via op 1, `--batch` items per frame                         |
| `bench bulk_import`                                    | Stream links via op 24 in `--batch-size` chunks until `--count` is reached |
| `bench get_link`                                       | Random point reads against `links_by_id` (op 3)                          |
| `bench browse --kind {path\|children\|subtree-links}`  | Hierarchy traversal (op 11 / 12 / 17)                                    |
| `bench search --target {links\|categories}`            | Token search via `links_index_tree` / `categories_index_tree` (op 14)    |
| `bench mixed --read-pct PCT`                           | Mixed `get_link` / `create_link` with configurable split (use 80 / 50 / 20 by convention) |
| `bench cold --kind {cache\|boot} --server-cmd CMD`     | Spawns the server itself; cold-cache or cold-boot timing                 |

`bench --help` prints the common-options reference.

## Common options

Parsed by every subcommand before its own flags:

```
--profile {1cpu2gb|2cpu4gb|unconstrained}    Tag the JSON record (does NOT enforce; the wrapper does)
--output PATH                                Append JSON Lines records to PATH (default: stdout)
--workers W                                  Concurrent client connections (default: 4)
--ops-per-worker N                           Ops each worker performs (default: 10000)
--warmup-ops N                               Discard first N ops from percentile recording (default: 1000)
--connect-host HOST                          Server host (default: 127.0.0.1)
--port P                                     Server port (default: 8080)
--rss-sample-ms MS                           Sample server RSS every MS ms (default: 200, 0 to disable)
--git-rev REV                                Override auto-detected git rev
```

**Note on `--warmup-ops`:** the default 1000 is sized for production runs. For tiny smoke tests (workers × ops < 1000), pass `--warmup-ops 0` or your percentiles will read zero.

## Per-workload options

| Subcommand    | Flag                | Default           | Meaning                                                        |
|---------------|---------------------|-------------------|----------------------------------------------------------------|
| `seed`        | `--data-dir DIR`    | `/var/lib/dmozdb` | Where `seed.json` is written (must be the server's data dir)    |
| `seed`        | `--categories N`    | `1000`            | Categories to create                                           |
| `seed`        | `--links N`         | `100000`          | Links to create                                                |
| `seed`        | `--depth N`         | `4`               | Depth of the generated category tree                           |
| `seed`        | `--server-cmd CMD`  | (none)            | Spawn the server with this command instead of connecting       |
| `create_link` | `--batch N`         | `10`              | Items per `create_link` frame                                  |
| `bulk_import` | `--count N`         | `10000`           | Total links to import                                          |
| `bulk_import` | `--batch-size N`    | `1000`            | Items per `bulk_import` frame (max 4000; `--count` max 10,000,000) |
| `get_link`    | `--data-dir DIR`    | `/var/lib/dmozdb` | Reads `seed.json` for the link id range                        |
| `browse`      | `--kind K`          | (required)        | `path`, `children` or `subtree-links`                          |
| `browse`      | `--data-dir DIR`    | `/var/lib/dmozdb` | Reads `seed.json` for the category id range                    |
| `search`      | `--target T`        | (required)        | `links` or `categories`                                        |
| `search`      | `--data-dir DIR`    | `/var/lib/dmozdb` | Reads `seed.json`                                              |
| `mixed`       | `--read-pct PCT`    | (required)        | Percentage of ops that are reads                               |
| `mixed`       | `--data-dir DIR`    | `/var/lib/dmozdb` | Reads `seed.json` for the link id range                        |
| `cold`        | `--kind K`          | (required)        | `cache`: spawn the server once, measure the first reads; `boot`: spawn-to-first-ping, `--ops-per-worker` iterations |
| `cold`        | `--server-cmd CMD`  | (required)        | Command used to spawn the server                               |
| `cold`        | `--data-dir DIR`    | `/var/lib/dmozdb` | Data dir handed to the spawned server                          |
| `cold`        | `--reseed`          | off               | Run an inline seed (200 categories × 2000 links) instead of requiring an existing `seed.json` |

Workloads that take `--data-dir` read the `seed.json` sidecar that `bench seed` wrote there; run `seed` first.

## Constrained profiles

`run-constrained.sh` and `run-server-constrained.sh` use `systemd-run --user --scope` to apply CPU + memory limits. No root required (cgroup v2 user delegation must be available; it works in the dev container).

```bash
# Run a workload under the 1 CPU / 2 GB profile
./bench/run-constrained.sh 1cpu2gb -- get_link \
  --data-dir /tmp/bench-data \
  --workers 4 \
  --ops-per-worker 5000 \
  --output /tmp/bench-1cpu2gb.jsonl

# Constrain the SERVER too (recommended for representative numbers)
./bench/run-server-constrained.sh 2cpu4gb &
SERVER_PID=$!
./bench/run-constrained.sh 2cpu4gb -- mixed --read-pct 80 \
  --data-dir /tmp/bench-data \
  --workers 4 \
  --ops-per-worker 10000 \
  --output /tmp/bench-2cpu4gb.jsonl
kill $SERVER_PID
```

If `systemd-run` is unavailable, fall back to:

- `taskset -c 0 ./zig-out/bin/bench ...` (CPU pinning)
- `docker run --cpus=1 --memory=2g ...` (container-based)
- `prlimit --as=2147483648 ...` (rough memory cap, not a hard limit)

## Matrix runner

A simple shell loop covers the full coverage matrix:

```bash
#!/usr/bin/env bash
set -euo pipefail
OUT=/tmp/bench-matrix.jsonl
> "$OUT"

# Assumes seed already done at /tmp/bench-data
for PROFILE in unconstrained 1cpu2gb 2cpu4gb; do
  for WORKERS in 1 4 8; do
    ./bench/run-constrained.sh "$PROFILE" -- get_link \
      --data-dir /tmp/bench-data --workers "$WORKERS" --ops-per-worker 5000 --output "$OUT"
    ./bench/run-constrained.sh "$PROFILE" -- create_link \
      --workers "$WORKERS" --batch 10 --ops-per-worker 5000 --output "$OUT"
    ./bench/run-constrained.sh "$PROFILE" -- search --target links \
      --data-dir /tmp/bench-data --workers "$WORKERS" --ops-per-worker 2000 --output "$OUT"
    ./bench/run-constrained.sh "$PROFILE" -- mixed --read-pct 80 \
      --data-dir /tmp/bench-data --workers "$WORKERS" --ops-per-worker 5000 --output "$OUT"
  done
done

# Summary table
jq -r '[.profile, .workload, .params.workers, .latency_ns.p50, .latency_ns.p99, .ops_per_sec] | @tsv' "$OUT"
```

## JSON Lines schema

Every workload appends one record like:

```json
{
  "schema_version": 1,
  "ts": 1714838400000,
  "host": "dev-container",
  "git_rev": "5a30064",
  "profile": "1cpu2gb",
  "workload": "get_link",
  "params": { "workers": 4, "ops_per_worker": 20000, "seed_path": "/tmp/bench-data/seed.json" },
  "duration_ms": 12340,
  "ops_total": 80000,
  "ops_per_sec": 6480,
  "latency_ns": {
    "p50": 130000,
    "p95": 250000,
    "p99": 480000,
    "p99_9": 1200000,
    "max": 5000000,
    "mean": 145000,
    "samples": 80000
  },
  "rss_bytes": { "peak": 521000000, "final": 480000000, "note": null },
  "errors": { "connect_failed": 0, "timeout": 0, "protocol_error": 0 }
}
```

`params` is workload-specific (different keys per `workload`). `rss_bytes.note` is `"rss_unavailable"` when the bench can't read `/proc/<pid>/status` (e.g., bench didn't spawn the server).

## Comparing two runs

```bash
jq -s '
  .[0] as $a | .[1] as $b
  | { workload, profile, baseline_p99: $a.latency_ns.p99, candidate_p99: $b.latency_ns.p99,
      delta_pct: (($b.latency_ns.p99 - $a.latency_ns.p99) * 100 / $a.latency_ns.p99) }
' baseline.jsonl candidate.jsonl
```

(For multi-record runs, use `jq -s '. | group_by(.workload + .profile)'` and diff per group.)

## Baselines

`baseline-2026-10-17-group-commit-*.jsonl` is the current baseline for all three profiles; `baseline-2026-10-17-*.jsonl` is the same day before group commit. Both are summarised, and compared against May, in `baseline-2026-10-17-summary.md`. `baseline-2026-05-04-*.jsonl` and `baseline-2026-05-05-slice6.jsonl` are earlier recorded runs; `baseline-2026-05-04-summary.md` summarises them.
