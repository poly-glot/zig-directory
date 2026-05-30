# dmozdb baseline benchmark — 2026-05-04 (unconstrained)

## Capture environment

- Host: `08d021927f86` (devcontainer; Ubuntu 24.04.4 LTS, Linux 6.12.76-linuxkit aarch64, 10 CPUs, 7.8 GiB RAM)
- Branch: `master`
- Git rev: `4d42a17` (4d42a1745f46af1317199aa3f6851e8eb61eac10)
- Build: `zig build -Doptimize=ReleaseFast` (Zig 0.15)
- Binaries: `zig-out/bin/dmozdb` 5.0M, `zig-out/bin/bench` 3.6M
- Profile tag: `unconstrained` (no cgroup enforcement; `systemd-run` is unavailable in this dev container, so the constrained matrix runs are deferred — see follow-up)
- Fixture: 1000 categories at depth 4, 50000 seeded links (post-seed: 1002 categories / 50000 links / ~20k pages; bulk_import later grew this to 70000 links / 25654 pages)
- Workload settings: 4 workers × 5000 ops each unless noted; default warmup 1000

## Seed (write throughput)

- 51 000 ops in 3957 ms → **12 888 ops/sec**
- Seed records latency as 0 (single-shot wall-clock, not per-op histogram)

## Hot path workloads (server already warm, default warmup 1000)

Latencies in microseconds (µs).

| Workload | Params | ops/sec | p50 | p95 | p99 | p99.9 | max |
|---|---|---:|---:|---:|---:|---:|---:|
| create_link | 4 workers, batch 10 | 208 333 | 160 | 260 | 377 | 1130 | 1173 |
| get_link | 4 workers | 22 497 | 127 | 348 | 623 | 1196 | 2218 |
| browse path | 4 workers | 33 557 | 97 | 174 | 221 | 307 | 560 |
| browse children | 4 workers | 51 813 | 71 | 114 | 141 | 180 | 1412 |
| browse subtree-links | 4 workers, 2k ops | 414 | 5964 | 8061 | 9437 | 12714 | 14784 |
| search links | 4 workers, corpus 15 | 38 387 | 90 | 174 | 240 | 508 | 960 |
| search categories | 4 workers, corpus 15 | 35 906 | 95 | 180 | 229 | 311 | 410 |
| mixed 80/20 | 4 workers, 80 % reads | 40 899 | 75 | 158 | 219 | 340 | 912 |
| mixed 50/50 | 4 workers, 50 % reads | 50 000 | 69 | 137 | 184 | 258 | 886 |
| bulk_import | 1 worker, batch 1000, 5000 items | 16 077 | 58 720 | 59 245 | 59 245 | 59 245 | 74 109 |

`create_link`'s 208 k ops/sec is per-frame throughput; with `batch=10` items per frame, the effective item rate is ~2 M items/s and the histogram records the ~160 µs round-trip per frame (not per item). `bulk_import` reports per-frame latency as well: each frame ships 1000 items, so the ~59 ms p50 is per 1000-item frame (≈ 59 µs/item, which lines up with the 16 k items/s headline figure).

## Cold workloads

| Workload | Params | iterations | p50 | p95 | p99 | p99.9 | max |
|---|---|---:|---:|---:|---:|---:|---:|
| cold cache | 2 workers, 1000 ops, warmup 0 | 1 | 124 | 199 | 291 | 479 | 1418 |
| cold boot | 5 ops | 5 | 100 663 | 301 990 | 301 990 | 301 990 | 303 572 |

`cold cache` window slicing (n = 2000): win[0..1000] p50 = 124 µs / p95 = 219 µs / p99 = 299 µs; win[1000..end] p50 = 122 µs / p95 = 178 µs / p99 = 249 µs — i.e. the cache warms up almost immediately and steady-state latency tracks the hot `get_link` numbers within tens of microseconds.

`cold boot` reports per-iteration end-to-end times of 303, 101, 302, 101, 302 ms, alternating between a longer first-recover path and a faster subsequent boot. The histogram only ever sees 5 samples so p95/p99/p99.9 collapse onto the same bucket value.

## Surprises and anomalies

