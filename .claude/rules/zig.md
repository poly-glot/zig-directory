# Zig Conventions (`src/`, the dmozdb backend)

- DO: **`zig fmt` clean.** Every `.zig` file. The auto-format hook runs it on save.
- DO: **Pair every acquire with `defer`/`errdefer`.** Allocations, file handles, locks. Use `errdefer` for cleanup on the error path and `defer` for unconditional teardown. No leaks.
- DO: **Use `std.testing.allocator` in unit tests.** It fails the test on a leak. Don't reach for the page allocator or an arena to hide a leak in a test.
- DO: **Return errors, don't panic.** Recoverable conditions use error unions (`!T`) with `try`/`catch`. Reserve `unreachable` and `@panic` for impossible states, and comment why the state is impossible.
- PREFER: **`comptime` over runtime** when a value or shape is known at compile time (op-code tables, field maps). It is the idiom and it costs nothing.
- DO: **Treat wire-format changes as protocol changes.** Adding or reordering an op or field touches the binary protocol. Update the codegen source and regenerate the client (see [protocol.md](protocol.md)). Never edit the generated file by hand.

## Comments

This codebase is well-commented, and that is an asset. Aim for precision: keep the comments that explain, drop the ones that decorate.

- DO: **Keep WHY comments.** Invariants, lock contracts, wire-format rationale, op-code provenance, "looks wrong but is correct because…". Never strip these to satisfy a "fewer comments" instinct.
- NEVER: **Bare decoration lines.** A `// ─────────────` divider with no words carries no information.
- NEVER: **Signature-echo doc comments.** A `///` that restates the function name or params (`/// Returns the count` over `fn count() usize`) adds nothing.
- NEVER: **Step-label comments that restate the next line**, like `// increment i` over `i += 1`.

| Instead of | Use |
|---|---|
| `// loop over links` above an obvious `for` | nothing, or a WHY: `// links are pre-sorted by id; binary search relies on it` |
| `// ─────────` decoration | a section header with real words, or nothing |
| `/// Gets the name` over `fn name()` | nothing |
