# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The project has no tagged releases and no stability promise yet. `build.zig.zon` says 0.6.0, so everything merged to
`main` up to now is grouped under that version. The entries were rebuilt from the merged pull request titles and the
commit history, and the pull request numbers are the ones in that history. The first commit is from 2026-05-30.

## [Unreleased]

### Added

- MIT licence, the same text as zigstore.
- `docs/protocol.md`, `docs/architecture.md` and `docs/operations.md`, split out of the README.
- `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `NOTICE.md`, issue templates and a pull request template.
- A `zig-reviewer` agent that builds a scratch copy and reports only what it reproduced.

- Store format 10: every category keeps exact approved and pending subtree link counts, so a status-filtered subtree
  listing reports an exact total. A format 9 store upgrades on first boot with one recount.

### Changed

- zigstore 4.0.0: keys and values over the engine's limits are refused before the WAL append, a failed recovery no
  longer truncates the WAL, and a failed WAL batch is no longer reported durable.
- Public pages, `/api/v1` and the MCP tools count approved links only.
- The README now starts with what the project is, its status and a quickstart that was run end to end.
- The README matches the code: op tables for ops 41 and 42, the data files table lists `derived.snap`, function
  names use the `snake_case` the code has, the bench and quickstart commands set `DMOZDB_VECTOR_MODEL` and an absolute
  data directory.
- Per-machine Claude Code permissions (`.claude/settings.local.json`) are no longer tracked.

### Fixed

- Pending and rejected links are no longer shown on public pages.
- Requests have a body limit, search no longer rescans tokens without bound, and a status-filtered subtree listing no
  longer scans the whole subtree.
- A slug path longer than the engine's key limit is refused instead of poisoning the WAL.
- The MCP server bounds anonymous sessions and the client metadata it fetches and caches.
- The GraphRAG eval's `dmozdb` container now gets the vector model it needs to start.

## [0.6.0] - not tagged

### Added

- Graph search: adjacency lists, a `neighbours` op (42), role queries, facets and a search monitor that probes the live
  site twice an hour (#37).
- Graph facts: `query_links` (op 38), link entities (op 39) and entity-aware search, store format 7 (#26). A
  subdomain-sites filter and a clear error for an unknown category path (#27).
- Search by query shape: content-word ranking, path embeddings, category vectors (op 41), inflection folding (#28).
- An IVF-PQ index over link vectors, built for the 3.04 million link dump, with store format 9 (#29).
- Tooling and memory sizing for the full 3.04 million link dump (#30).
- Hybrid search: a ranked keyword mode, stored link vectors (op 37) and embeddings computed in the web tier (#23, #24,
  #25). The GraphRAG eval that justified them (#22).
- A derived-index snapshot written at every checkpoint and restored at boot before replay (#34).
- An MCP server that exposes the directory to AI clients, with OAuth identity and a Kubernetes deployment (#10).
- The `breadcrumbs_by_ids` op (30), so the web tier asks the server for ancestor chains.
- Journaled checkpoints, so a crash between a checkpoint's two phases is repaired on the next start (#14).
- A TigerStyle checker, `src/tidy.zig`, that runs inside `zig build test`, and the TigerStyle adoption across the Zig
  backend (#32).
- A benchmark baseline for all three profiles, with a summary (#18), and `bench/` workloads for seed, create, bulk
  import, get, browse, search, mixed and cold start.
- Continuous integration for Zig, web and MCP (`.github/workflows/ci.yaml`), and continuous deployment to Kubernetes
  (`.github/workflows/cd.yaml`).

### Changed

- The storage engine moved out into the zigstore library. This repository consumes it through `build.zig.zon`, now at
  v3.0.1 (#6, #8, #9, #11, #14).
- Zig 0.16.0 is the minimum version, with the `std.process.Init` and `Io` APIs (#15).
- The web frontend and the backend run as separate workloads, and the web app compiles to one self-contained binary
  (#2, #5).
- A write is acknowledged after one durability wait per request, outside the write lock. Group commit shares the
  `fdatasync` between connections (#19).
- Boot opens the port without scanning the store and seeds the URL bloom filter afterwards, pausing between chunks
  (#17, #20).
- Large categories page without scanning the whole link index, and the verifier runs once a month (#31).
- The backend pod gets a 128 MiB scratch slab and is no longer restarted on unrelated merges (#33). Checkpoints and
  snapshots run hourly instead of every five minutes (#35).
- A cleanup pass removed about 1,850 lines of dead code without changing behaviour (#13).

### Fixed

- The stats response is bounds-checked, so pipelined frames cannot overflow the buffer (#3).
- Pipelined frames that cannot fit are deferred instead of returning an error (#4).
- Crash and race gaps around the WAL commit path were closed (#12).
- The backend gets 300 seconds to boot before its startup probe fails (#16).
- The category views no longer use the request's scratch slab (#36).
- The website no longer leaks a user's password hash through island serialisation, and stored URLs can no longer carry
  script.
- zigstore was re-pinned at v1.0.1 for an x86_64 alignment fix in the WAL and snapshot code.
- Security, durability, concurrency and memory-safety hardening of `dmozdb` from the first review (#1).
