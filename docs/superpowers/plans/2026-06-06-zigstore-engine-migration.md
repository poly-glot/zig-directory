# zigstore Engine Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract dmozdb's generic database/server engine (storage, WAL, snapshot, epoll reactor, binary-protocol framing, TS-client codegen — ~11k loc) into the standalone `zigstore` library, consumed by dmozdb via a `build.zig.zon` dependency, landed as one validated big-bang PR that tags `zigstore` `v1.0.0`.

**Architecture:** Hybrid API. A comptime data plane — `zigstore.Engine(schema)` — generates the typed `Store` (superblock `Header`, named paged B+Trees, named memtables, persisted counters) from an app-declared schema. The dynamic seams stay runtime: `Store.recover(ctx, .{ .apply_entry, .on_replayed, .bootstrap })`, `Store.spawnWorker(ctx, .{ .interval_ns, .tick })`, `protocol.processFrames(ctx, conn, dispatch_fn, op_latency)`, snapshot over a `SnapshotHost` interface, and a generic `run(Store, ctx, ServerConfig)` bootstrap — every seam's callback context is the same `*anyopaque` app `Directory`. **The one invariant that must never break: no `zigstore/src/*` file may import or name a dmozdb file or type.** dmozdb composes `Store` into an app `Directory` that owns hierarchy, slugs, statuses, and the op dispatch.

**Tech Stack:** Zig 0.15.2 (pinned). Two git repos: `zigstore` (at `/Users/junaidahmed/Desktop/projects/zigstore`, branch `feat/engine-extraction`) and `dmozdb`/`zig-directory` (branch `feat/zigstore-extraction`). The engine is the source of truth for the binary protocol; the Deno/Fresh web client is regenerated from it.

---

## Ground rules (read before Task 1)

These hold for **every** task below. They are not repeated per-step.

1. **This is a migration of tested code, not greenfield.** Most engine bodies already exist in `dmozdb/src/` and pass tests today. The work is *move + repoint + invert couplings*, not reinvention. When a step says "port `fn X` from `dmozdb/src/Y.zig:a-b`," copy that body verbatim and change only the named imports/types. The moved tests are the red/green gate. Author *new* tests only for the *new generic seams* (`Engine(schema)` paged backing, `recover`, `spawnWorker`, `SnapshotHost`, the `processFrames` dispatch callback, `wire_codec`, `tsgen`).

2. **The acyclic boundary is checked every phase.** After any phase that touches `zigstore/src`, run:
   ```bash
   cd /Users/junaidahmed/Desktop/projects/zigstore
   ! grep -rEn 'Category|Link|LinkStatus|RepairOp|DMOZ|dmoz|slug|subtree|directory\.zig|operations|verifier' src --include='*.zig' \
       | grep -v -E '//|test |"' || echo "BOUNDARY CLEAN"
   ```
   Any hit in non-comment, non-test, non-string code is a boundary violation — stop and fix.

3. **Gates run in the Linux devcontainer, not the macOS host.** The host PATH zig is 0.13 (too old), and from Phase 3 onward the engine's paged storage needs Linux `O_DIRECT`/`fallocate`. Run every `zig build test` inside the devcontainer (`zigstore/.devcontainer` for the engine, `zig-directory/.devcontainer` for the app). For pure-comptime/compile-only checks before Phase 3 you may use the host 0.15.2 binary: `ZIG=~/Library/zig/0.15.2/zig`. **A change is "done" only when its repo's `zig build test` exits 0 in the container.**

4. **`.path` dev loop the whole way; flip to tarball last.** dmozdb depends on `zigstore` via `.path = "../zigstore"` for Phases 1–9. The flip to `url`+`hash` is Phase 10 only. Never hand-edit the hash; always `zig fetch --save`.

5. **Commit identity (dmozdb and zigstore both have a `poly-glot` remote):**
   ```bash
   git -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" commit -m "..."
   ```

6. **Commit cadence.** Commit after each task's gate passes. Never push without explicit approval. The PR is reviewable as this commit sequence.

7. **`zig fmt` on every `.zig` you touch** (the auto-format hook does this on save). Trailing newline on every file.

---

## File Structure (end state)

**zigstore/src/ (engine — all generic):**

```
codec.zig              # DONE in v0: Serializable, FixedString, CompositeKey, encodeU64/decodeU64, hash
engine.zig             # schema(), Schema, IndexSpec, KeyKind, Engine(schema); Store now paged-backed
wire_codec.zig         # NEW: @typeInfo encodeStruct/decodeStruct/encodeField/decodeField + version framing
file_header.zig        # NEW: generic superblock helpers (serialize/deserialize/validate over the generated Header)
page.zig page_cache.zig freelist.zig memtable.zig bloom.zig inverted_index.zig histogram.zig   # moved leaves
btree/{btree,btree_insert,btree_delete,btree_search,btree_repair,btree_helpers}.zig             # moved
wal.zig wal_replay.zig # moved (from wal/); WAL OpCode is plain u8
snapshot.zig           # moved + generic over SnapshotHost
commit.zig             # moved + generic over a record type with serialize/apply callbacks
connection.zig signal.zig epoll.zig   # moved; epoll generic over ctx + Handler + ServerConfig
server_config.zig      # NEW: ServerConfig (+ fromEnv, isAllowed, isProtectedMode)
protocol/framing.zig   # NEW: HEADER_SIZE, base Status, writeResp/writeErrorResp(Sub), TLV codec, processFrames, writeRowList, readOptionalString
run.zig                # NEW: generic run(Store, ctx, ServerConfig) bootstrap
tsgen.zig              # NEW: reflection emitters parameterized over a field→TS-type/reader table
root.zig               # barrel: re-exports the full public surface + aggregates engine tests
```

**zig-directory/src/ (dmozdb — app residual):**

```
schema.zig             # NEW: Category, Link, LinkStatus, RepairOp, RepairTask + ParentChild/CategoryLink/SubmitterLink key wrappers + size-assert tests
directory.zig          # NEW (was database.zig): Directory composes Store; url_bloom, subtree_cache, status counts, verifier_state; recover hooks + worker ticks
changeset.zig          # residual: Op/Effect/ChangeSet union + encode/decode wrappers calling zigstore.wire_codec
binary_protocol.zig    # residual: Op enum, SubStatus, mapErrorWithSubStatus, dispatch, all handle* fns
main.zig               # residual: DMOZ Config + DMOZDB_* env, branding, Directory instantiation, zigstore.run call
gen_client_ts.zig      # residual: driver — defines the field-table + writeLinkStatusEnum, calls zigstore.tsgen
operations/* apply/* verifier.zig subtree.zig repair/* wal_apply.zig import_main.zig   # stay app-side
# types.zig DELETED (split into zigstore/codec.zig + dmozdb/schema.zig)
```

---

## Phase 0 — Dual-repo branches and the `.path` dev loop

