// Dev-only seed: create a default admin in the Deno-KV user store when it has
// no users yet. Invoked by .devcontainer/seed.sh on container start (guarded by
// a missing web/data/users.db). NEVER used in production — the prod user store
// is restored from the real data out-of-band; registration only ever creates
// the `user` role, so a fresh dev checkout otherwise has no way in to /admin.
//
// No credential is hardcoded (secret scanners stay quiet): the password comes
// from SEED_ADMIN_PASSWORD, else a strong random one is generated and written
// to web/data/admin-credentials.txt (under gitignored web/data/) and printed.
import { createUser, getUserCount } from "../lib/kv-users.ts";

const EMAIL = Deno.env.get("SEED_ADMIN_EMAIL") ?? "admin@test.com";
const USERNAME = Deno.env.get("SEED_ADMIN_USERNAME") ?? "admin";

// ~144 bits of entropy, alphanumeric — generated per fresh checkout, never
// committed, so it is not a static secret to scan for.
function randomPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(18));
  return btoa(String.fromCharCode(...bytes)).replace(/[^A-Za-z0-9]/g, "");
}

if ((await getUserCount()) > 0) {
  console.log("[seed-admin] user store already populated; skipping.");
} else {
  const password = Deno.env.get("SEED_ADMIN_PASSWORD") ?? randomPassword();
  await createUser(EMAIL, USERNAME, password, "admin");
  // Persist + print so the dev can sign in. The file lives under gitignored
  // web/data/, so it is never committed.
  const creds = `dev admin (created by scripts/seed-admin.ts)
email:    ${EMAIL}
username: ${USERNAME}
password: ${password}
`;
  await Deno.writeTextFile("./data/admin-credentials.txt", creds);
  console.log(
    "[seed-admin] created admin — credentials saved to web/data/admin-credentials.txt:",
  );
  console.log(creds.trimEnd().replace(/^/gm, "  "));
}
