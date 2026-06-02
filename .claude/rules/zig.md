# Zig Conventions (`src/`, the dmozdb backend)

- DO: **`zig fmt` clean.** Every `.zig` file. The auto-format hook runs it on save.
- DO: **Pair every acquire with `defer`/`errdefer`.** Allocations, file handles, locks. Use `errdefer` for cleanup on the error path and `defer` for unconditional teardown. No leaks.
- DO: **Use `std.testing.allocator` in unit tests.** It fails the test on a leak. Don't reach for the page allocator or an arena to hide a leak in a test.
- DO: **Return errors, don't panic.** Recoverable conditions use error unions (`!T`) with `try`/`catch`. Reserve `unreachable` and `@panic` for genuinely impossible states; pick an assertion/error name that makes the impossibility self-evident.
- PREFER: **`comptime` over runtime** when a value or shape is known at compile time (op-code tables, field maps). It is the idiom and it costs nothing.
- DO: **Treat wire-format changes as protocol changes.** Adding or reordering an op or field touches the binary protocol. Update the codegen source and regenerate the client (see [protocol.md](protocol.md)). Never edit the generated file by hand.

## Comments

No comments. The code carries intent through naming and structure; the "why" lives in tests.

- NEVER: **Any comment.** No `//`, `///`, or `//!` — not WHY comments, not doc comments, not section dividers, not step labels. The only `//` allowed in a `.zig` file is inside a string literal (URLs, format strings).
- DO: **Make the code self-documenting.** If a line would need a comment to be understood, rename the symbol or extract a well-named function instead.
- DO: **Encode the "why" in tests.** An invariant a comment would have explained becomes a named test that fails when the invariant breaks — name the test for the property it locks (e.g. `test "delete invalidates the rightmost cache so a reused page is not cross-tree written"`) and assert it.

| Instead of | Use |
|---|---|
| `// links are pre-sorted by id; search relies on it` | a test: `test "ids stay sorted so binary search holds"` |
| `// looks wrong but is correct because X` | a test that fails if X stops holding |
| `/// Gets the name` over `fn name()` | nothing |
