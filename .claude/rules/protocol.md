# Protocol Conventions (binary wire format and generated client)

The Zig backend (`dmozdb`) speaks a binary protocol. The Deno client's typed view of it is generated.

- NEVER: **Hand-edit `web/lib/dmoz-protocol.gen.ts`.** It is generated. A manual edit gets overwritten on the next regeneration and silently diverges the client from the server.
- DO: **Regenerate after any protocol change.** When you add or change an op or field in the Zig server, run:
  ```bash
  zig build gen-client-ts
  cd web && deno check
  ```
  Commit the regenerated file in the same commit as the server change.
- DO: **Extend ops with optional trailing bytes.** To extend an op without breaking older callers, append an optional trailing byte or field (the status filter and the cursor `after_id` both do this). Follow that pattern instead of forking a new op number.
- DO: **Keep hierarchy semantics on the server** (see [architecture.md](architecture.md)). New recursive or aggregate needs are new ops, not client fan-out.
