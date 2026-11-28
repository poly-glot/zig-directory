import { assert, assertEquals } from "jsr:@std/assert@^1";
import {
  authenticateUser,
  createUser,
  getKv,
  getUserById,
} from "./kv-users.ts";

Deno.env.set("KV_PATH", ":memory:");

const kvTest = { sanitizeResources: false };

async function averageSignInMs(email: string): Promise<number> {
  const runs = 5;
  const started = performance.now();
  for (let run = 0; run < runs; run++) {
    assertEquals(await authenticateUser(email, "wrong-password"), null);
  }
  return (performance.now() - started) / runs;
}

Deno.test({
  ...kvTest,
  name: "an unknown email costs a sign-in as much as a wrong password",
  async fn() {
    await createUser("known@example.com", "known", "right-password");

    const knownMs = await averageSignInMs("known@example.com");
    const unknownMs = await averageSignInMs("unknown@example.com");

    assert(
      unknownMs > knownMs / 2,
      `unknown ${unknownMs.toFixed(2)} ms vs known ${knownMs.toFixed(2)} ms`,
    );
  },
});

async function legacyPasswordHash(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const keyMaterial = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt, iterations: 100_000, hash: "SHA-256" },
    keyMaterial,
    256,
  );
  const hex = (bytes: Uint8Array) =>
    Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex(salt)}:${hex(new Uint8Array(bits))}`;
}

Deno.test({
  ...kvTest,
  name: "new passwords are hashed with 600,000 PBKDF2 iterations",
  async fn() {
    const user = await createUser("fresh@example.com", "fresh", "password-1");

    assert(user.passwordHash.startsWith("600000:"));
    assert(await authenticateUser("fresh@example.com", "password-1"));
  },
});

Deno.test({
  ...kvTest,
  name: "a legacy 100,000-iteration hash still signs in and is upgraded",
  async fn() {
    const user = await createUser("legacy@example.com", "legacy", "unused");
    const kv = await getKv();
    await kv.set(["users", user.id], {
      ...user,
      passwordHash: await legacyPasswordHash("old-password"),
    });

    assert(await authenticateUser("legacy@example.com", "old-password"));
    const upgraded = await getUserById(user.id);
    assert(upgraded?.passwordHash.startsWith("600000:"));

    assert(await authenticateUser("legacy@example.com", "old-password"));
    assertEquals(
      await authenticateUser("legacy@example.com", "wrong-password"),
      null,
    );
  },
});
