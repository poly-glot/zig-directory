# Zig Conventions (every `.zig` file: `src/`, `bench/`, `build.zig`)

[TigerStyle](https://tigerstyle.dev) is the canon for all Zig in this repo. Its full text is
TigerBeetle's [TIGER_STYLE.md](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md),
and the site points there. **When any other rule in this repo, in `CLAUDE.md`, or in the
global instructions conflicts with TigerStyle, TigerStyle wins.** Two such conflicts were
resolved on 2026-10-27: Zig functions are `snake_case` (not Zig's `camelCase`), and comments
that say *why* are required, not banned.

`src/tidy.zig` enforces the mechanical half of these rules as part of `zig build test` (line
and function length, naming, recursion, unbounded loops, `usize` fields, banned patterns). It
depends only on `std`, so `zig test src/tidy.zig` with the Zig from `build.zig.zon` also runs on
any host in a second. Everything a parser cannot decide is enforced in review against this file.

## Safety

- NEVER: **Recursion.** Walk trees with an explicit stack or queue that has a declared maximum
  (`subtree.zig`, `repair_worker.zig`). `tidy` flags a function that calls itself and any
  call cycle within a file.
- DO: **Put a limit on everything.** Every loop has a fixed upper bound: iterate a slice, use
  `for (0..n)`, or count iterations and `assert` the count. `while (true)` is banned (`tidy`).
  Every queue, buffer and batch has a named maximum (`subtree_offset_max`, `bulk_items_max`).
  Where a loop must never terminate (an event loop) that must be asserted; dmozdb has none,
  zigstore owns the reactor.
- DO: **Explicitly sized integers.** Domain values (ids, counts, sizes, offsets) are `u32` or
  `u64`; `usize` appears only where the language forces it, for slice lengths and indexing,
  and never in a struct field (`tidy`). Cast at the slice boundary with `@intCast`.
- DO: **Assert arguments, return values, pre- and postconditions and invariants.** A function
  must not operate blindly on data it has not checked. Target an average of two assertions per
  function; `tidy` prints the density. Pair assertions across code paths (assert validity before
  writing to the WAL and after reading from it). Split compound assertions (`assert(a);
  assert(b);`). Assert the positive space you expect and the negative space you do not. Use
  `if (a) assert(b)` for implications. Assert relationships between compile-time constants and
  type sizes in `comptime` blocks.
  - **Programmer error versus operating error.** Bytes from the network, the WAL, the disk,
    the environment and the config are operating input: validate them and return an error or a
    protocol status, never assert on them. A value this code computed itself is a programmer
    error if wrong: assert it.
  - Import `const assert = std.debug.assert;` at the top of the file and call `assert(...)`
    (`tidy` bans the inline `std.debug.assert(`). Occasionally a blatantly true assertion
    documents a surprising invariant better than a comment.
  - Production builds are `ReleaseSafe` (`Dockerfile.backend`, `.devcontainer/run.sh`) so every
    assertion stays live in production. Never switch a shipped binary to `ReleaseFast`.
- DO: **Static memory allocation.** Allocate at startup, in `init`; do not allocate, free or
  reallocate after initialization. Size buffers from the named maxima above. The request path
  works from scratch slabs: `Directory.init` reserves one per reactor thread (`src/scratch.zig`,
  `DMOZDB_SCRATCH_SLAB_MB`, 32 MiB each), `Directory.dispatch` opens the thread's slab for the
  request, and `db.scratch()` hands it out; a request that outgrows its slab fails with a
  protocol error instead of growing. `db.allocator` (the gpa) is for `init`, for state that
  outlives a request (memtables, caches, the vector and facts indexes) and, today, for the
  background ticks and loaders, whose working sets scale with the store and still need a
  per-structure reservation (the verifier's orphan list and count maps, the repair worker's
  walk, the facts and vector index growth). Reviewers reject `db.allocator`, `ArrayList`
  growth, `allocPrint` or `ArenaAllocator.init(db.allocator)` on a request path; request-scoped
  memory comes from `db.scratch()` or a caller-provided buffer.
- DO: **Smallest scope.** Declare a variable where it is used, not at the top of the function,
  and keep the number of variables in scope small. Do not alias or duplicate state.
- DO: **Hard limit of 70 lines per function** (`tidy`). Split by pushing `if`s up and `for`s
  down: the parent keeps the control flow and the state, helpers compute without branching and
  stay pure.
- DO: **Simple, explicit control flow.** Split compound conditions into nested `if`/`else`
  trees so every case is visible, and ask whether an `if` needs its `else`. State invariants
  positively (`if (index < count)`). Braces on every `if` that does not fit on one line.
- DO: **Handle every error.** Recoverable conditions use error unions with `try`/`catch`.
  `unreachable` and `@panic` are for states that cannot happen, named so the impossibility is
  self-evident.
- DO: **Crash-only after the WAL append.** Once a `ChangeSet` is in the WAL, a failure to apply
  it in memory is not a client error: `Directory.apply_or_abort` panics so the process restarts
  and recovery replays the record whole. The same rule covers a WAL `fdatasync` failure:
  `Directory.commit`, and `Directory.dispatch` when it waits for a request's writes to become
  durable, panic on `error.WalFlushFailed` because the entries are already applied in memory.
  These are the sanctioned `@panic`s in the write path; everything before the append returns
  errors, and a failed memtable drain is retried.
- DO: **Pass options explicitly** to library calls instead of relying on defaults where the
  default carries meaning (`.{ .iterate = true }`, an explicit `.mode`), so a changed default
  cannot change behaviour silently.
- DO: **Run at your own pace.** Background work (verifier, repair worker, checkpointer, bloom
  seeder) runs on fixed intervals and in bounded chunks; it never reacts to a single external
  event.
- DO: **Pair every acquire with `defer`/`errdefer`**, and group an allocation with its `defer`
  between blank lines so a leak is visible. Unit tests use `std.testing.allocator`.

## Performance

- DO: **Sketch before you design.** Estimate network, disk, memory and CPU, each for bandwidth
  and latency, and write the sketch into the commit message. Optimize the slowest resource
  first after weighting by frequency.
- DO: **Control plane, data plane.** Batch. The data plane (`binary_protocol.zig` handlers)
  writes responses in place into the preallocated buffer, copies fixed-size `extern struct`s
  straight from the store, and never serializes through an intermediate. Assertions live in the
  control plane; the data plane stays a straight line.
- DO: **Fixed-size, aligned records.** `schema.zig` structs are `extern`, sized and aligned by
  `comptime` assertion; a wire-format change is a protocol change (see
  [protocol.md](protocol.md)).
- DO: **Extract hot loops** into stand-alone functions with primitive arguments and no `self`.
- PREFER: `comptime` over runtime for anything known at compile time (op tables, field maps).

## Developer experience

### Naming

- DO: **`snake_case` for functions, variables and files; `PascalCase` for types.** A function
  that returns a type is `PascalCase` and ends in `Type` (`BatchCreateHandlerType`). Constants
  are `snake_case` too, never `SCREAMING_SNAKE` (`tidy`). The one exception is a name a
  dependency's comptime interface dictates (`FieldTable.tsType` for zigstore's `tsgen`); `tidy`
  lists those explicitly.
- DO: **Big-endian names.** Most significant word first, units and qualifiers last:
  `subtree_offset_max`, `latency_ms_p99`, `verifier_interval_s`. They sort and line up.
- NEVER: **Abbreviate.** `buffer` not `buf`, `response` not `resp`, `request` not `req`,
  `category` not `cat`, `change_set` not `cs`, `iterator` not `iter`, `index` not `idx`,
  `current` not `cur`, `directory` not `dir`, `memtable` not `mt`. Zig's own `len`, `io`,
  `gpa`, `arena`, `id`, `fd` and `url` are words here. Single letters only as sort or matrix
  arguments.
- DO: **Same length for related names** (`source`/`target`, `old_path`/`new_path`) so the
  calculations that use them line up.
- DO: **Name a helper after its caller** (`read_sector` / `read_sector_callback`); callbacks go
  last in the parameter list.
- DO: **Infuse names with meaning.** `gpa` and `arena` tell the reader whether `deinit` is
  owed; `allocator` does not.
- DO: **Order for the first read.** `main` first in a file; in a struct, fields, then nested
  types, then methods. The `//!` header on every file says what the module owns.

### Shape

- DO: **Options struct** when two parameters share a primitive integer type or three share
  `[]const u8` (`tidy`), and when a `null` argument would be unclear at the call site: `Page`,
  `Move`, `CategoryText`, `LinkText` in `operations_shared.zig` are the shared shapes.
  Dependencies with unique types (`io`, an allocator, `*Directory`) are positional, most
  general first. An options struct is built at the call site and meant to be copied, so it
  travels by value even past 16 bytes; records (`schema.Link`, `ChangeSet`) do not.
- DO: **`*const T` for arguments over 16 bytes** that are not meant to be copied
  (`*const schema.Link`, `*const ChangeSet`). Construct large structs in place through an out
  pointer instead of returning them by value.
- DO: **Simplest return type that works.** `void` over `bool`, `bool` over `u64`, `u64` over
  `?u64`, `?u64` over `!u64`; every extra dimension is a branch at every call site.
- DO: **Show division intent.** `@divExact`, `@divFloor`, `@divTrunc` or a `div_ceil` helper
  on integers, never bare `/`.
- DO: **100 columns, hard limit** (`tidy`). To wrap a call, signature or literal, add a trailing
  comma and let `zig fmt` do the rest. Four-space indentation; `zig fmt` clean (the hook runs
  it on save).

### Comments

TigerStyle supersedes the repo's former "no comments in Zig" rule and the global no-comment
instruction for `.zig` files.

- DO: **Say why.** A comment explains the rationale a reader cannot recover from the code: a
  protocol invariant, a measured number, a deliberate deviation. Show your workings.
- DO: **Say how.** A test begins with a comment stating its goal and method so a reader can
  skip or dive in. A `//!` header opens every file.
- NEVER: **Restate the code.** `// increment the counter` is still banned; so is commented-out
  code (see [common.md](common.md)).
- DO: **Comments are sentences** (`tidy`): a space after the slashes, a capital letter, a full
  stop or colon at the end of the block. End-of-line comments after code may be phrases.
- DO: **Keep encoding invariants as named tests too.** A test that fails when the invariant
  breaks remains the strongest form of "why"; the comment points at it.

## Dependencies and tooling

- NEVER: **Add a third-party dependency.** `zigstore` is this project's own engine (same
  author, extracted from this repo) and the only entry in `build.zig.zon`. Anything else needs
  a written case against the safety, performance, install-time and supply-chain costs, and the
  answer is normally to write it.
- DO: **Scripts in Zig.** New tooling is a Zig program under `bench/` or `src/`, not a shell
  script; `bench/run-constrained.sh` and `bench/run-server-constrained.sh` are the legacy
  exceptions, not a precedent.
- DO: **Treat wire-format changes as protocol changes.** Update the codegen source and
  regenerate the client (see [protocol.md](protocol.md)). Never edit the generated file by hand.
- DO: **Zero technical debt.** Do it right the first time; a known gap ships with its fix, not
  a `TODO` (`tidy` bans `TODO` and `FIXME`).

## Verify

- `zig build test` (Docker gate on this Mac, see the memory notes) runs the suite and `tidy`.
- `zig test src/tidy.zig` runs the style checks alone on any host with Zig 0.16.
- `zig build test -Dtarget=aarch64-linux-musl` cross-compiles the whole test binary on macOS
  in about ten seconds; the only acceptable failure is the "unable to execute" run step.
