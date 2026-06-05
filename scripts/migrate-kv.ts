#!/usr/bin/env -S deno run -A --unstable-kv

// One-shot migration of the file-backed Deno KV (users + sessions) into the
// shared denokv service. Users are copied; sessions are intentionally dropped
// (the 7-day session cookies simply re-authenticate), so any logged-in user
// signs in once more after cutover.
//
// Usage:
//   DENO_KV_ACCESS_TOKEN=<token> \
//     deno run -A --unstable-kv scripts/migrate-kv.ts <source-users.db> <dest-kv-url>
//
// dest-kv-url examples:
//   http://denokv.dmozdb.svc.cluster.local:4512   (run in-cluster)
//   http://localhost:4512                          (via `kubectl port-forward svc/denokv 4512`)
//
// The source SQLite file is in WAL mode; copy its -wal/-shm sidecars too, or
// run against a quiesced source, so recent writes aren't missed.

const sourcePath = Deno.args[0] ?? Deno.env.get("SOURCE_KV_PATH");
const destUrl = Deno.args[1] ?? Deno.env.get("DEST_KV_URL");

if (!sourcePath || !destUrl) {
  console.error(
    "usage: migrate-kv.ts <source-users.db> <dest-kv-url>  (DENO_KV_ACCESS_TOKEN required for dest)",
  );
  Deno.exit(1);
}

const src = await Deno.openKv(sourcePath);
const dest = await Deno.openKv(destUrl);

let migrated = 0;
let skippedSessions = 0;

for await (const entry of src.list({ prefix: [] })) {
  if (entry.key[0] === "sessions") {
    skippedSessions++;
    continue;
  }
  await dest.set(entry.key, entry.value);
  migrated++;
}

src.close();
dest.close();

console.log(
  `migrated ${migrated} entries; skipped ${skippedSessions} sessions (will re-auth)`,
);