- `browse subtree-links` is the slowest hot read by two orders of magnitude (~6 ms p50 vs. ~70–130 µs for other browse variants). With only 414 ops/sec and a 9.4 ms p99, this is the workload to watch for regressions and the natural target for optimization. There is a known offset cap (`OffsetTooLarge` if offset > 5000) but at 2000 ops/worker the harness stays under the cap and no errors were emitted (`errors.connect_failed = errors.timeout = errors.protocol_error = 0`).
- `bulk_import` p50 ≈ p95 ≈ p99 ≈ 59 ms because only 5 frames (5000 items / 1000 per batch) were sent — too few samples to differentiate percentiles. To get a real distribution, future runs should bump `--count` to ≥ 50 000.
- No `verifier WARN drift` or other scary stderr lines were observed during the long-running server session or the cold-restart cycles. All workloads exited 0.
- A first attempt at the workload loop in this shell did not word-split the argv string correctly and yielded `error: UnknownSubcommand` for every workload; rerunning each workload as a separate command fixed it. The committed JSONL contains only the clean re-runs.

## Open follow-up

`systemd-run` is not available in this dev container, so the cgroup-enforced `1cpu2gb` and `2cpu4gb` profiles defined in `bench/run-constrained.sh` could not be captured. Re-run this same procedure on a host with `systemd --user` (or any environment where transient scopes can be created) and append the resulting JSONL records to a sibling file (e.g. `bench/baseline-2026-05-04-1cpu2gb.jsonl`) so regressions can be compared per-profile. The unconstrained numbers above set the upper bound for what those constrained runs should approach.

## 1 CPU / 2 GB (Docker --cpus=1 --memory=2g --memory-swap=2g)

Captured by running the dmozdb server inside Docker with cgroup limits while the host-resident bench client connected over `localhost:8080` (`--network host`, `DMOZDB_BIND=127.0.0.1`). Server image built `ReleaseFast` from the same `4d42a17`-equivalent tree on this branch; bench binary identical to the unconstrained run. Cold workloads were skipped because bench's `--server-cmd` lifecycle does not model `docker run`/`docker stop`. JSONL: `bench/baseline-2026-05-04-1cpu2gb.jsonl` (11 records).

Seed: 51 000 ops in 5563 ms → **9 167 ops/sec** (latency not histogrammed; single-shot wall-clock).

| Workload | Params | ops/sec | p50 | p95 | p99 | p99.9 | max |
|---|---|---:|---:|---:|---:|---:|---:|
| create_link | 4 workers, batch 10 | 10 020 | 1 261 | 2 981 | 63 438 | 97 517 | 184 263 |
| get_link | 4 workers | 13 386 | 87 | 225 | 348 | 61 341 | 64 948 |
| browse path | 4 workers | 15 576 | 98 | 176 | 243 | 52 428 | 55 894 |
| browse children | 4 workers | 41 322 | 73 | 121 | 159 | 389 | 25 903 |
| browse subtree-links | 4 workers, 2k ops | 64 | 85 983 | 96 468 | 100 663 | 119 537 | 179 103 |
| search links | 4 workers, corpus 15 | 20 140 | 98 | 217 | 397 | 44 564 | 48 197 |
| search categories | 4 workers, corpus 15 | 20 661 | 97 | 184 | 245 | 45 088 | 46 592 |
| mixed 80/20 | 4 workers, 80 % reads | 25 673 | 75 | 165 | 235 | 44 040 | 46 908 |
| mixed 50/50 | 4 workers, 50 % reads | 22 962 | 80 | 176 | 270 | 44 564 | 50 840 |
| bulk_import | 1 worker, batch 1000, 5000 items | 10 020 | 92 274 | 111 149 | 111 149 | 111 149 | 135 067 |

Latencies in microseconds (µs). All workloads exited 0 — no protocol or connect errors. The standout is `browse subtree-links` collapsing from 414 ops/sec → 64 (≈ 6.5× slower) and `bulk_import` per-frame latency rising from 58.7 ms → 92.3 ms. `create_link` p99 jumps from 377 µs to 63 ms because writes back up behind the single core's fsync path, and the same tail latency appears as p99.9 spikes (~44–61 ms) on every read workload — those are reads queued behind a write batch on the only available reactor.

## 2 CPU / 4 GB (Docker --cpus=2 --memory=4g --memory-swap=4g)

Same procedure with `--cpus=2 --memory=4g --memory-swap=4g`. JSONL: `bench/baseline-2026-05-04-2cpu4gb.jsonl` (11 records).

Seed: 51 000 ops in 4177 ms → **12 209 ops/sec**.

