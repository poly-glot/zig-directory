# dmozdb baseline benchmark — 2026-10-17

Re-run of the 2026-05-04 matrix on the code that is live after the Zig quality upgrade: zigstore 3.0.0 (crash-consistent
checkpoints), dmozdb on Zig 0.16.0, the ACID fixes, the cleanup and the fast boot. Every comparison below is against
`baseline-2026-05-04-*.jsonl` (summary in `baseline-2026-05-04-summary.md`).

## Capture environment

- Host: Docker Desktop VM on the same Mac (`7.0.14-linuxkit`, aarch64, **4 CPUs, 15.6 GiB**). The May run had 10 CPUs and
  7.8 GiB, so the `unconstrained` rows are not like-for-like; the `1cpu2gb` and `2cpu4gb` rows are, because the server's
  CPU and memory are capped by Docker in both runs.
- Git rev: `145b602` (`main` after PRs #11–#17), recorded in every JSONL record as `git_rev`.
- Build: `zig build -Doptimize=ReleaseFast -Dtools=true` with Zig 0.16.0, from a clean checkout.
- Server settings: defaults (`DMOZDB_CACHE_SIZE_MB` 256, thread count = visible CPUs), fresh data dir per profile.
- Fixture and workloads: identical to May — `seed` 1000 categories at depth 4 and 50 000 links, then `create_link`
  (4 workers, batch 10, 5000 items each), `get_link`, `browse path|children` (4 × 5000), `browse subtree-links`
  (4 × 2000), `search links|categories` (4 × 5000), `mixed 80/20` and `50/50` (4 × 5000), `bulk_import` (1 worker,
  batch 1000, 5000 items), in that order; default warmup 1000.
- `unconstrained`: server and bench in one container with no limits; then `cold cache` (2 × 1000, warmup 0) and
  `cold boot` (5 iterations).
- `1cpu2gb` / `2cpu4gb`: server in its own container with `--cpus=1 --memory=2g` / `--cpus=2 --memory=4g` (swap equal to
  memory); bench in an unconstrained container sharing the server's network namespace, so it connects over loopback as
  the May run's `--network host` did. Cold workloads are skipped for these profiles, as in May.
- All 35 workload runs exited 0 with zero connect, timeout or protocol errors. The server logs carry no warnings.

## Reading the write numbers

Two facts decide how to read every write row, and neither is a regression introduced by the upgrade:

1. **Every write is now acknowledged only after its own `fdatasync`.** In May the README stated that request handlers
   never block on disk I/O; today the ack is the fsync (see `README.md`, Durability). A real insert now costs about
   300 µs on this VM's disk, against about 6 µs in May. The rate is the same in all three profiles (≈ 4 200 items/s for
   `create_link`, ≈ 3 200 items/s for `bulk_import`, ≈ 3 000 ops/s for `seed`), which shows it is disk-bound, not
   CPU-bound. In a smaller same-container A/B on 2026-10-17, a binary from before the ACID, checkpoint and Zig 0.16
   changes (zigstore 1.4.1) measured 4 900–7 000 items/s on `create_link`, so those changes did not move the ceiling.
2. **Some bench "writes" are duplicate rejections.** `create_link`'s worker 0 generates `https://b1.t … b50000.t`,
   which `seed` already inserted, and `mixed` regenerates `create_link`'s URLs. Those requests are refused as
   duplicates without a commit. In `create_link` a quarter of the items are such rejections; in `mixed` nearly all
   writes are, so the `mixed` rows measure reads plus duplicate checks, not durable writes. This was true in May too.

## Unconstrained

Latencies in microseconds. `ops/sec` counts items for `create_link` and `bulk_import`, as the May summary did.

| Workload | ops/sec (May → now) | Δ | p50 µs (May → now) | p99 µs (May → now) | p99.9 µs now |
|---|---:|---:|---:|---:|---:|
| create_link | 208 333 → 4 278 | 0.02× | 159 → 6 225 | 376 → 20 971 | 35 127 |
| get_link | 22 497 → 151 515 | 6.73× | 126 → 22 | 622 → 46 | 145 |
| browse path | 33 557 → 74 626 | 2.22× | 97 → 38 | 221 → 83 | 151 |
| browse children | 51 813 → 101 010 | 1.95× | 70 → 36 | 141 → 68 | 121 |
| browse subtree-links | 414 → 6 535 | 15.79× | 5 963 → 548 | 9 437 → 1 179 | 4 096 |
| search links | 38 387 → 85 836 | 2.24× | 90 → 40 | 239 → 79 | 130 |
| search categories | 35 906 → 110 497 | 3.08× | 95 → 31 | 229 → 74 | 176 |
| mixed 80/20 | 40 899 → 136 986 | 3.35× | 74 → 24 | 219 → 53 | 123 |
| mixed 50/50 | 50 000 → 101 522 | 2.03× | 68 → 32 | 184 → 153 | 860 |
| bulk_import | 16 077 → 3 180 | 0.20× | 58 720 → 306 184 | 59 244 → 314 572 | 314 572 |