**Files:**
- Create: `zig-directory/build.zig.zon`
- Modify: `zig-directory/build.zig`
- Branches: `zigstore` → `feat/engine-extraction`; `zig-directory` → `feat/zigstore-extraction`

- [ ] **Step 1: Branch both repos**

```bash
git -C /Users/junaidahmed/Desktop/projects/zigstore switch -c feat/engine-extraction
git -C /Users/junaidahmed/Desktop/projects/zig-directory switch -c feat/zigstore-extraction
```

- [ ] **Step 2: Create dmozdb's `build.zig.zon` with the `.path` dependency**

Create `zig-directory/build.zig.zon` (get the fingerprint the same way zigstore did — write without it, run `zig build`, paste the suggested value):

```zig
.{
    .name = .dmozdb,
    .version = "0.6.0",
    .fingerprint = 0x0, // replace with the value `zig build` suggests on first run
    .minimum_zig_version = "0.15.2",
    .dependencies = .{
        .zigstore = .{ .path = "../zigstore" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

- [ ] **Step 3: Wire the zigstore module into dmozdb's `build.zig`**

In `zig-directory/build.zig`, after the `target`/`optimize` lines, add a helper and attach the import to every module (`exe_mod`, `test_mod`, `gen_client_mod`, and the tool modules). Add at the top of `build()`:

```zig
const zigstore = b.dependency("zigstore", .{ .target = target, .optimize = optimize }).module("zigstore");
```

Then after each `b.createModule(...)` that roots a dmozdb compile, add:

```zig
exe_mod.addImport("zigstore", zigstore);
test_mod.addImport("zigstore", zigstore);
gen_client_mod.addImport("zigstore", zigstore);
```

(and the same for `bench_mod`/`import_mod` inside the `build_tools` branch).

- [ ] **Step 4: Verify the dependency resolves (compile-only is fine here)**

Run in the dmozdb devcontainer:
```bash
cd /Users/junaidahmed/Desktop/projects/zig-directory && zig build --help >/dev/null && echo "deps resolve"
```
Expected: prints `deps resolve` (the `zigstore` module is found at `../zigstore`). It is not yet imported by any source file — that starts in Phase 1.

- [ ] **Step 5: Commit (both repos)**

```bash
git -C /Users/junaidahmed/Desktop/projects/zig-directory -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  add build.zig build.zig.zon && \
git -C /Users/junaidahmed/Desktop/projects/zig-directory -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  commit -m "build: add zigstore .path dependency (engine extraction, phase 0)"
```

---

## Phase 1 (§9 step 1) — Split `types.zig` → `codec.zig` (engine, done) + `schema.zig` (app)

This lands first because `changeset.zig`, `subtree.zig`, `gen_client_ts.zig`, `operations/*`, `apply/*`, `binary_protocol.zig`, `verifier.zig`, `repair/*`, and `database.zig` all reach through `types.zig`.

**Files:**
- Verify: `zigstore/src/codec.zig` (already holds the codec half)
- Create: `zig-directory/src/schema.zig`
- Modify: every dmozdb file importing `types.zig` (repoint)
- Delete: `zig-directory/src/types.zig`

- [ ] **Step 1: Confirm the engine codec half is complete**

```bash
grep -E 'pub (fn|const) (Serializable|FixedString|CompositeKey|encodeU64|decodeU64|hash)' \
  /Users/junaidahmed/Desktop/projects/zigstore/src/codec.zig
```
Expected: all six present. No engine change needed.

- [ ] **Step 2: Create `zig-directory/src/schema.zig` with the app records**

Port verbatim from `zig-directory/src/types.zig` the residual (records + key wrappers + their size-assert tests), changing the codec imports to come from zigstore:

```zig
const std = @import("std");
const codec = @import("zigstore").codec;
const FixedString = codec.FixedString;
const Serializable = codec.Serializable;
const CompositeKey = codec.CompositeKey;

// Port verbatim from src/types.zig:
//   - Category (lines 66-90) + its size-assert (92-96)
//   - LinkStatus (98-103)
//   - Link (105-130) + its size-assert (132-136)
//   - RepairOp (138-141), RepairTask (143-155) + size-assert (157-160)
//   - ParentChildKey/CategoryLinkKey/SubmitterLinkKey (220-264)
//   - the record/key tests (the DMOZ-specific ones: 317-490)
// Change nothing in the bodies except that FixedString/Serializable/CompositeKey
// now resolve from `codec` above instead of being defined in this file.
```

- [ ] **Step 3: Repoint every dmozdb importer of `types.zig`**

For each dmozdb file that does `@import("types.zig")` (or `../types.zig`), split the reference:
- codec primitives (`FixedString`, `Serializable`, `CompositeKey`, `encodeU64`, `decodeU64`, `hashUrl`→`hash`) → `@import("zigstore").codec`
- records/keys (`Category`, `Link`, `LinkStatus`, `RepairOp`, `RepairTask`, `*Key`) → `@import("schema.zig")` (adjust relative depth for `operations/`, `apply/`, `btree/`, `wal/`, `repair/` subdirs, e.g. `@import("../schema.zig")`)

Find them:
```bash
cd /Users/junaidahmed/Desktop/projects/zig-directory && grep -rln 'types.zig' src --include='*.zig'
```
Repoint each. Note `hashUrl` was renamed to `codec.hash` — update call sites accordingly.

- [ ] **Step 4: Delete `types.zig`**

```bash
git -C /Users/junaidahmed/Desktop/projects/zig-directory rm src/types.zig
```

- [ ] **Step 5: Gate (dmozdb devcontainer)**

Run: `cd /Users/junaidahmed/Desktop/projects/zig-directory && zig build test`
Expected: PASS. The codec primitives now come from zigstore; the records live in `schema.zig`. If a file still references `types.`, the compile error names it — repoint and re-run.

- [ ] **Step 6: Commit**

```bash
git -C /Users/junaidahmed/Desktop/projects/zig-directory -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  add -A && git -C /Users/junaidahmed/Desktop/projects/zig-directory -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  commit -m "refactor: split types.zig into zigstore codec + app schema.zig"
```

---

## Phase 2 (§9 step 2) — Lift `changeset.zig`'s codec → `wire_codec.zig`

**Files:**
- Create: `zigstore/src/wire_codec.zig`
- Modify: `zigstore/src/root.zig` (export `wire_codec`)
- Modify: `zig-directory/src/changeset.zig` (residual: Op/Effect/ChangeSet, calls into `zigstore.wire_codec`)

- [ ] **Step 1: Write the failing engine test for `wire_codec`**

Create `zigstore/src/wire_codec.zig` with only this test first:

```zig
const std = @import("std");

test "encodeStruct/decodeStruct round-trips a generic extern struct" {
    const Rec = extern struct { id: u64, n: u32, _pad: u32 = 0 };
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try encodeStruct(std.testing.allocator, &buf, Rec{ .id = 7, .n = 3 });
    var cur: usize = 0;
    const got = try decodeStruct(std.testing.allocator, Rec, buf.items, &cur);
    try std.testing.expectEqual(@as(u64, 7), got.id);
    try std.testing.expectEqual(@as(u32, 3), got.n);
}
```

- [ ] **Step 2: Run it — expect failure (undefined `encodeStruct`)**

Run (host ok, pure comptime/mem): `ZIG=~/Library/zig/0.15.2/zig; $ZIG test /Users/junaidahmed/Desktop/projects/zigstore/src/wire_codec.zig`
Expected: FAIL — `encodeStruct`/`decodeStruct` not defined.

- [ ] **Step 3: Port the generic codec body**

Into `wire_codec.zig`, port from `zig-directory/src/changeset.zig` the `@typeInfo`-driven functions and error types (per the survey, the encode/decode struct/field machinery + version framing). Add `//!`/`///` doc comments on the public surface (zigstore's comment policy). Public surface:

```zig
pub const EncodeError = error{ OutOfMemory, StringTooLong };
pub const DecodeError = error{ BufferTooShort, UnknownOpTag, UnsupportedSchemaVersion, InvalidEnumValue, OutOfMemory };
pub fn encodeField(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: anytype) EncodeError!void { ... }
pub fn decodeField(arena: std.mem.Allocator, comptime T: type, bytes: []const u8, cur: *usize) DecodeError!T { ... }
pub fn encodeStruct(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: anytype) EncodeError!void { ... }
pub fn decodeStruct(arena: std.mem.Allocator, comptime T: type, bytes: []const u8, cur: *usize) DecodeError!T { ... }
```

Port the version-framing helper (1 byte version + 1 byte op tag + struct bytes) too, but keep the **`SCHEMA_VERSION` constant app-side** — pass the version in as a parameter so the engine hardcodes no app version.

- [ ] **Step 4: Run the test — expect PASS**

Run: `$ZIG test /Users/junaidahmed/Desktop/projects/zigstore/src/wire_codec.zig`
Expected: PASS.

- [ ] **Step 5: Export from the barrel**

In `zigstore/src/root.zig` add: `pub const wire_codec = @import("wire_codec.zig");` and add `_ = @import("wire_codec.zig");` to the aggregating `test {}`.

- [ ] **Step 6: Engine gate + commit (zigstore)**

Run: `cd /Users/junaidahmed/Desktop/projects/zigstore && zig build test` → PASS. Commit:
```bash
git -C /Users/junaidahmed/Desktop/projects/zigstore -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  add -A && git -C /Users/junaidahmed/Desktop/projects/zigstore -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  commit -m "feat: lift changeset codec into wire_codec (generic @typeInfo marshaller)"
```

- [ ] **Step 7: Rewrite dmozdb `changeset.zig` to call `zigstore.wire_codec`**

Keep the app `Op`/`Effect`/`ChangeSet` union and the top-level `encode(allocator, cs)`/`decode(arena, bytes)` wrappers, but delete the inlined struct/field marshalling and replace its calls with `zigstore.wire_codec.encodeStruct(...)`/`decodeStruct(...)`, passing the app's `SCHEMA_VERSION`. Repoint imports (`@import("zigstore").wire_codec`).

- [ ] **Step 8: dmozdb gate + commit**

Run: `cd /Users/junaidahmed/Desktop/projects/zig-directory && zig build test` → PASS. Commit `refactor: changeset.zig delegates marshalling to zigstore.wire_codec`.

---

## Phase 3 (§9 step 3) — Move the 17 zero-back-edge files

These import only each other (or `std`) and carry zero DMOZ tokens in code. Move, repoint, and let their tests travel.

**Files (move `zig-directory/src/X` → `zigstore/src/X`):** `page.zig`, `page_cache.zig`, `freelist.zig`, `memtable.zig`, `bloom.zig`, `inverted_index.zig`, `histogram.zig`, `connection.zig`, `signal.zig`, `btree/{btree,btree_insert,btree_delete,btree_search,btree_repair,btree_helpers}.zig`, `wal/wal.zig`→`zigstore/src/wal.zig`, `wal/wal_replay.zig`→`zigstore/src/wal_replay.zig`.

- [ ] **Step 1: Copy the storage/index leaves**

```bash
cd /Users/junaidahmed/Desktop/projects/zig-directory
mkdir -p /Users/junaidahmed/Desktop/projects/zigstore/src/btree
cp src/page.zig src/page_cache.zig src/freelist.zig src/memtable.zig src/bloom.zig \
   src/inverted_index.zig src/histogram.zig src/connection.zig src/signal.zig \
   /Users/junaidahmed/Desktop/projects/zigstore/src/
cp src/btree/*.zig /Users/junaidahmed/Desktop/projects/zigstore/src/btree/
cp src/wal/wal.zig /Users/junaidahmed/Desktop/projects/zigstore/src/wal.zig
cp src/wal/wal_replay.zig /Users/junaidahmed/Desktop/projects/zigstore/src/wal_replay.zig
```

- [ ] **Step 2: Repoint imports in the moved files**

- `wal.zig`/`wal_replay.zig`: change `@import("../page.zig")` → `@import("page.zig")`, `@import("../page_cache.zig")` → `@import("page_cache.zig")` (they sit at `src/` now, not `src/wal/`). Change any `@import("wal.zig")` cross-reference to the sibling `@import("wal.zig")`.
- `btree/*.zig`: `@import("../page.zig")`, `@import("../page_cache.zig")`, `@import("../freelist.zig")` stay valid (btree/ is one level under src/, same as before). `@import("btree.zig")` stays valid.
- `page_cache.zig`, `freelist.zig`: their `@import("page.zig")`/`@import("page_cache.zig")` stay valid (all siblings in `src/`).
- Confirm WAL `OpCode` is referenced as a plain `u8` on the wire (engine namespaces no op codes); leave the app to own record-kind codes.

Verify nothing reaches back:
```bash
cd /Users/junaidahmed/Desktop/projects/zigstore && grep -rEn 'types\.zig|database\.zig|changeset\.zig|operations|\.\./\.\.' src --include='*.zig' || echo "NO BACK-EDGES"
```

- [ ] **Step 3: Aggregate the moved tests in the barrel**

In `zigstore/src/root.zig`'s `test {}`, add `_ = @import("X");` for each moved file (page, page_cache, freelist, memtable, bloom, inverted_index, histogram, connection, signal, wal, wal_replay, and each btree/*). Do **not** publicly re-export internals you don't want in the API yet — only aggregate their tests. (Public re-exports of `EpollServer`/etc. come in Phase 6.)

- [ ] **Step 4: Engine gate (devcontainer — paged storage needs Linux)**

Run in the zigstore devcontainer: `cd /Users/junaidahmed/Desktop/projects/zigstore && zig build test`
Expected: PASS, including the btree/page/wal roundtrip tests that travelled. Run the boundary check from Ground Rule 2 → `BOUNDARY CLEAN`.

- [ ] **Step 5: Delete the originals from dmozdb and commit both**

Defer deleting the dmozdb originals until Phase 8 (dmozdb still imports them relatively until its modules flip to `@import("zigstore")`). For now, commit the engine additions:
```bash
git -C /Users/junaidahmed/Desktop/projects/zigstore -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  add -A && git -C /Users/junaidahmed/Desktop/projects/zigstore -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  commit -m "feat: move paged storage, btree, wal, connection, signal into zigstore"
```

---

## Phase 4 (§9 step 4) — Generate `Store.Header`; carve `Store`; invert engine→app imports

The central carve. The v0 `engine.zig` already generates the right `Header` and the `tree(name)`/`counter(name)`/`nextId(name)` accessors over an **in-memory** `OrderedTree`. This phase swaps that backing for the paged B+Tree and adds the `recover`/`spawnWorker` seams, then splits `database.zig` into the app `Directory`.

**Files:**
- Create: `zigstore/src/file_header.zig` (generic superblock serialize/deserialize/validate over the generated `Header`)
- Modify: `zigstore/src/engine.zig` (paged-backed `Store`; `init`/`flushHeader`/`drainMemtables`/`recover`/`spawnWorker`)
- Modify: `zigstore/src/root.zig`
- Create: `zig-directory/src/directory.zig` (was `database.zig`)
- Modify (parameter type `*Database` → `*Directory`, field accesses → accessors — see Step 7): `zig-directory/src/main.zig`, `operations/operations_category.zig`, `operations/operations_link.zig`, `operations/operations_search.zig`, `operations/operations_slug.zig`, `operations/operations_changeset_compute.zig`, `operations/operations_shared.zig`, `apply/apply.zig`, `apply/apply_category.zig`, `apply/apply_link.zig`, `apply/apply_repair.zig`, `verifier.zig`, `subtree.zig`, `repair/repair_worker.zig`, `wal/wal_apply.zig`, `binary_protocol.zig` (handlers pass the handle through)

- [ ] **Step 1: Generic superblock — `file_header.zig`**

Create `zigstore/src/file_header.zig` providing `serialize(header) [PAGE_SIZE]u8`, `deserialize(bytes) Header`, `validate(header, expected_magic, expected_version) !void`, over the **comptime-generated** `Header` type (passed in / re-exported from `engine.zig`). Port the body from `zig-directory/src/file_header.zig`, deleting the hardcoded `MAGIC`/`VERSION` constants and the named DMOZ root/count fields — those are now generated. Keep the page-size assert and the bad-magic/bad-version/bad-page-size validation tests, parameterized over the app-supplied magic.

- [ ] **Step 2: Write the failing engine test for a paged Store**

Add to `engine.zig` a test that opens a **temp-file-backed** Store (mirroring dmozdb's `openTestInstance`) and exercises a tree + a counter across a flush/reopen:

```zig
test "paged Store: put/get/range survive flushHeader + reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    var s = try TestStore.init(std.testing.allocator, .{ .data_dir = path, .cache_size_mb = 4 });
    const id = s.nextId("next_id");
    try s.tree("by_id").insert(&codec.encodeU64(id), "hello");
    try s.flushHeader();
    s.deinit();

    var s2 = try TestStore.init(std.testing.allocator, .{ .data_dir = path, .cache_size_mb = 4 });
    defer s2.deinit();
    var out: [64]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "hello", (try s2.tree("by_id").search(&codec.encodeU64(1), &out)).?);
    try std.testing.expectEqual(@as(u64, 1), s2.header.next_id);
}
```

Run in the devcontainer → FAIL (`init`/paged `tree` not defined). Note the tree API is now the **BPlusTree** API (`insert`, `search(key, out_buf)`, `delete`, `rangeScan`), replacing the v0 `OrderedTree` API.

- [ ] **Step 3: Replace the tree backing with the paged B+Tree**

In `engine.zig`:
- Make the generated `Store` hold `allocator`, `file: std.fs.File`, `header: Header`, `cache: PageCache`, `free_list: FreeList`, `wal: WalWriter`, the named `BPlusTree`s (one per `schema.indexes`, replacing `OrderedTree`), the named `MemTable`s (one per `schema.memtable_indexes`), the flush/drain/apply-ordering machinery (`mt_flusher` thread, `mt_drain_mutex`, `apply_mutex`/`apply_cond`/`last_applied_seq`, `header_lock`, `snapshot_in_progress`), and `op_latency: [256]AtomicHistogram`.
- Generalize the v0 comptime walk: `inline for (s.indexes)` now wires each `BPlusTree` to `&cache`/`&free_list` and loads its `root_page` from `@field(header, name ++ "_root")`. Port the body of `database.zig`'s `init` (the `inline for (tree_fields)` at lines 312-316) and `flushHeader` (lines 578-581), driving them from `s.indexes` instead of the hardcoded `tree_fields` table.
- `tree(comptime name)` returns `*BPlusTree`; `counter`/`nextId` are unchanged but their slot is now persisted via `flushHeader`.
- **Add a memtable accessor** parallel to `tree`: `pub fn memtable(self: *Store, comptime name: [:0]const u8) *MemTable` resolving against `schema.memtable_indexes` (comptime-checked; `@compileError` if `name` is not a declared memtable index). The app's operations reach the write memtables through this, not through named fields. Also expose `pub fn drainMemtables(self: *Store) !void` (the generalized `drainOneInner` over `schema.memtable_indexes` → their backing trees).
- Add `pub const Config = struct { data_dir: []const u8, cache_size_mb: u32 = 64 };` as the engine-level open config (distinct from app `ServerConfig`).
- Remove the v0 in-memory `OrderedTree` (or keep it under a clearly-named test-only helper). Update the v0 example/tests to the BPlusTree API.

Run the Step-2 test → PASS.

- [ ] **Step 4: Add the `recover` seam (TDD)**

Write a failing test (with a stub `ctx` and counters): a Store with a WAL of N entries — `recover(ctx, hooks)` calls `apply_entry` once per replayed entry, then `on_replayed` once after drain+flush, and `bootstrap` only when the store was empty. Then implement:

```zig
pub const ReplayEntry = wal_replay.ReplayEntry; // { sequence: u64, op_code: u8, data: []const u8 }

pub fn recover(self: *Store, ctx: *anyopaque, hooks: struct {
    apply_entry: *const fn (ctx: *anyopaque, entry: ReplayEntry) anyerror!void,
    on_replayed: *const fn (ctx: *anyopaque) anyerror!void,
    bootstrap: *const fn (ctx: *anyopaque) anyerror!void,
}) !void {
    // engine owns ordering: wal_replay.replayWal over self, invoking hooks.apply_entry per
    // decoded entry; then drainMemtables() + flushHeader(); then hooks.on_replayed(ctx);
    // if the store was empty, hooks.bootstrap(ctx). Port the replay/drain/flush body from
    // database.zig::recover (lines ~530-565).
}
```

The hook context is `*anyopaque` (the app `Directory`), matching the `run`/`processFrames` ctx pattern — so a hook can reach both `store` trees and Directory-owned state (bloom, status counts). **The engine imports neither `changeset` nor `wal_apply`:** the per-entry changeset-decode-and-apply that was `wal_apply.WalApplier.apply` becomes `hooks.apply_entry`; the aggregate recompute that was `operations.recompute*` becomes `hooks.on_replayed`. Run → PASS.

- [ ] **Step 5: Add the `spawnWorker` seam (TDD)**

Write a failing test: `spawnWorker(ctx, .{ .interval_ns = 1_000_000, .tick = &countTick })` runs the tick ≥1 time then `worker.stop()` joins cleanly (assert a counter advanced, no leak under `std.testing.allocator`). Implement the generic thread/cond/mutex/shutdown/interval scaffolding (port from `database.zig`'s verifier/repair loop machinery), calling `tick(ctx)` on the interval:

```zig
pub const Worker = struct { thread: std.Thread, shutdown: std.atomic.Value(bool), cond: std.Thread.Condition, mutex: std.Thread.Mutex, pub fn stop(self: *Worker) void { ... } };
pub fn spawnWorker(self: *Store, ctx: *anyopaque, cfg: struct { interval_ns: u64, tick: *const fn (ctx: *anyopaque) anyerror!void }) !*Worker { ... }
```

The tick takes the same `*anyopaque` app `ctx` as `recover`, so a tick (`verifyOnce`/`repairOnce`) reaches both `store` trees and Directory state.

Run → PASS. Update `root.zig` exports/test aggregation. Engine gate → PASS; boundary check → CLEAN. Commit `feat: paged Store(schema) with recover + spawnWorker seams`.

- [ ] **Step 6: Carve `database.zig` → `directory.zig` (app)**

Rename `zig-directory/src/database.zig` → `src/directory.zig`. The struct becomes `Directory`, and it is the single handle every app module operates on (replacing `*Database`):
- holds `store: Store` (= `zigstore.Engine(schema)`), `config: Config` (the DMOZ config), `url_bloom: BloomFilter`, `subtree_cache: SubtreeCache`, `verifier_state: VerifierState`, and `links_pending_count`/`approved`/`rejected`.
- deletes the fields now owned by `Store` (file/header/cache/free_list/wal/memtables/flusher/apply-ordering/op_latency/the 11 trees/the 3 counters).
- **delegating accessors** so app modules reach the data plane through one handle (these are what Step 7 repoints the operations' `db.<field>` accesses onto):
  ```zig
  pub fn tree(self: *Directory, comptime n: [:0]const u8) *zigstore.BPlusTree { return self.store.tree(n); }
  pub fn memtable(self: *Directory, comptime n: [:0]const u8) *zigstore.MemTable { return self.store.memtable(n); }
  pub fn counter(self: *Directory, comptime n: [:0]const u8) *u64 { return self.store.counter(n); }
  pub fn nextId(self: *Directory, comptime n: [:0]const u8) u64 { return self.store.nextId(n); }
  ```
- recover/worker callbacks take `ctx: *anyopaque` and cast it back, so they reach both `dir.store` trees and `dir.url_bloom`/counts:
  ```zig
  fn asDir(ctx: *anyopaque) *Directory { return @ptrCast(@alignCast(ctx)); }
  pub fn applyEntry(ctx: *anyopaque, e: zigstore.ReplayEntry) !void { const dir = asDir(ctx); ... } // was wal_apply.WalApplier.apply: decode changeset, apply to dir.tree(...), bump dir counts/bloom
  pub fn recomputeCounts(ctx: *anyopaque) !void { const dir = asDir(ctx); ... }                      // was operations.recompute* + rebuild url_bloom/subtree_cache
  pub fn bootstrapRoots(ctx: *anyopaque) !void { const dir = asDir(ctx); ... }                       // was bootstrapRootCategories
  pub fn verifyOnce(ctx: *anyopaque) !void { const dir = asDir(ctx); ... }                           // was verifier.runOnce
  pub fn repairOnce(ctx: *anyopaque) !void { const dir = asDir(ctx); ... }                           // was repair_worker.tickOnce
  ```
- `Directory.commit(cs)` keeps the existing local commit path for now; it is rewired to the generic engine `commit` in Phase 5.

- [ ] **Step 7: Repoint `main.zig`, the operations, and the worker modules onto `*Directory`**

`main.zig`: replace `Database.init` with `Directory.init`; replace the verifier/repair thread spawns with `dir.store.spawnWorker(&dir, .{ .interval_ns = ..., .tick = &Directory.verifyOnce })` and `&Directory.repairOnce`; replace `db.recover()` with `dir.store.recover(&dir, .{ .apply_entry = &Directory.applyEntry, .on_replayed = &Directory.recomputeCounts, .bootstrap = &Directory.bootstrapRoots })`. `verifier.zig`/`repair_worker.zig`: keep the tick bodies, drop the thread-owning `loop`.

**The app data-plane repoint (this is the bulk of the app-side diff).** Every app module that took `db: *Database` now takes `dir: *Directory` and rewrites its accesses by category — there is no `Database` struct anymore:

- **named tree fields** `db.categories_by_id.search(...)`, `db.cat_by_parent.insert(...)`, … → `dir.tree("categories_by_id").search(...)`, `dir.tree("cat_by_parent").insert(...)`, … (all 11 indexes). The tree API is the `BPlusTree` API (`search(key, out_buf)`, `insert`, `delete`, `rangeScan`, `entryCount`), unchanged from today.
- **memtables** `db.mt_categories_by_id`, … and `db.drainOneMemtable(...)` → `dir.memtable("categories_by_id")`, … and `dir.store.drainMemtables()`.
- **Directory-owned state** (names unchanged, now on `Directory`): `db.url_bloom` → `dir.url_bloom`; `db.links_pending_count`/`approved`/`rejected` → `dir.links_pending_count`/…; `db.config.*` → `dir.config.*`; `db.subtree_cache` → `dir.subtree_cache`; `db.verifier_state` → `dir.verifier_state`.
- **counters** `db.next_category_id` (atomic) → `dir.nextId("next_category_id")` / `dir.counter("next_category_id").*`.

Find every site mechanically, then repoint each:
```bash
cd /Users/junaidahmed/Desktop/projects/zig-directory
grep -rnE 'db\.(categories_by_id|cat_by_parent|links_by_id|link_by_category|link_by_url_hash|link_by_submitter|categories_by_slug_path|categories_by_slug_only|categories_index_tree|links_index_tree|slug_path_repair_queue|mt_[a-z_]+|drainOneMemtable|url_bloom|links_(pending|approved|rejected)_count|next_(category|link|repair)_id|next_repair_seq)' src --include='*.zig'
```
Apply to: `operations/{operations_category,operations_link,operations_search,operations_slug,operations_changeset_compute,operations_shared}.zig`, `apply/{apply,apply_category,apply_link,apply_repair}.zig`, `verifier.zig`, `subtree.zig`, `repair/repair_worker.zig`, `wal/wal_apply.zig`, and the `handle*` fns in `binary_protocol.zig` (they thread `dir` to the operations). `operations/operations.zig` stays a re-export barrel.

> Churn-reduction option: if the per-site `db.X` → `dir.tree("X")` rewrite is too broad to land in one task, give `Directory` named inline tree wrappers (`pub fn categories_by_id(self: *Directory) *zigstore.BPlusTree { return self.store.tree("categories_by_id"); }`, one per index) so call sites change only `db.categories_by_id` → `dir.categories_by_id()`. This trades a little app boilerplate for a smaller, lower-risk diff. Either approach is acceptable; pick one and apply it consistently.

- [ ] **Step 8: dmozdb gate (devcontainer) + commit both**

Run in the dmozdb devcontainer: `cd /Users/junaidahmed/Desktop/projects/zig-directory && zig build test` → PASS. Commit the engine and app changes (two commits, one per repo) — `feat: carve Database into app Directory composing zigstore.Store`.

---

## Phase 5 (§9 step 5) — Genericize `snapshot.zig` (`SnapshotHost`) and `commit.zig` (record type)

**Files:**
- Create: `zigstore/src/snapshot.zig`, `zigstore/src/commit.zig`
- Modify: `zigstore/src/engine.zig` (Store satisfies `SnapshotHost`; exposes generic `commit`)
- Modify: `zigstore/src/root.zig`; `zig-directory/src/directory.zig`, `wal_apply.zig`

- [ ] **Step 1: Define `SnapshotHost` and move snapshot (TDD)**

Move `zig-directory/src/snapshot.zig` → `zigstore/src/snapshot.zig`. Replace every `db: anytype` with a formal interface. Write the interface and make the generated `Store` satisfy it:

```zig
pub const SnapshotHost = struct {
    snapshot_in_progress: *std.atomic.Value(bool),
    data_dir: []const u8,
    apply_mutex: *std.Thread.Mutex,
    mt_drain_mutex: *std.Thread.Mutex,
    page_count: u64,
    walSequence: *const fn (ctx: *anyopaque) u64,
    flushCache: *const fn (ctx: *anyopaque) anyerror!void,
    flushHeader: *const fn (ctx: *anyopaque) anyerror!void,
    ctx: *anyopaque,
};
```

Port `forceSnapshot`/`createSnapshot` bodies, replacing each `db.X` access with the matching `SnapshotHost` member. Add `Store.snapshotHost(self) SnapshotHost`. Test: a temp-file Store produces a snapshot and `snapshot.meta` with the expected sequence. Run (devcontainer) → PASS.

- [ ] **Step 2: Genericize commit (TDD)**

Move `commit.zig` → `zigstore/src/commit.zig`. Make it generic over a record type with app callbacks; the engine owns WAL-append + monotonic-seq ordering (seq N applies only after N−1, broadcast) + durability wait:

```zig
pub fn commit(
    comptime Record: type,
    store: anytype,                 // *Store (has wal, apply_mutex, apply_cond, last_applied_seq)
    record: Record,
    serialize_fn: *const fn (std.mem.Allocator, Record) std.mem.Allocator.Error![]u8,
    apply_fn: *const fn (@TypeOf(store), Record) anyerror!void,
) !void { ... }
```

Port the seq-gating/durability body from the old `commit.zig` (lines 11-37), substituting the callbacks for `changeset.encode`/`apply_mod.apply`. Test: two concurrent commits apply in seq order (assert `last_applied_seq` monotonic). Run → PASS. Export `commit`/`snapshot`/`SnapshotHost` from `root.zig`. Engine gate + boundary check → CLEAN. Commit.

- [ ] **Step 3: Rewire dmozdb to the generic commit**

`directory.zig`: `Directory.commit(cs)` now calls `zigstore.commit(ChangeSet, &self.store, cs, &serializeChangeSet, &applyChangeSet)`. `wal_apply.zig` stays app-side and is the body of `Directory.applyEntry` — invoked per WAL entry through the recover `apply_entry` hook (Phase 4 Step 4), not `on_replayed`. dmozdb gate (devcontainer) → PASS. Commit both.

---

## Phase 6 (§9 step 6) — `ServerConfig`, generic `epoll`, `protocol/framing`, `run`

**Files:**
- Create: `zigstore/src/server_config.zig`, `zigstore/src/protocol/framing.zig`, `zigstore/src/run.zig`
- Create (move from `zig-directory/src/epoll.zig` + genericize over ctx + Handler + ServerConfig): `zigstore/src/epoll.zig`
- Modify: `zigstore/src/root.zig`
- Modify: `zig-directory/src/binary_protocol.zig` (residual), `zig-directory/src/main.zig`, `zig-directory/src/directory.zig` (dispatch)

- [ ] **Step 1: `ServerConfig`**

Create `zigstore/src/server_config.zig`. Port the generic config fields + parsing from `main.zig`'s `Config`: `port`, `bind_address`, `cache_size_mb`, `thread_count`, `snapshot_interval_s`, `wal_sync_interval_ms`, `wal_batch_size`, the trust-list (`trusted_ips`/`trusted_cidrs` + `isAllowed`/`isProtectedMode`), and a `fromEnv()` that reads the **generic** env keys. Leave DMOZ-only knobs (`data_dir` semantics, `rename_inline_threshold`, repair/subtree knobs) for the app. Add unit tests for `isAllowed`/CIDR parsing (port from existing). Run (host ok) → PASS.

- [ ] **Step 2: `protocol/framing.zig` with the injected dispatch callback (TDD)**

Create `zigstore/src/protocol/framing.zig`. Write a failing test first: feed a framed request buffer to `processFrames` with a stub `dispatch_fn` that echoes, assert the response framing + that `op_latency[op_byte]` recorded a sample. Then port from `binary_protocol.zig` the generic half:

```zig
pub const REQUEST_HEADER_SIZE: usize = 8;
pub const RESPONSE_HEADER_SIZE: usize = 10;
pub const HEADER_SIZE = REQUEST_HEADER_SIZE;
pub const Status = enum(u8) { ok = 0, not_found = 1, duplicate = 2, invalid = 3, err = 4 };
pub fn writeResp(buf: []u8, op: u8, status: Status, count: u16, payload: []const u8) usize { ... }
pub fn writeErrorResp(buf: []u8, op: u8, status: Status) usize { ... }
pub fn writeErrorRespSub(buf: []u8, op: u8, status: Status, sub: u8) usize { ... }
pub fn readOptionalString(payload: []const u8, off: *usize, mask: u8, bit: u8) ?(?[]const u8) { ... }
pub fn writeRowList(comptime T: type, resp: []u8, op_byte: u8, items: []const T) usize { ... }
// comptime TLV codec: parsePayload/advancePayload/ReadResult/ParsedPayload (move as-is)
pub fn processFrames(
    ctx: *anyopaque,
    conn: *connection.Connection,
    dispatch_fn: *const fn (ctx: *anyopaque, op_byte: u8, payload: []const u8, count: u16, resp: []u8) usize,
    op_latency: *[256]histogram.AtomicHistogram,
) void { ... }  // parses raw op_byte (NEVER maps to an app Op enum), records op_latency[op_byte], pipelines
```

`processFrames` passes the **raw `u8`** op to `dispatch_fn` and records latency by raw op byte. Run → PASS.

- [ ] **Step 3: Genericize `epoll.zig` over ctx + Handler + ServerConfig**

Move/modify `epoll.zig`: replace `db: *Database`/`config: Config` with `ctx: *anyopaque` + a runtime `Handler { processFrames: *const fn (*anyopaque, *Connection) void, HEADER_SIZE: usize }` + `ServerConfig`. The socket/epoll_wait/connection-lifecycle/idle-sweep code is generic and unchanged. The `db.flushHeader()` periodic call becomes a `Handler`-supplied callback or a `ctx` method invoked generically. Make it `EpollServer(comptime Store: type)`.

- [ ] **Step 4: `run.zig` generic bootstrap**

Create `zigstore/src/run.zig`: `pub fn run(comptime Store: type, ctx: *anyopaque, config: ServerConfig) !void` — allocate, set up `signal.setupSignalHandlers`, spawn `config.thread_count` reactors over `EpollServer(Store)`, wait for shutdown. Port the reactor-spawn loop from `main.zig:223-247`. Export `protocol`, `ServerConfig`, `EpollServer`, `run` from `root.zig`. Engine gate (devcontainer) → PASS; boundary → CLEAN. Commit `feat: generic epoll reactor + protocol framing + run bootstrap`.

- [ ] **Step 5: dmozdb residual — `binary_protocol.zig`, `main.zig`, dispatch**

`binary_protocol.zig` keeps the `Op` enum, `SubStatus`, `mapErrorWithSubStatus`, `dispatch`, and all `handle*` fns; it imports `zigstore.protocol` for `Status`/`writeResp`/`writeRowList`/TLV/`HEADER_SIZE`. Add `Directory.dispatch(ctx, op_byte, payload, count, resp) usize` that `@ptrCast`es `ctx`→`*Directory` and routes to the handlers. `main.zig`: build the `Handler` from `Directory.dispatch`, call `zigstore.run(Store, &directory, server_config)`; keep DMOZ `Config` (composing `ServerConfig` + DMOZ knobs), `DMOZDB_*` env keys, and the `Top`/`Lost and Found` branding app-side. dmozdb gate (devcontainer) → PASS. Commit both.

---

## Phase 7 (§9 step 7) — Lift `tsgen` emitters; rebuild the app codegen driver

**Files:**
- Create: `zigstore/src/tsgen.zig`; Modify `zigstore/src/root.zig`
- Modify: `zig-directory/src/gen_client_ts.zig` (driver), `zig-directory/web/lib/dmoz-protocol.gen.ts` (regenerated)

- [ ] **Step 1: `tsgen.zig` parameterized over a field table (TDD)**

Create `zigstore/src/tsgen.zig`. Write a failing test: emit a TS interface + reader for a small `extern struct` via a stub `FieldTable`, assert the emitted string contains the expected field lines. Then port the reflection emitters from `gen_client_ts.zig` (`writeStructInterface`, `writeStructReader`, `writeOpEnum`, `writeStatusEnum`, `writeStatusMap`, the name-munging helpers), parameterized over a comptime `FieldTable` providing `tsType(comptime T, comptime field_name) []const u8` and `reader(comptime T, comptime field_name) []const u8`. Run (host ok) → PASS. Export `tsgen` from `root.zig`. Engine gate + commit.

- [ ] **Step 2: dmozdb codegen driver**

`gen_client_ts.zig` becomes a thin driver: defines the DMOZ `FieldTable` (the `status→LinkStatus`, `created_at`/`updated_at`→`Date` special cases), keeps `writeLinkStatusEnum`, imports `zigstore.tsgen`, and writes to `web/lib/dmoz-protocol.gen.ts`.

- [ ] **Step 3: Regenerate the client and verify**

Run (devcontainer): `cd /Users/junaidahmed/Desktop/projects/zig-directory && zig build gen-client-ts && cd web && deno check`
Expected: regenerates `web/lib/dmoz-protocol.gen.ts` byte-compatibly (or with only intended diffs) and `deno check` passes. Commit `refactor: gen_client_ts driver on zigstore.tsgen` (include the regenerated `.gen.ts` in the same commit).

---

## Phase 8 (§9 step 8) — Repoint all app imports to `@import("zigstore")`; delete moved originals; split `e2e_test.zig`

**Files:** every dmozdb module that still imports a moved file relatively; delete the moved originals; `zig-directory/src/e2e_test.zig`.

- [ ] **Step 1: Flip relative engine imports to the module import**

In dmozdb, replace relative imports of moved files with the module surface: `@import("epoll.zig")`→`@import("zigstore").EpollServer`/`run`, `@import("snapshot.zig")`/`commit.zig`/`page*`/`btree/*`/`wal*`/`histogram`/`connection`/`signal`/`inverted_index`/`bloom`/`memtable` → the corresponding `@import("zigstore").<name>` (add public re-exports in `root.zig` for any internal the app legitimately needs, e.g. `BloomFilter`, `MemTable`, `AtomicHistogram`, `inverted_index` tokenizer, `BPlusTree` if the app walks trees directly in `subtree.zig`/`verifier.zig`).

Find stragglers:
```bash
cd /Users/junaidahmed/Desktop/projects/zig-directory && grep -rEn '@import\("(\.\./)?(page|page_cache|freelist|btree/|wal/|wal\.zig|snapshot|commit|epoll|connection|signal|bloom|memtable|inverted_index|histogram)' src --include='*.zig'
```
Repoint each.

- [ ] **Step 2: Delete the moved originals from dmozdb**

```bash
cd /Users/junaidahmed/Desktop/projects/zig-directory
git rm src/page.zig src/page_cache.zig src/freelist.zig src/memtable.zig src/bloom.zig \
       src/inverted_index.zig src/histogram.zig src/connection.zig src/signal.zig src/epoll.zig \
       src/snapshot.zig src/commit.zig src/file_header.zig
git rm -r src/btree src/wal/wal.zig src/wal/wal_replay.zig
```
(`src/wal/wal_apply.zig` stays — it's app residual; keep the `wal/` dir for it.)

- [ ] **Step 3: Split `e2e_test.zig`**

The infra-roundtrip tests (page/file_header/btree/codec/CompositeKey roundtrips) already travelled with their files to zigstore in Phases 2–4. Delete those blocks from `e2e_test.zig`; keep the DMOZ-workflow tests (category create/recover, link lifecycle). Confirm no test references a deleted module.

- [ ] **Step 4: Full dmozdb gate (devcontainer)**

Run: `cd /Users/junaidahmed/Desktop/projects/zig-directory && zig build test` → PASS. Boundary check on zigstore → CLEAN. Commit `refactor: dmozdb consumes zigstore via @import("zigstore"); drop moved originals`.

---

## Phase 9 (§9 step 9) — Full integration validation against the `.path` engine

No code changes — this is the integration gate the split otherwise loses (each repo only tests its half).

- [ ] **Step 1: Both unit suites green**

Run in the devcontainer:
```bash
cd /Users/junaidahmed/Desktop/projects/zigstore && zig build test
cd /Users/junaidahmed/Desktop/projects/zig-directory && zig build test
```
Both Expected: PASS.

- [ ] **Step 2: Build + restart dmozdb, curl the routes**

```bash
cd /Users/junaidahmed/Desktop/projects/zig-directory && zig build
# restart dmozdb in the background (it can be OOM-killed by vite/chromium), then:
DMOZDB_HOST=127.0.0.1 curl -s http://localhost:8080/ | head
```
Expected: the directory home renders (HTTP 200, category list present), not "Directory service unavailable".

- [ ] **Step 3: Playwright e2e (chromium only) + eyeball**

```bash
cd /Users/junaidahmed/Desktop/projects/zig-directory/e2e && npx playwright test --project=chromium --reporter=line
```
Expected: green. Then open the rendered pages (home, a category, a link list, search) and confirm visually — green specs miss CSS/width regressions.

- [ ] **Step 4: k6 sanity**

Run the existing k6 smoke (60 VUs) and confirm 0 errors / no restarts. Record the evidence in the PR description.

- [ ] **Step 5: Commit any fixes; do not tag yet**

If validation surfaced fixes, commit them in the owning repo and re-run Steps 1–4 until all green.

---

## Phase 10 (§9 step 10) — Tag `zigstore` `v1.0.0`; flip dmozdb to tarball+hash; re-validate; land

- [ ] **Step 1: Finalize and tag the engine**

In `zigstore/build.zig.zon` set `.version = "1.0.0"`. Commit `release: zigstore v1.0.0`. **Ask the user before pushing/tagging** (push policy). On approval:
```bash
git -C /Users/junaidahmed/Desktop/projects/zigstore tag v1.0.0
# push branch + tag only after explicit approval
```

- [ ] **Step 2: Flip dmozdb's dependency to the tagged tarball**

```bash
cd /Users/junaidahmed/Desktop/projects/zig-directory
zig fetch --save=zigstore "https://github.com/poly-glot/zigstore/archive/refs/tags/v1.0.0.tar.gz"
```
This rewrites `build.zig.zon`'s `.zigstore` entry to `url` + content-addressed `hash` in one shot. Never hand-edit the hash. **Never move the `v1.0.0` tag** afterward — a re-tag that changes the tree breaks the pinned hash.

- [ ] **Step 3: Re-validate against the tagged dependency**

Re-run Phase 9 Steps 1–4 in the devcontainer against the tarball-pinned engine. All Expected: PASS.

- [ ] **Step 4: Commit and open the single PR**

```bash
git -C /Users/junaidahmed/Desktop/projects/zig-directory -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  add build.zig.zon && git -C /Users/junaidahmed/Desktop/projects/zig-directory -c user.name="Junaid Ahmed" -c user.email="me@junaid.guru" \
  commit -m "build: pin zigstore v1.0.0 (tarball + hash)"
```
Open the dmozdb PR (the full migration commit sequence) and the zigstore PR/release. Include the Phase 9 evidence (unit suites, Playwright, curl, k6) in the description.

---

## Self-Review

**1. Spec coverage** (each §-decision → task):
- §2 "moves as-is" (17 files) → Phase 3. §2 splits (types/changeset/file_header/database/snapshot/commit/binary_protocol/main/gen_client_ts/epoll) → Phases 1,2,4,5,6,7. §2 "stays in dmozdb" → Phases 4–8 (residuals) + `e2e_test` split in Phase 8.
- §3 comptime data plane (`Engine(schema)`, generated `Header`) → Phase 4; runtime seams (`recover`, `spawnWorker`, `processFrames`, `run`) → Phases 4 & 6.
- §4 blockers: (1) database carve → Phase 4; (2) framing split → Phase 6; (3) superblock → Phases 1/4 (already type-safe-roots in v0); (4) types split → Phase 1; (5) changeset codec → Phase 2; (6) SnapshotHost → Phase 5; (7) commit → Phase 5; (8) tsgen → Phase 7; (9) wal OpCode→u8 → Phase 3.
- §6 build/packaging (`.path` then tarball, `-Dcpu=baseline` threads via `standardTargetOptions`) → Phases 0 & 10. §7 versioning/CI → Phase 10. §8 test strategy (infra tests travel; integration gate is dmozdb e2e+curl+visual) → Phases 2–4 & 9. §10 non-goals (no VFS/io_uring; hierarchy stays app-side) → respected: only generic primitives move.

**2. Placeholder scan:** No "TBD/implement later". Where a body is ported, the source file + line range is named and the only change is imports/types — concrete and executable. New generic seams (`wire_codec`, paged `Store`, `recover`, `spawnWorker`, `SnapshotHost`, `commit`, `processFrames`, `run`, `tsgen`) each have a failing test, an exact signature, and a port-from-source instruction.

**3. Type consistency:** `Store` = `zigstore.Engine(schema)` throughout; tree accessor `store.tree(name)` returns `*BPlusTree` from Phase 4 onward (the v0 `OrderedTree` API is retired in Phase 4 Step 3 — call sites use `insert`/`search`/`delete`/`rangeScan`), with the parallel `store.memtable(name)` for write memtables. App modules operate on a single `*Directory` handle (replacing `*Database`) that delegates `tree`/`memtable`/`counter`/`nextId` to its composed `Store` and owns `url_bloom`/status-counts/`config`/`subtree_cache`/`verifier_state`. Every runtime seam takes the same `*anyopaque` app ctx: `recover(ctx, .{ .apply_entry, .on_replayed, .bootstrap })`, `spawnWorker(ctx, .{ .interval_ns, .tick })`, `processFrames(ctx, conn, dispatch_fn, op_latency)`, `run(Store, ctx, config)`; plus `commit(Record, store, record, serialize_fn, apply_fn)`, `SnapshotHost`, `ServerConfig`. Names are identical at definition (engine) and call site (app); the recover hooks/worker ticks (`applyEntry`/`recomputeCounts`/`bootstrapRoots`/`verifyOnce`/`repairOnce`) `@ptrCast` ctx back to `*Directory`.

**Known surface change to flag during execution:** the v0 in-memory `tree(name) *OrderedTree` becomes `tree(name) *BPlusTree` in Phase 4. This changes the engine's own example/tests (updated in Phase 4 Step 3) but matches the API dmozdb already uses everywhere, so the app side is unaffected by the difference.