| Workload | Params | ops/sec | p50 | p95 | p99 | p99.9 | max |
|---|---|---:|---:|---:|---:|---:|---:|
| create_link | 4 workers, batch 10 | 16 090 | 1 523 | 2 621 | 23 855 | 69 206 | 91 639 |
| get_link | 4 workers | 26 845 | 112 | 256 | 303 | 548 | 7 705 |
| browse path | 4 workers | 32 520 | 95 | 165 | 206 | 3 604 | 5 244 |
| browse children | 4 workers | 49 261 | 70 | 130 | 282 | 753 | 1 915 |
| browse subtree-links | 4 workers, 2k ops | 138 | 17 563 | 64 487 | 67 108 | 70 254 | 77 254 |
| search links | 4 workers, corpus 15 | 38 759 | 93 | 159 | 196 | 245 | 398 |
| search categories | 4 workers, corpus 15 | 37 453 | 100 | 176 | 212 | 274 | 404 |
| mixed 80/20 | 4 workers, 80 % reads | 42 918 | 72 | 149 | 204 | 1 638 | 6 630 |
| mixed 50/50 | 4 workers, 50 % reads | 45 662 | 70 | 145 | 194 | 786 | 6 931 |
| bulk_import | 1 worker, batch 1000, 5000 items | 16 611 | 55 574 | 57 671 | 57 671 | 57 671 | 75 707 |

Doubling the CPU and memory roughly doubles throughput on most read paths and shaves the multi-millisecond tail down to single-digit milliseconds. Notably, `bulk_import` per-frame p50 *improves* against unconstrained (55.6 ms vs. 58.7 ms) — bulk import is single-worker and CPU-bound rather than memory-bound, and the container has no GUI/devcontainer noise. `search` tails are near-flat (p99.9 = 245–274 µs) because the AND-intersection happens entirely in memory and no longer fights for the only core.

## Cross-profile observations

The constrained profiles diverge from unconstrained mostly in *tail latency* rather than median: at 1 CPU, every read workload's p50 is within 30 % of unconstrained, but p99.9 explodes to 44–61 ms because reads queue behind writes on the single reactor. `browse subtree-links` is the worst-case scaling target — at 1 CPU it drops to **64 ops/sec (6.5× regression)** and even with 2 CPU/4 GB it only reaches 138 ops/sec (3× regression vs. 414); the workload is CPU-bound on the recursive child enumeration, not memory-bound, and shrinking the available cores hits it hardest. `bulk_import` is roughly *insensitive* to the constraint (10–16.6 k items/s across all three profiles, matching the wall-clock fsync floor): it is disk-bound, not CPU- or memory-bound. `search` benefits cleanly from the second core — 1 CPU shows 44 ms p99.9 from queueing while 2 CPU/4 GB drops the entire tail under 0.5 ms — confirming AND-intersection wants parallelism more than memory headroom. `create_link` write throughput halves at 1 CPU (208 k → 10 k frames/s) primarily because the single core has to serialize protocol I/O *and* wal/page-flush work; doubling cores recovers only ~16 k/s, which is consistent with the disk-bound interpretation: the second CPU helps, but the wall-clock fsync ceiling dominates beyond that.

The Docker-based capture has one structural difference from the unconstrained run worth noting: the server in the container talks to a fresh data dir per profile (the `--rm` volume is discarded between starts), so the b-tree fanout characteristics at measurement time match the unconstrained run almost exactly (~1002 categories / 50 000 links post-seed), keeping the comparison apples-to-apples. Cold-cache and cold-boot remain a follow-up — they need bench-driven server lifecycle, which the `docker run`/`docker stop` model doesn't support cleanly.

---

## Slice 6 follow-up — `browse subtree-links` after the algorithm-dispatch fix (2026-05-05)

After landing the dispatch on descendant count (commit `2c8efb3`), the unconstrained `browse subtree-links` workload was re-measured against the same fixture (1000 cats / 70k links — slightly grown after Slice 5c bench runs):

| Profile | Before (commit `a4d0f6e`) | After (commit `2c8efb3`) | Change |
|---|---:|---:|---:|
| unconstrained, 4 workers, 2k ops | 414 ops/s, p50 5 964 µs, p99 9 437 µs | **3 443 ops/s, p50 516 µs, p99 2 916 µs** | **8.3× ops/s, 11.5× p50** |

The fix: `handleListSubtreeLinks` now picks between `listSubtreeLinkIdsScan` (unbounded sequential walk over `link_by_category`, good for huge subtrees) and `listSubtreeLinkIds` (per-descendant rangescans, cheap for small subtrees) based on `db.config.subtree_scan_threshold` (default 1024). The bench's random-cat pattern almost always selects subtrees well below the threshold, so it now takes the per-descendant path — and avoids walking the entire 70k-link table for each request.

`bench/baseline-2026-05-05-slice6.jsonl` carries the post-fix record. Constrained-profile re-measurement (1cpu2gb / 2cpu4gb via Docker) is a candidate for a follow-up run; the algorithm change is bounded by tree fanout rather than CPU count, so a similar relative improvement should hold under both constraints.