Seed: 51 000 ops at 12 888 → 3 091 ops/sec.

Cold workloads:

| Workload | May | Now |
|---|---|---|
| cold cache, first 1000 reads | p50 124 µs, p99 299 µs | p50 120 µs, p99 1 490 µs |
| cold cache, next 1000 reads | p50 122 µs, p99 249 µs | p50 97 µs, p99 223 µs |
| cold boot, 5 iterations (ms) | 303, 101, 302, 101, 302 | 102, 113, 106, 107, 107 |

Cold boot no longer alternates with a slow 300 ms recovery: boot now restores derived counts from the checkpoint and
seeds the URL bloom after the port opens. The cold-cache first window has a heavier tail (p99 1.5 ms) while that
background seeding reads the link table; the second window is faster than May's.

## 1 CPU / 2 GB

| Workload | ops/sec (May → now) | Δ | p50 µs (May → now) | p99 µs (May → now) | p99.9 µs now |
|---|---:|---:|---:|---:|---:|
| create_link | 10 020 → 4 176 | 0.42× | 1 261 → 9 175 | 63 438 → 13 369 | 18 612 |
| get_link | 13 386 → 121 951 | 9.11× | 87 → 19 | 348 → 34 | 89 |
| browse path | 15 576 → 59 523 | 3.82× | 98 → 32 | 243 → 49 | 78 |
| browse children | 41 322 → 101 522 | 2.46× | 73 → 32 | 159 → 55 | 77 |
| browse subtree-links | 64 → 5 780 | 90.31× | 85 983 → 397 | 100 663 → 1 081 | 45 088 |
| search links | 20 140 → 74 074 | 3.68× | 98 → 30 | 397 → 59 | 87 |
| search categories | 20 661 → 78 125 | 3.78× | 97 → 29 | 245 → 59 | 121 |
| mixed 80/20 | 25 673 → 105 820 | 4.12× | 75 → 21 | 235 → 40 | 68 |
| mixed 50/50 | 22 962 → 114 942 | 5.01× | 80 → 21 | 270 → 45 | 118 |
| bulk_import | 10 020 → 3 234 | 0.32× | 92 274 → 306 184 | 111 149 → 306 184 | 306 184 |

Seed: 51 000 ops at 9 167 → 2 960 ops/sec.

## 2 CPU / 4 GB

| Workload | ops/sec (May → now) | Δ | p50 µs (May → now) | p99 µs (May → now) | p99.9 µs now |
|---|---:|---:|---:|---:|---:|
| create_link | 16 090 → 4 159 | 0.26× | 1 523 → 6 291 | 23 855 → 20 185 | 24 641 |
| get_link | 26 845 → 130 718 | 4.87× | 112 → 26 | 303 → 45 | 87 |
| browse path | 32 520 → 74 626 | 2.29× | 95 → 37 | 206 → 93 | 221 |
| browse children | 49 261 → 166 666 | 3.38× | 70 → 22 | 282 → 38 | 60 |
| browse subtree-links | 138 → 8 611 | 62.40× | 17 563 → 364 | 67 108 → 942 | 3 801 |
| search links | 38 759 → 109 289 | 2.82× | 93 → 30 | 196 → 62 | 88 |
| search categories | 37 453 → 120 481 | 3.22× | 100 → 29 | 212 → 57 | 141 |
| mixed 80/20 | 42 918 → 162 601 | 3.79× | 72 → 20 | 204 → 39 | 61 |
| mixed 50/50 | 45 662 → 178 571 | 3.91× | 70 → 20 | 194 → 35 | 65 |
| bulk_import | 16 611 → 3 267 | 0.20× | 55 574 → 301 989 | 57 671 → 306 184 | 306 184 |

Seed: 51 000 ops at 12 209 → 3 008 ops/sec.

## Cross-profile observations

- **Reads are 2–9× faster in every profile, and the single-core tail is gone.** In May, every read workload at 1 CPU
  had a p99.9 of 44–61 ms from queueing behind writes on the only core; at 1 CPU now, p99.9 is under 0.13 ms for every
  read except `browse subtree-links`.
- **`browse subtree-links` is 16–90× faster** (the May-05 scan/walk dispatch plus the later work). Its only remaining
  outlier is the 1-CPU p99.9 of 45 ms.
- **Writes are disk-bound at one fsync per item** and identical across profiles. More CPUs cannot help a client that
  sends its writes one after another; group commit only batches writes that are in flight together.

## Follow-ups

- Give the write workloads URL ranges that cannot collide with `seed` or with each other, so `create_link` and `mixed`
  measure durable inserts only.
- The write ceiling is the per-item `fdatasync`. The lever is batching: commit a whole `create_link` or `bulk_import`
  frame as one WAL entry, or revisit zigstore's unmerged fsync-pipeline branch as a measured opt-in.
- Record server RSS: every record still says `rss_unavailable` because the server runs outside the bench process tree.
